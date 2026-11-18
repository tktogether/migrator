/* agent/tracker.c — which chunks of the volumes were written, since when.
 *
 * Two trackers behind one interface (tracker_start/flip/lost/stop):
 *
 * bpf (kernel >= 4.14): a small BPF program on the block_bio_queue tracepoint
 * (perf_event_open per CPU + PERF_EVENT_IOC_SET_BPF; nothing from libbpf, the
 * bytecode is assembled here from the field offsets the tracepoint's "format"
 * file gives). For every bio that is not a read, on one of our devices and
 * inside the volume's sector range, it stores a 1 into a byte-per-chunk array
 * map: entry = base(volume) + chunk/2^20 + parity*total, byte = chunk%2^20.
 * There is no event stream to consume, so nothing is dropped by being late; a
 * bio longer than the unrolled marking loop covers (MAXCH chunks: 8 MiB on
 * 5.2+, 1 MiB before - XFS writeback with large folios and discards can be
 * far bigger) is written as one {seq, first, last} entry into a per-cpu
 * overflow ring that userspace drains at every flip; only a ring that wraps
 * before a drain, or a sequence gap, counts as lost (then a full pass). A flip
 * toggles the parity the program reads from a control map, waits 10 ms for
 * in-flight handlers, then reads and clears the old parity's entries.
 *
 * ftrace (any kernel with CONFIG_BLK_DEV_IO_TRACE): the same tracepoint
 * enabled through tracefs with a dev filter, a thread reads trace_pipe and
 * sets bits in the volume's current bitmap; a flip writes a marker into
 * trace_marker and the thread swaps bitmaps when it sees it (events before
 * the marker land in the old one). Per-CPU buffer 16 MiB; overruns are
 * counted in per_cpu/cpuN/stats and reported as lost.
 *
 * Which bios count: everything that is not a read with nr_sector > 0: writes,
 * write-zeroes ("N" in rwbs), discards ("D" - the device may return zeros
 * afterwards, the copy must match the source byte for byte). A partition is
 * traced on its whole disk (the kernel remaps the bio before the tracepoint
 * fires), with absolute sectors and the partition's start subtracted.
 */
#include "agent.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <dirent.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <linux/bpf.h>
#include <linux/perf_event.h>

static char errbuf[1024];
#define FAIL(...) do { snprintf(errbuf, sizeof errbuf, __VA_ARGS__); t->err = errbuf; return -1; } while (0)

/* ---- small things ------------------------------------------------------ */

int kernel_version(void)
{
	struct utsname u; int a = 0, b = 0;
	if (uname(&u) < 0) return 0;
	sscanf(u.release, "%d.%d", &a, &b);
	return a * 10000 + b;
}

const char *find_tracefs(char *buf, size_t n)
{
	struct stat st;
	/* /sys/kernel/tracing is a kernel automount of tracefs since 4.1; touching it mounts it */
	if (stat("/sys/kernel/tracing/events", &st) == 0) { snprintf(buf, n, "/sys/kernel/tracing"); return buf; }
	if (mount("tracefs", "/sys/kernel/tracing", "tracefs", 0, NULL) == 0 && stat("/sys/kernel/tracing/events", &st) == 0) { snprintf(buf, n, "/sys/kernel/tracing"); return buf; }
	if (stat("/sys/kernel/debug/tracing/events", &st) == 0) { snprintf(buf, n, "/sys/kernel/debug/tracing"); return buf; }
	if (mount("debugfs", "/sys/kernel/debug", "debugfs", 0, NULL) == 0 && stat("/sys/kernel/debug/tracing/events", &st) == 0) { snprintf(buf, n, "/sys/kernel/debug/tracing"); return buf; }
	return NULL;
}

int bitmap_alloc(struct bitmap *b, uint64_t nbits)
{
	b->nbits = nbits; b->nwords = (nbits + 63) / 64;
	b->w = calloc(b->nwords ? b->nwords : 1, sizeof(uint64_t));
	return b->w ? 0 : -1;
}
void bitmap_free(struct bitmap *b) { free(b->w); b->w = NULL; }
void bitmap_or_into(struct bitmap *dst, struct bitmap *src)
{
	for (uint64_t i = 0; i < dst->nwords; i++) {
		uint64_t v = __atomic_exchange_n(&src->w[i], 0, __ATOMIC_RELAXED);
		if (v) dst->w[i] |= v;
	}
}
uint64_t bitmap_count(const struct bitmap *b)
{
	uint64_t n = 0;
	for (uint64_t i = 0; i < b->nwords; i++) n += __builtin_popcountll(b->w[i]);
	return n;
}

/* the tracepoint's field offsets, from its format file */
struct tp_format { int id, off_dev, off_sector, off_nr, off_rwbs; };
static int read_format(const char *tracefs, struct tp_format *f)
{
	char path[256], line[256]; FILE *fp;
	snprintf(path, sizeof path, "%s/events/block/block_bio_queue/id", tracefs);
	f->id = (int)read_file_long(path, -1);
	snprintf(path, sizeof path, "%s/events/block/block_bio_queue/format", tracefs);
	fp = fopen(path, "r"); if (!fp) return -1;
	f->off_dev = f->off_sector = f->off_nr = f->off_rwbs = -1;
	while (fgets(line, sizeof line, fp)) {
		char name[64]; int off = -1;
		char *p = strstr(line, "field:"); if (!p) continue;
		/* "field:dev_t dev;  offset:8;  size:4; ..." - the name is the last word before ';' */
		char *semi = strchr(p, ';'); if (!semi) continue;
		*semi = 0;
		char *sp = strrchr(p, ' '); if (!sp) continue;
		snprintf(name, sizeof name, "%s", sp + 1);
		char *bracket = strchr(name, '['); if (bracket) *bracket = 0;
		p = strstr(semi + 1, "offset:"); if (!p) continue;
		off = atoi(p + 7);
		if (!strcmp(name, "dev")) f->off_dev = off;
		else if (!strcmp(name, "sector")) f->off_sector = off;
		else if (!strcmp(name, "nr_sector")) f->off_nr = off;
		else if (!strcmp(name, "rwbs")) f->off_rwbs = off;
	}
	fclose(fp);
	return (f->id > 0 && f->off_dev >= 0 && f->off_sector >= 0 && f->off_nr >= 0 && f->off_rwbs >= 0) ? 0 : -1;
}

/* ---- bpf --------------------------------------------------------------- */

static long sys_bpf(int cmd, union bpf_attr *attr, unsigned size) { return syscall(__NR_bpf, cmd, attr, size); }

static int bpf_map_create(int type, int key, int value, int max)
{
	union bpf_attr a; memset(&a, 0, sizeof a);
	a.map_type = type; a.key_size = key; a.value_size = value; a.max_entries = max;
	return (int)sys_bpf(BPF_MAP_CREATE, &a, sizeof a);
}
static int bpf_map_lookup(int fd, const void *key, void *value)
{
	union bpf_attr a; memset(&a, 0, sizeof a);
	a.map_fd = fd; a.key = (uint64_t)(uintptr_t)key; a.value = (uint64_t)(uintptr_t)value;
	return (int)sys_bpf(BPF_MAP_LOOKUP_ELEM, &a, sizeof a);
}
static int bpf_map_update(int fd, const void *key, const void *value)
{
	union bpf_attr a; memset(&a, 0, sizeof a);
	a.map_fd = fd; a.key = (uint64_t)(uintptr_t)key; a.value = (uint64_t)(uintptr_t)value; a.flags = BPF_ANY;
	return (int)sys_bpf(BPF_MAP_UPDATE_ELEM, &a, sizeof a);
}
static int bpf_prog_load(const struct bpf_insn *insns, int n, char *log, int loglen)
{
	union bpf_attr a; memset(&a, 0, sizeof a);
	a.prog_type = BPF_PROG_TYPE_TRACEPOINT; a.insns = (uint64_t)(uintptr_t)insns; a.insn_cnt = n;
	a.license = (uint64_t)(uintptr_t)"GPL"; a.log_buf = (uint64_t)(uintptr_t)log; a.log_size = loglen; a.log_level = log ? 1 : 0;
	return (int)sys_bpf(BPF_PROG_LOAD, &a, sizeof a);
}

/* the assembler: a growing array, jumps patched by index */
struct prog { struct bpf_insn *i; int n, cap; };
static int emit(struct prog *p, struct bpf_insn in)
{
	if (p->n == p->cap) { p->cap = p->cap ? p->cap * 2 : 1024; p->i = realloc(p->i, p->cap * sizeof *p->i); if (!p->i) die("out of memory"); }
	p->i[p->n] = in; return p->n++;
}
#define INSN(CODE, DST, SRC, OFF, IMM) ((struct bpf_insn){ .code = (CODE), .dst_reg = (DST), .src_reg = (SRC), .off = (OFF), .imm = (IMM) })
#define ALU64_IMM(OP, DST, IMM) INSN(BPF_ALU64 | BPF_OP(OP) | BPF_K, DST, 0, 0, IMM)
#define ALU64_REG(OP, DST, SRC) INSN(BPF_ALU64 | BPF_OP(OP) | BPF_X, DST, SRC, 0, 0)
#define MOV64_REG(DST, SRC) INSN(BPF_ALU64 | BPF_MOV | BPF_X, DST, SRC, 0, 0)
#define MOV64_IMM(DST, IMM) INSN(BPF_ALU64 | BPF_MOV | BPF_K, DST, 0, 0, IMM)
#define LDX_MEM(SZ, DST, SRC, OFF) INSN(BPF_LDX | BPF_SIZE(SZ) | BPF_MEM, DST, SRC, OFF, 0)
#define STX_MEM(SZ, DST, SRC, OFF) INSN(BPF_STX | BPF_SIZE(SZ) | BPF_MEM, DST, SRC, OFF, 0)
#define ST_MEM(SZ, DST, OFF, IMM) INSN(BPF_ST | BPF_SIZE(SZ) | BPF_MEM, DST, 0, OFF, IMM)
#define STX_XADD(SZ, DST, SRC, OFF) INSN(BPF_STX | BPF_SIZE(SZ) | 0xc0, DST, SRC, OFF, 0)   /* BPF_XADD; imm 0 = BPF_ADD for the BPF_ATOMIC spelling too */
#define JMP_IMM(OP, DST, IMM, OFF) INSN(BPF_JMP | BPF_OP(OP) | BPF_K, DST, 0, OFF, IMM)
#define JMP_REG(OP, DST, SRC, OFF) INSN(BPF_JMP | BPF_OP(OP) | BPF_X, DST, SRC, OFF, 0)
#define CALL_(FUNC) INSN(BPF_JMP | BPF_CALL, 0, 0, 0, FUNC)
#define EXIT_ INSN(BPF_JMP | BPF_EXIT, 0, 0, 0, 0)
static void emit_ld_imm64(struct prog *p, int dst, uint64_t v)
{
	emit(p, INSN(BPF_LD | BPF_DW | BPF_IMM, dst, 0, 0, (int32_t)(uint32_t)(v & 0xffffffffu)));
	emit(p, INSN(0, 0, 0, 0, (int32_t)(uint32_t)(v >> 32)));
}
static void emit_ld_map_fd(struct prog *p, int dst, int fd)
{
	emit(p, INSN(BPF_LD | BPF_DW | BPF_IMM, dst, BPF_PSEUDO_MAP_FD, 0, fd));
	emit(p, INSN(0, 0, 0, 0, 0));
}
static void patch(struct prog *p, int at, int target) { p->i[at].off = (int16_t)(target - at - 1); }

#define R0 0
#define R1 1
#define R2 2
#define R3 3
#define R6 6
#define R7 7
#define R8 8
#define R9 9
#define R10 10

/* r6 = dev, r7 = sector, r8 = nr_sector, r9 = parity * total */
static void build_prog(struct prog *p, struct tracker *t, const struct tp_format *f)
{
	int j_exit[8 + MAX_VOLS], nj = 0, v;
	emit(p, MOV64_REG(R9, R1));                              /* r9 = ctx for now */
	emit(p, LDX_MEM(BPF_W, R6, R9, f->off_dev));
	emit(p, LDX_MEM(BPF_DW, R7, R9, f->off_sector));
	emit(p, LDX_MEM(BPF_W, R8, R9, f->off_nr));
	emit(p, LDX_MEM(BPF_B, R2, R9, f->off_rwbs));
	emit(p, LDX_MEM(BPF_B, R3, R9, f->off_rwbs + 1));
	j_exit[nj++] = emit(p, JMP_IMM(BPF_JEQ, R8, 0, 0));
	j_exit[nj++] = emit(p, JMP_IMM(BPF_JEQ, R2, 'R', 0));
	j_exit[nj++] = emit(p, JMP_IMM(BPF_JEQ, R3, 'R', 0));
	/* parity from the control map, entry 0 */
	emit(p, ST_MEM(BPF_W, R10, -4, 0));
	emit_ld_map_fd(p, R1, t->ctrl_fd);
	emit(p, MOV64_REG(R2, R10)); emit(p, ALU64_IMM(BPF_ADD, R2, -4));
	emit(p, CALL_(BPF_FUNC_map_lookup_elem));
	j_exit[nj++] = emit(p, JMP_IMM(BPF_JEQ, R0, 0, 0));
	emit(p, LDX_MEM(BPF_W, R9, R0, 0));
	emit(p, ALU64_IMM(BPF_AND, R9, 1));
	emit(p, ALU64_IMM(BPF_MUL, R9, (int32_t)t->bpf_total));
	for (v = 0; v < t->nvols; v++) {
		struct volume *vol = &t->vols[v];
		uint64_t dev = ((uint64_t)vol->tmaj << 20) | vol->tmin;
		uint64_t start = vol->toff, end = vol->toff + vol->size / SECTOR;
		int shift = t->chunk_shift - 9;   /* chunk in sectors = 1 << shift */
		int j_next[3], nn = 0, j_done[2 * 130 + 8], nd = 0, i;
		emit_ld_imm64(p, R3, dev);  j_next[nn++] = emit(p, JMP_REG(BPF_JNE, R6, R3, 0));
		emit_ld_imm64(p, R3, start); j_next[nn++] = emit(p, JMP_REG(BPF_JLT, R7, R3, 0));
		emit_ld_imm64(p, R2, end);   j_next[nn++] = emit(p, JMP_REG(BPF_JGE, R7, R2, 0));
		emit(p, ALU64_REG(BPF_SUB, R7, R3));                  /* r7 = sector - start */
		emit(p, ALU64_REG(BPF_ADD, R8, R7));
		emit(p, ALU64_IMM(BPF_SUB, R8, 1));                   /* r8 = last sector */
		emit(p, ALU64_IMM(BPF_RSH, R7, shift));               /* first chunk */
		emit(p, ALU64_IMM(BPF_RSH, R8, shift));               /* last chunk */
		for (i = 0; i < (int)t->maxch; i++) {
			j_done[nd++] = emit(p, JMP_REG(BPF_JGT, R7, R8, 0));
			emit(p, MOV64_REG(R1, R7)); emit(p, ALU64_IMM(BPF_RSH, R1, 20));
			emit(p, ALU64_IMM(BPF_ADD, R1, (int32_t)vol->bpf_base)); emit(p, ALU64_REG(BPF_ADD, R1, R9));
			emit(p, STX_MEM(BPF_W, R10, R1, -4));
			emit_ld_map_fd(p, R1, t->map_fd);
			emit(p, MOV64_REG(R2, R10)); emit(p, ALU64_IMM(BPF_ADD, R2, -4));
			emit(p, CALL_(BPF_FUNC_map_lookup_elem));
			j_done[nd++] = emit(p, JMP_IMM(BPF_JEQ, R0, 0, 0));
			emit(p, MOV64_REG(R1, R7)); emit(p, ALU64_IMM(BPF_AND, R1, BPF_ENTRY_BYTES - 1));
			emit(p, ALU64_REG(BPF_ADD, R0, R1));
			emit(p, ST_MEM(BPF_B, R0, 0, 1));
			emit(p, ALU64_IMM(BPF_ADD, R7, 1));
		}
		/* chunks left over (a bio longer than maxch chunks): one entry in this
		 * cpu's ring - {seq, first, last, parity*total, vol}; userspace marks the
		 * range at the next epoch. Plain stores: the handler runs with preemption
		 * off on its cpu; a nested submission from an interrupt would show up as a
		 * sequence gap, which userspace counts as lost. */
		j_done[nd++] = emit(p, JMP_REG(BPF_JGT, R7, R8, 0));
		emit(p, ST_MEM(BPF_W, R10, -4, 0));
		emit_ld_map_fd(p, R1, t->ring_fd);
		emit(p, MOV64_REG(R2, R10)); emit(p, ALU64_IMM(BPF_ADD, R2, -4));
		emit(p, CALL_(BPF_FUNC_map_lookup_elem));
		j_done[nd++] = emit(p, JMP_IMM(BPF_JEQ, R0, 0, 0));
		emit(p, LDX_MEM(BPF_DW, R6, R0, 0));                  /* r6 = seq (dev is not needed any more) */
		emit(p, MOV64_REG(R1, R6)); emit(p, ALU64_IMM(BPF_ADD, R1, 1));
		emit(p, STX_MEM(BPF_DW, R0, R1, 0));                  /* counter = seq + 1 */
		emit(p, MOV64_REG(R1, R6)); emit(p, ALU64_IMM(BPF_AND, R1, BPF_RING - 1)); emit(p, ALU64_IMM(BPF_ADD, R1, 1));
		emit(p, STX_MEM(BPF_W, R10, R1, -4));                 /* slot key = (seq & (RING-1)) + 1 */
		emit_ld_map_fd(p, R1, t->ring_fd);
		emit(p, MOV64_REG(R2, R10)); emit(p, ALU64_IMM(BPF_ADD, R2, -4));
		emit(p, CALL_(BPF_FUNC_map_lookup_elem));
		j_done[nd++] = emit(p, JMP_IMM(BPF_JEQ, R0, 0, 0));
		emit(p, STX_MEM(BPF_DW, R0, R6, 0));
		emit(p, STX_MEM(BPF_DW, R0, R7, 8));
		emit(p, STX_MEM(BPF_DW, R0, R8, 16));
		emit(p, STX_MEM(BPF_DW, R0, R9, 24));
		emit(p, ST_MEM(BPF_W, R0, 32, vol->id));
		int done = p->n;
		for (i = 0; i < nd; i++) patch(p, j_done[i], done);
		j_exit[nj++] = emit(p, JMP_IMM(BPF_JA, 0, 0, 0));
		int next = p->n;
		for (i = 0; i < nn; i++) patch(p, j_next[i], next);
	}
	int ex = emit(p, MOV64_IMM(R0, 0)); emit(p, EXIT_);
	for (v = 0; v < nj; v++) patch(p, j_exit[v], ex);
}

struct ring_entry { uint64_t seq, first, last, parity_off; uint32_t vol, pad; };

static int possible_cpus(void)
{
	char s[256]; int last = -1;
	if (read_file_str("/sys/devices/system/cpu/possible", s, sizeof s) < 0) return -1;
	for (char *p = strtok(s, ",\n"); p; p = strtok(NULL, ",\n")) { int a, b; if (sscanf(p, "%d-%d", &a, &b) < 2) b = atoi(p); if (b > last) last = b; }
	return last + 1;
}

/* the ring: every cpu's entries since the last drain; an entry written under
 * the old parity belongs to the epoch just closed (pending), a newer one to
 * the current epoch (cur, merged at the next flip) */
static int bpf_drain_ring(struct tracker *t, unsigned old_parity)
{
	size_t vsz = (sizeof(struct ring_entry) + 7) & ~7UL;
	uint8_t *vals = malloc(vsz * t->ncpu_possible); uint32_t k = 0; int cpu;
	if (!vals) die("out of memory");
	if (bpf_map_lookup(t->ring_fd, &k, vals) < 0) { free(vals); FAIL("ring lookup: %s", strerror(errno)); }
	for (cpu = 0; cpu < t->ncpu_possible; cpu++) {
		uint64_t counter = ((struct ring_entry *)(vals + cpu * vsz))->seq, seq = t->ring_drained[cpu];
		if (counter - seq > BPF_RING) { t->ring_lost += counter - seq - BPF_RING; seq = counter - BPF_RING; }
		for (; seq < counter; seq++) {
			uint8_t *slot = malloc(vsz * t->ncpu_possible); struct ring_entry *e;
			k = (uint32_t)(seq & (BPF_RING - 1)) + 1;
			if (!slot || bpf_map_lookup(t->ring_fd, &k, slot) < 0) { free(slot); free(vals); FAIL("ring slot lookup: %s", strerror(errno)); }
			e = (struct ring_entry *)(slot + cpu * vsz);
			if (e->seq != seq) { t->ring_lost++; free(slot); continue; }
			for (int i = 0; i < t->nvols; i++) {
				struct volume *v = &t->vols[i];
				if (v->id != (int)e->vol) continue;
				struct bitmap *b = (e->parity_off != 0) == (old_parity != 0) ? &v->pending : &v->cur;
				for (uint64_t c = e->first; c <= e->last && c < v->chunks; c++) bitmap_set(b, c);
			}
			free(slot);
		}
		t->ring_drained[cpu] = counter;
	}
	free(vals);
	return 0;
}

static int online_cpus(int *list, int max)
{
	char s[1024]; int n = 0;
	if (read_file_str("/sys/devices/system/cpu/online", s, sizeof s) < 0) return -1;
	for (char *p = strtok(s, ",\n"); p; p = strtok(NULL, ",\n")) {
		int a, b; if (sscanf(p, "%d-%d", &a, &b) < 2) b = a = atoi(p);
		for (int c = a; c <= b && n < max; c++) list[n++] = c;
	}
	return n;
}

static int bpf_start(struct tracker *t)
{
	struct tp_format f; struct prog p = { 0 }; char *log; int cpus[1024], ncpu, i;
	struct rlimit rl = { RLIM_INFINITY, RLIM_INFINITY };
	if (kernel_version() < 40014) FAIL("bpf needs kernel 4.14 or newer");
	if (read_format(t->tracefs, &f) < 0) FAIL("cannot read %s/events/block/block_bio_queue/format", t->tracefs);
	setrlimit(RLIMIT_MEMLOCK, &rl);
	/* map geometry: entries of BPF_ENTRY_BYTES chunks per volume, two parities */
	t->bpf_total = 0;
	for (i = 0; i < t->nvols; i++) {
		t->vols[i].bpf_base = t->bpf_total;
		t->bpf_total += (t->vols[i].chunks + BPF_ENTRY_BYTES - 1) / BPF_ENTRY_BYTES;
	}
	t->ctrl_fd = bpf_map_create(BPF_MAP_TYPE_ARRAY, 4, 8, 2);
	if (t->ctrl_fd < 0) FAIL("bpf map create (control): %s", strerror(errno));
	t->map_fd = bpf_map_create(BPF_MAP_TYPE_ARRAY, 4, BPF_ENTRY_BYTES, (int)(2 * t->bpf_total));
	if (t->map_fd < 0) { int e = errno; FAIL("bpf map create (%llu x 1 MiB): %s", (unsigned long long)(2 * t->bpf_total), strerror(e)); }
	{ uint32_t k = 0; uint64_t z = 0; bpf_map_update(t->ctrl_fd, &k, &z); k = 1; bpf_map_update(t->ctrl_fd, &k, &z); }
	t->ncpu_possible = possible_cpus();
	if (t->ncpu_possible <= 0) FAIL("cannot count possible cpus");
	t->ring_fd = bpf_map_create(BPF_MAP_TYPE_PERCPU_ARRAY, 4, sizeof(struct ring_entry), BPF_RING + 1);
	if (t->ring_fd < 0) FAIL("bpf map create (ring): %s", strerror(errno));
	t->ring_drained = calloc(t->ncpu_possible, sizeof(uint64_t));
	t->ring_lost = 0;
	for (i = 0; i < t->nvols; i++) if (bitmap_alloc(&t->vols[i].cur, t->vols[i].chunks) < 0) FAIL("out of memory");
	t->parity = 0;
	t->maxch = kernel_version() >= 50002 ? 128 : 16;
	build_prog(&p, t, &f);
	log = malloc(1 << 20);
	t->prog_fd = bpf_prog_load(p.i, p.n, log, 1 << 20);
	if (t->prog_fd < 0) {
		int e = errno; char *nl;
		/* the verifier's verdict is the last non-empty line of the log */
		for (nl = log + strlen(log); nl > log && (nl[-1] == '\n' || nl[-1] == 0); nl--) nl[-1] = 0;
		nl = strrchr(log, '\n'); nl = nl ? nl + 1 : log;
		snprintf(errbuf, sizeof errbuf, "bpf prog load (%d insns, maxch %u): %s: %.300s", p.n, t->maxch, strerror(e), nl);
		free(log); free(p.i); t->err = errbuf; return -1;
	}
	free(log); free(p.i);
	/* one perf event is enough: the program sits in the tracepoint's own
	 * prog_array and runs on every cpu; a second event with the same program
	 * is refused with EEXIST (bcc does the same: one event on one cpu) */
	ncpu = online_cpus(cpus, 1024);
	if (ncpu <= 0) FAIL("cannot list online cpus");
	t->perf_fds = calloc(1, sizeof(int)); t->nperf = 0;
	{
		struct perf_event_attr attr; memset(&attr, 0, sizeof attr);
		attr.type = PERF_TYPE_TRACEPOINT; attr.size = sizeof attr; attr.config = f.id;
		attr.sample_period = 1; attr.wakeup_events = 1;
		int fd = (int)syscall(__NR_perf_event_open, &attr, -1, cpus[0], -1, PERF_FLAG_FD_CLOEXEC);
		if (fd < 0) FAIL("perf_event_open(tracepoint %d, cpu %d): %s", f.id, cpus[0], strerror(errno));
		t->perf_fds[t->nperf++] = fd;
		if (ioctl(fd, PERF_EVENT_IOC_SET_BPF, t->prog_fd) < 0) FAIL("PERF_EVENT_IOC_SET_BPF: %s", strerror(errno));
		if (ioctl(fd, PERF_EVENT_IOC_ENABLE, 0) < 0) FAIL("PERF_EVENT_IOC_ENABLE: %s", strerror(errno));
	}
	t->mode = 1;
	return 0;
}

static int bpf_flip(struct tracker *t)
{
	static uint8_t *buf, *zero;
	uint32_t k; uint64_t v; int i;
	if (!buf) { buf = malloc(BPF_ENTRY_BYTES); zero = calloc(1, BPF_ENTRY_BYTES); if (!buf || !zero) die("out of memory"); }
	unsigned old = t->parity;
	t->parity ^= 1; k = 0; v = t->parity;
	if (bpf_map_update(t->ctrl_fd, &k, &v) < 0) FAIL("bpf control map update: %s", strerror(errno));
	usleep(10000);   /* handlers that read the old parity before the update have long finished */
	for (i = 0; i < t->nvols; i++) bitmap_or_into(&t->vols[i].pending, &t->vols[i].cur);   /* ring entries of the epoch just closed, drained earlier */
	if (bpf_drain_ring(t, old) < 0) return -1;
	for (i = 0; i < t->nvols; i++) {
		struct volume *vol = &t->vols[i];
		uint64_t entries = (vol->chunks + BPF_ENTRY_BYTES - 1) / BPF_ENTRY_BYTES, e;
		for (e = 0; e < entries; e++) {
			k = (uint32_t)(vol->bpf_base + e + old * t->bpf_total);
			if (bpf_map_lookup(t->map_fd, &k, buf) < 0) FAIL("bpf map lookup %u: %s", k, strerror(errno));
			/* scan 8 bytes at a time; set bits are rare compared to the scan */
			const uint64_t *w = (const uint64_t *)buf; int dirty = 0;
			for (uint64_t j = 0; j < BPF_ENTRY_BYTES / 8; j++) {
				if (!w[j]) continue;
				dirty = 1;
				for (int b = 0; b < 8; b++) if (buf[j * 8 + b]) {
					uint64_t chunk = e * BPF_ENTRY_BYTES + j * 8 + b;
					if (chunk < vol->chunks) bitmap_set(&vol->pending, chunk);
				}
			}
			if (dirty && bpf_map_update(t->map_fd, &k, zero) < 0) FAIL("bpf map clear %u: %s", k, strerror(errno));
		}
	}
	return 0;
}

static uint64_t bpf_lost(struct tracker *t)
{
	uint32_t k = 1; uint64_t v = 0;
	if (bpf_map_lookup(t->ctrl_fd, &k, &v) < 0) v = 0;
	return v + t->ring_lost;
}

static void bpf_stop(struct tracker *t)
{
	for (int i = 0; i < t->nperf; i++) { ioctl(t->perf_fds[i], PERF_EVENT_IOC_DISABLE, 0); close(t->perf_fds[i]); }
	free(t->perf_fds); t->perf_fds = NULL; t->nperf = 0;
	if (t->prog_fd > 0) close(t->prog_fd);
	if (t->map_fd > 0) close(t->map_fd);
	if (t->ctrl_fd > 0) close(t->ctrl_fd);
	if (t->ring_fd > 0) close(t->ring_fd);
	t->prog_fd = t->map_fd = t->ctrl_fd = t->ring_fd = -1;
	free(t->ring_drained); t->ring_drained = NULL;
	for (int i = 0; i < t->nvols; i++) bitmap_free(&t->vols[i].cur);
}

/* ---- ftrace ------------------------------------------------------------ */

static void ft_path(struct tracker *t, char *buf, size_t n, const char *rel) { snprintf(buf, n, "%s/%s", t->tracefs, rel); }

static uint64_t ft_overruns(struct tracker *t)
{
	char dir[256], path[320]; DIR *d; struct dirent *de; uint64_t sum = 0;
	ft_path(t, dir, sizeof dir, "per_cpu");
	d = opendir(dir); if (!d) return 0;
	while ((de = readdir(d))) {
		if (strncmp(de->d_name, "cpu", 3)) continue;
		snprintf(path, sizeof path, "%s/%s/stats", dir, de->d_name);
		FILE *fp = fopen(path, "r"); if (!fp) continue;
		char line[128];
		while (fgets(line, sizeof line, fp)) if (!strncmp(line, "overrun:", 8)) sum += strtoull(line + 8, NULL, 10);
		fclose(fp);
	}
	closedir(d);
	return sum;
}

static void ft_event(struct tracker *t, unsigned maj, unsigned min, uint64_t sector, uint64_t nr)
{
	for (int i = 0; i < t->nvols; i++) {
		struct volume *v = &t->vols[i];
		if (v->tmaj != maj || v->tmin != min) continue;
		uint64_t end = v->toff + v->size / SECTOR;
		if (sector + nr <= v->toff || sector >= end) continue;
		uint64_t s0 = sector > v->toff ? sector - v->toff : 0;
		uint64_t s1 = sector + nr - 1; if (s1 >= end) s1 = end - 1; s1 -= v->toff;
		int shift = t->chunk_shift - 9;
		uint64_t c0 = s0 >> shift, c1 = s1 >> shift;
		int both = t->grace_until > 0 && now_s() < t->grace_until;
		for (uint64_t c = c0; c <= c1 && c < v->chunks; c++) {
			bitmap_set(&v->cur, c);
			if (both) bitmap_set(&v->closed, c);
		}
	}
}

static void *ft_consumer(void *arg)
{
	struct tracker *t = arg;
	static char buf[1 << 16]; size_t have = 0;
	for (;;) {
		ssize_t r = read(t->pipe_fd, buf + have, sizeof buf - have - 1);
		if (r < 0) { if (errno == EINTR) continue; break; }
		if (r == 0) break;
		have += r; buf[have] = 0;
		char *line = buf, *nl;
		while ((nl = memchr(line, '\n', have - (line - buf)))) {
			*nl = 0;
			char *p = strstr(line, ": block_bio_queue: ");
			if (p) {
				unsigned maj, min; char rwbs[16]; unsigned long long sec, nr;
				/* every bio that is not a read: writes, write-zeroes ("N"), discards
				 * ("D"), flushes carrying data. The copy must match the source byte
				 * for byte, and a discarded range reads back as zeros. */
				if (sscanf(p + 19, "%u,%u %15s %llu + %llu", &maj, &min, rwbs, &sec, &nr) == 5 && nr && rwbs[0] != 'R' && rwbs[1] != 'R')
					ft_event(t, maj, min, sec, nr);
			} else if ((p = strstr(line, ": tracing_mark_write: RELOCA "))) {
				int k = atoi(p + 29);
				/* The epoch ends here: what came before the marker is in cur, which
				 * becomes closed. But trace_pipe merges per-cpu buffers by timestamp
				 * only among the events already sitting in them: with writers running,
				 * an event recorded BEFORE the marker can still be read after it. So
				 * for a grace window every event goes into BOTH halves - into closed,
				 * so this pass takes it, and into cur, in case it really was a later
				 * write. Re-sending a clean chunk costs nothing; missing a dirty one
				 * costs the copy. The PoC covered the same race with a 2 s overlap
				 * (DEVLOG 2026-10-21); the agent had nothing until a /boot on md
				 * RAID1 came out different under load (2026-10-22). */
				for (int i = 0; i < t->nvols; i++) {
					struct volume *v = &t->vols[i];
					struct bitmap tmp = v->closed; v->closed = v->cur; v->cur = tmp;
				}
				t->grace_until = now_s() + t->grace_s;
				__atomic_store_n(&t->flip_seen, k, __ATOMIC_RELEASE);
			}
			line = nl + 1;
		}
		have -= line - buf;
		memmove(buf, line, have);
	}
	return NULL;
}

static int ft_start(struct tracker *t)
{
	char path[256], filter[2048]; int n = 0, i, j;
	ft_path(t, path, sizeof path, "events/block/block_bio_queue/enable");
	if (access(path, W_OK) < 0) FAIL("no block_bio_queue tracepoint under %s", t->tracefs);
	ft_path(t, path, sizeof path, "tracing_on"); write_file_str(path, "0");
	ft_path(t, path, sizeof path, "current_tracer"); write_file_str(path, "nop");
	ft_path(t, path, sizeof path, "events/block/block_bio_queue/enable"); write_file_str(path, "0");
	ft_path(t, path, sizeof path, "buffer_size_kb"); write_file_str(path, "16384");
	ft_path(t, path, sizeof path, "trace"); write_file_str(path, "");
	/* the filter: our devices (each once), not reads */
	n += snprintf(filter + n, sizeof filter - n, "(");
	for (i = 0; i < t->nvols; i++) {
		for (j = 0; j < i; j++) if (t->vols[j].tmaj == t->vols[i].tmaj && t->vols[j].tmin == t->vols[i].tmin) break;
		if (j < i) continue;
		n += snprintf(filter + n, sizeof filter - n, "%sdev == %llu", n > 1 ? " || " : "", ((unsigned long long)t->vols[i].tmaj << 20) | t->vols[i].tmin);
	}
	n += snprintf(filter + n, sizeof filter - n, ")");
	ft_path(t, path, sizeof path, "events/block/block_bio_queue/filter");
	{
		char f2[2200]; snprintf(f2, sizeof f2, "%s && rwbs !~ \"R*\"", filter);
		if (write_file_str(path, f2) < 0 && write_file_str(path, filter) < 0) write_file_str(path, "0");
	}
	for (i = 0; i < t->nvols; i++) {
		if (bitmap_alloc(&t->vols[i].cur, t->vols[i].chunks) < 0 || bitmap_alloc(&t->vols[i].closed, t->vols[i].chunks) < 0) FAIL("out of memory");
	}
	t->grace_s = 0.3; t->grace_until = 0;   /* the delivery race above; 300 ms is plenty for trace_pipe */
	ft_path(t, path, sizeof path, "trace_pipe");
	t->pipe_fd = open(path, O_RDONLY | O_CLOEXEC);
	if (t->pipe_fd < 0) FAIL("open %s: %s", path, strerror(errno));
	t->ov0 = ft_overruns(t);
	t->flip_seen = 0;
	if (pthread_create(&t->thread, NULL, ft_consumer, t)) FAIL("pthread_create: %s", strerror(errno));
	ft_path(t, path, sizeof path, "events/block/block_bio_queue/enable"); write_file_str(path, "1");
	ft_path(t, path, sizeof path, "tracing_on"); write_file_str(path, "1");
	t->mode = 2;
	return 0;
}

static int ft_flip(struct tracker *t)
{
	char path[256], m[32]; int k = ++t->flip_req, i;
	ft_path(t, path, sizeof path, "trace_marker");
	snprintf(m, sizeof m, "RELOCA %d", k);
	if (write_file_str(path, m) < 0) FAIL("write trace_marker: %s", strerror(errno));
	for (i = 0; i < 2000; i++) {
		if (__atomic_load_n(&t->flip_seen, __ATOMIC_ACQUIRE) == k) break;
		usleep(10000);
	}
	if (i == 2000) FAIL("the trace consumer did not see marker %d within 20 s", k);
	/* let the grace window pass: events recorded before the marker but read after it
	 * are still landing in closed (ft_event puts them in both halves meanwhile) */
	usleep((useconds_t)(t->grace_s * 1e6) + 20000);
	for (i = 0; i < t->nvols; i++) bitmap_or_into(&t->vols[i].pending, &t->vols[i].closed);
	return 0;
}

static void ft_stop(struct tracker *t)
{
	char path[256];
	ft_path(t, path, sizeof path, "events/block/block_bio_queue/enable"); write_file_str(path, "0");
	ft_path(t, path, sizeof path, "events/block/block_bio_queue/filter"); write_file_str(path, "0");
	ft_path(t, path, sizeof path, "tracing_on"); write_file_str(path, "0");
	if (t->thread) { pthread_cancel(t->thread); pthread_join(t->thread, NULL); t->thread = 0; }
	if (t->pipe_fd > 0) { close(t->pipe_fd); t->pipe_fd = -1; }
	ft_path(t, path, sizeof path, "trace"); write_file_str(path, "");
	for (int i = 0; i < t->nvols; i++) { bitmap_free(&t->vols[i].cur); bitmap_free(&t->vols[i].closed); }
}

/* ---- the interface ----------------------------------------------------- */

int tracker_start(struct tracker *t, const char *want)
{
	int i;
	if (!find_tracefs(t->tracefs, sizeof t->tracefs)) FAIL("no tracefs (neither /sys/kernel/tracing nor /sys/kernel/debug/tracing)");
	for (i = 0; i < t->nvols; i++) {
		t->vols[i].chunks = (t->vols[i].size + (1ULL << t->chunk_shift) - 1) >> t->chunk_shift;
		if (bitmap_alloc(&t->vols[i].pending, t->vols[i].chunks) < 0) FAIL("out of memory");
	}
	if (!strcmp(want, "bpf") || !strcmp(want, "auto")) {
		t->prog_fd = t->map_fd = t->ctrl_fd = t->ring_fd = -1;
		if (bpf_start(t) == 0) return 0;
		bpf_stop(t);
		if (!strcmp(want, "bpf")) return -1;
		logf_("bpf tracker unavailable (%s): falling back to ftrace", t->err);
	}
	return ft_start(t);
}

int tracker_flip(struct tracker *t) { return t->mode == 1 ? bpf_flip(t) : ft_flip(t); }
uint64_t tracker_lost(struct tracker *t) { return t->mode == 1 ? bpf_lost(t) : (t->mode == 2 ? ft_overruns(t) - t->ov0 : 0); }
void tracker_stop(struct tracker *t)
{
	if (t->mode == 1) bpf_stop(t); else if (t->mode == 2) ft_stop(t);
	t->mode = 0;
}
