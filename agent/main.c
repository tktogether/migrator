/* agent/main.c — migrator-agent: serve (donor), pull (recipient), probe, hash.
 *
 * Protocol (serve's stdin -> commands, stdout -> frames), one line each; a
 * data frame carries LEN raw bytes right after its line:
 *   hello                    -> ok hello version= kernel= arch=
 *   comp none|zstd[:LEVEL]   -> ok comp mode= level=   (data frames only, never the session)
 *   vol ID PATH              -> ok vol id= dev= size= fs= mnt= trace=MAJ:MIN off=SECTORS
 *   track MODE CHUNK         -> ok track mode=bpf|ftrace chunk=
 *   epoch SETTLE_MS MAX_MS   -> ok epoch n= dirty=ID:BYTES,... lost=   (closes the epoch of every volume into its pending set)
 *   full ID                  -> data/zero frames, stat full ..., ok full id=
 *   send ID                  -> data frames of the pending set, stat send ..., ok send id=
 *   freeze                   -> ok freeze n= secs=     (every mounted volume, deepest mountpoint first)
 *   thaw                     -> ok thaw
 *   hash ID                  -> hash ID HEX, ok hash id= secs=
 *   quit [thaw]              -> ok quit (and exit)
 *   anything failing         -> err TEXT (the session goes on; pull stops)
 * Frames: data ID OFF LEN · zdata ID OFF RAW COMP (zstd payload) · zero ID OFF LEN ·
 *         stat k=v ... · log TEXT · hash ID HEX · ok ... · err ...
 * Compression sits on the PAYLOAD OF ONE FRAME, never on the session: the session is
 * interactive (a command, then its answer), and a stream compressor holds a short write
 * in its buffer, so the first "ok hello" never arrives - that is what "serve | gzip" did
 * (2026-10-21). One zstd call per frame keeps every frame self-contained and flushed,
 * and a frame that does not shrink is sent raw.
 *
 * The cutover, hours later and without a new ssh login (sshd would write
 * lastlog/wtmp on the frozen root and hang): "quit poll HOST PORT TOKEN" leaves
 * the donor frozen and spawns "migrator-agent poll", a detached process that
 * keeps connecting to the recipient's HOST:PORT; "migrator-agent cutover --port
 * PORT --token TOKEN netdown|poweroff|thaw|ping|exit" on the recipient answers
 * the next poll with that command. The donor's firewall is no obstacle: the
 * connection goes out from the donor. A recipient that never comes back must
 * not leave the donor frozen until someone visits its console: when the poller
 * has not reached the recipient for MIGRATOR_POLL_THAW_AFTER seconds (default
 * 1800), or for the one-week cap at the latest, it thaws the mountpoints it was
 * given and exits.
 *
 * pull runs the whole thing from the recipient (docs/DEVLOG.md 2026-10-21):
 * pass 1 = full copy of every volume; then epochs: the dirty bytes of the
 * closed epoch decide (estimated send time at the measured rate <= converge
 * -> freeze; too many passes, not shrinking, or 3x the data sent -> not
 * converging: freeze anyway when the estimate is under --max-est with
 * --freeze auto, ask on stdin with --freeze ask, give up with never); after
 * the freeze one more epoch and the final sends; then optionally a hash of
 * every frozen volume against what was written.
 */
#include "agent.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/sysmacros.h>
#include <sys/utsname.h>
#include <linux/fs.h>
#include <zstd.h>
#include <linux/reboot.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <dirent.h>
#include <limits.h>

/* ---- util ---------------------------------------------------------------- */

void die(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	fprintf(stderr, "migrator-agent: "); vfprintf(stderr, fmt, ap); fprintf(stderr, "\n");
	va_end(ap); exit(1);
}
void logf_(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	fprintf(stderr, "migrator-agent: "); vfprintf(stderr, fmt, ap); fprintf(stderr, "\n");
	va_end(ap);
}
double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }
ssize_t write_all(int fd, const void *buf, size_t n)
{
	const char *p = buf; size_t left = n;
	while (left) {
		ssize_t w = write(fd, p, left);
		if (w < 0) { if (errno == EINTR) continue; return -1; }
		p += w; left -= w;
	}
	return (ssize_t)n;
}
int read_file_str(const char *path, char *buf, size_t n)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC); ssize_t r;
	if (fd < 0) return -1;
	r = read(fd, buf, n - 1); close(fd);
	if (r < 0) return -1;
	buf[r] = 0;
	while (r > 0 && (buf[r - 1] == '\n' || buf[r - 1] == ' ')) buf[--r] = 0;
	return (int)r;
}
long read_file_long(const char *path, long dflt)
{
	char b[64]; if (read_file_str(path, b, sizeof b) < 0) return dflt; return strtol(b, NULL, 10);
}
int write_file_str(const char *path, const char *s)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC); ssize_t r;
	if (fd < 0) return -1;
	r = write(fd, s, strlen(s)); close(fd);
	return r < 0 ? -1 : 0;
}
static void *aligned_buf(size_t n)
{
	void *p; if (posix_memalign(&p, 4096, n)) die("out of memory (%zu bytes)", n); return p;
}
static int is_zero(const void *buf, size_t n)
{
	const uint64_t *w = buf; size_t i, nw = n / 8;
	for (i = 0; i < nw; i++) if (w[i]) return 0;
	for (i = nw * 8; i < n; i++) if (((const uint8_t *)buf)[i]) return 0;
	return 1;
}
static uint64_t parse_size(const char *s)
{
	char *e; double v = strtod(s, &e);
	switch (*e) { case 'k': case 'K': v *= 1024; break; case 'm': case 'M': v *= 1048576; break; case 'g': case 'G': v *= 1073741824.0; break; case 't': case 'T': v *= 1099511627776.0; break; }
	return (uint64_t)v;
}
static const char *mib(uint64_t b, char *buf, size_t n) { snprintf(buf, n, "%.1f MiB", b / 1048576.0); return buf; }

/* ---- the volume behind a path ------------------------------------------- */

static int blk_size(const char *dev, uint64_t *size)
{
	int fd = open(dev, O_RDONLY | O_CLOEXEC); int r;
	if (fd < 0) return -1;
	r = ioctl(fd, BLKGETSIZE64, size); close(fd);
	return r;
}

/* /proc/self/mountinfo: find by mountpoint (want_mnt) or by device (maj:min) */
static int mountinfo_find(const char *want_mnt, unsigned maj, unsigned min, char *mnt, size_t mn, char *fstype, size_t fn, char *src, size_t sn)
{
	FILE *fp = fopen("/proc/self/mountinfo", "r"); char line[4096]; int found = 0;
	if (!fp) return -1;
	while (fgets(line, sizeof line, fp)) {
		unsigned a, b; char mp[1024], fs[64], source[1024]; char *dash;
		if (sscanf(line, "%*d %*d %u:%u %*s %1023s", &a, &b, mp) != 3) continue;
		dash = strstr(line, " - "); if (!dash) continue;
		if (sscanf(dash + 3, "%63s %1023s", fs, source) != 2) continue;
		/* \040 escapes in the mountpoint */
		for (char *q = mp; (q = strstr(q, "\\040")); ) { *q = ' '; memmove(q + 1, q + 4, strlen(q + 4) + 1); }
		if (want_mnt ? !strcmp(mp, want_mnt) : (a == maj && b == min)) {
			snprintf(mnt, mn, "%s", mp); snprintf(fstype, fn, "%s", fs); snprintf(src, sn, "%s", source);
			if (!want_mnt) { /* the first mount of the device wins unless a later one is the shortest path */ found = 1; break; }
			found = 1; break;
		}
	}
	fclose(fp);
	return found ? 0 : -1;
}

static int resolve_volume(struct volume *v, const char *path, char *err, size_t en)
{
	struct stat st; char real[PATH_MAX], src[1024], sys[256], buf[256];
	snprintf(v->path, sizeof v->path, "%s", path);
	if (!realpath(path, real)) { snprintf(err, en, "%s: %s", path, strerror(errno)); return -1; }
	if (stat(real, &st) < 0) { snprintf(err, en, "%s: %s", real, strerror(errno)); return -1; }
	if (S_ISDIR(st.st_mode)) {
		if (mountinfo_find(real, 0, 0, v->mnt, sizeof v->mnt, v->fstype, sizeof v->fstype, src, sizeof src) < 0) { snprintf(err, en, "%s is not a mountpoint", real); return -1; }
		if (stat(src, &st) < 0 || !S_ISBLK(st.st_mode)) { snprintf(err, en, "%s is mounted from %s, not a block device", real, src); return -1; }
		v->maj = major(st.st_rdev); v->min = minor(st.st_rdev);
		snprintf(v->dev, sizeof v->dev, "%s", src);
	} else if (S_ISBLK(st.st_mode)) {
		v->maj = major(st.st_rdev); v->min = minor(st.st_rdev);
		snprintf(v->dev, sizeof v->dev, "%s", real);
		if (mountinfo_find(NULL, v->maj, v->min, v->mnt, sizeof v->mnt, v->fstype, sizeof v->fstype, src, sizeof src) < 0) { v->mnt[0] = 0; v->fstype[0] = 0; }
	} else { snprintf(err, en, "%s: neither a directory nor a block device", real); return -1; }
	if (blk_size(v->dev, &v->size) < 0) { snprintf(err, en, "%s: BLKGETSIZE64: %s", v->dev, strerror(errno)); return -1; }
	snprintf(sys, sizeof sys, "/sys/dev/block/%u:%u", v->maj, v->min);
	snprintf(buf, sizeof buf, "%s/partition", sys);
	if (access(buf, F_OK) == 0) {
		unsigned a, b; char dev[64];
		snprintf(buf, sizeof buf, "%s/../dev", sys);
		if (read_file_str(buf, dev, sizeof dev) < 0 || sscanf(dev, "%u:%u", &a, &b) != 2) { snprintf(err, en, "%s: cannot find the disk of this partition", v->dev); return -1; }
		v->tmaj = a; v->tmin = b;
		snprintf(buf, sizeof buf, "%s/start", sys);
		v->toff = (uint64_t)read_file_long(buf, -1);
		if ((long)v->toff < 0) { snprintf(err, en, "%s: no start in sysfs", v->dev); return -1; }
	} else { v->tmaj = v->maj; v->tmin = v->min; v->toff = 0; }
	snprintf(v->tdev_sys, sizeof v->tdev_sys, "/sys/dev/block/%u:%u", v->tmaj, v->tmin);
	return 0;
}

/* in-flight writes of a device, from sysfs; -1 when unknown */
static long inflight_writes(const struct volume *v)
{
	char path[300], s[64]; long r, w;
	snprintf(path, sizeof path, "/sys/dev/block/%u:%u/inflight", v->maj, v->min);
	if (read_file_str(path, s, sizeof s) < 0) return -1;
	if (sscanf(s, "%ld %ld", &r, &w) != 2) return -1;
	return w;
}

/* ---- serve (the donor) -------------------------------------------------- */

static struct volume S_vols[MAX_VOLS];
static int S_nvols;
static struct tracker S_tracker;
static int S_chunk_shift;
static uint64_t S_run = DEFAULT_RUN;
static uint8_t *S_buf;
static int S_comp;                  /* 0 none, 1 zstd */
static double S_ctime;              /* seconds spent compressing in this pass: the donor's cpu, measured */
static int S_clevel = 1;
static uint8_t *S_zbuf; static size_t S_zcap;
static int S_frozen_fds[2 * MAX_VOLS], S_nfrozen;
static char S_mnts[MAX_VOLS][256]; static int S_nmnts;   /* freeze-only mountpoints (files volumes) */
static int S_out = 1;

static void out_line(const char *fmt, ...)
{
	char line[4096]; va_list ap; int n;
	va_start(ap, fmt); n = vsnprintf(line, sizeof line - 1, fmt, ap); va_end(ap);
	if (n < 0) return;
	if (n > (int)sizeof line - 2) n = sizeof line - 2;
	line[n++] = '\n';
	if (write_all(S_out, line, n) < 0) exit(1);
}
#define OK(...) out_line("ok " __VA_ARGS__)
#define ERR(...) out_line("err " __VA_ARGS__)

static struct volume *S_find(int id) { for (int i = 0; i < S_nvols; i++) if (S_vols[i].id == id) return &S_vols[i]; return NULL; }

static int S_read(struct volume *v, uint64_t off, uint64_t len)
{
	uint64_t got = 0;
	while (got < len) {
		ssize_t r = pread(v->fd, S_buf + got, len - got, off + got);
		if (r < 0) { if (errno == EINTR) continue; return -1; }
		if (r == 0) break;
		got += r;
	}
	return got == len ? 0 : -1;
}

static int S_emit_range(struct volume *v, uint64_t off, uint64_t len, int allow_zero, uint64_t *data, uint64_t *zero)
{
	if (S_read(v, off, len) < 0) { ERR("read %s at %llu+%llu: %s", v->dev, (unsigned long long)off, (unsigned long long)len, strerror(errno)); return -1; }
	if (allow_zero && is_zero(S_buf, len)) { out_line("zero %d %llu %llu", v->id, (unsigned long long)off, (unsigned long long)len); *zero += len; return 0; }
	if (S_comp && S_zbuf) {
		/* one shot per frame: no stream state, nothing held back, and a frame that does
		 * not shrink by at least ~1.5% goes raw, so incompressible data (already
		 * compressed files, an encrypted volume) costs cpu and nothing else */
		double ct0 = now_s();
		size_t n = ZSTD_compress(S_zbuf, S_zcap, S_buf, len, S_clevel);
		S_ctime += now_s() - ct0;
		if (!ZSTD_isError(n) && n && n < len - len / 64) {
			out_line("zdata %d %llu %llu %llu", v->id, (unsigned long long)off, (unsigned long long)len, (unsigned long long)n);
			if (write_all(S_out, S_zbuf, n) < 0) exit(1);
			*data += len;
			return 0;
		}
	}
	out_line("data %d %llu %llu", v->id, (unsigned long long)off, (unsigned long long)len);
	if (write_all(S_out, S_buf, len) < 0) exit(1);
	*data += len;
	return 0;
}

static void S_full(struct volume *v)
{
	uint64_t off, data = 0, zero = 0; double t0 = now_s();
	S_ctime = 0;
	if (v->pending.w) memset(v->pending.w, 0, v->pending.nwords * sizeof(uint64_t));
	for (off = 0; off < v->size; off += S_run) {
		uint64_t len = v->size - off < S_run ? v->size - off : S_run;
		if (S_emit_range(v, off, len, 1, &data, &zero) < 0) return;
	}
	out_line("stat full id=%d data=%llu zero=%llu secs=%.2f csecs=%.2f", v->id, (unsigned long long)data, (unsigned long long)zero, now_s() - t0, S_ctime);
	OK("full id=%d", v->id);
}

static void S_send(struct volume *v, int final)
{
	uint64_t c = 0, data = 0, zero = 0, runs = 0, chunks = 0; double t0 = now_s();
	S_ctime = 0;
	uint64_t maxc = S_run >> S_chunk_shift; if (!maxc) maxc = 1;
	struct bitmap *b = &v->pending;
	while (c < v->chunks) {
		uint64_t w = b->w[c >> 6];
		if (!w) { c = (c | 63) + 1; continue; }
		if (!bitmap_test(b, c)) { c++; continue; }
		uint64_t first = c, last = c;
		while (last + 1 < v->chunks && last + 1 - first < maxc && bitmap_test(b, last + 1)) last++;
		uint64_t off = first << S_chunk_shift, len = (last - first + 1) << S_chunk_shift;
		if (off + len > v->size) len = v->size - off;
		chunks += last - first + 1; runs++;
		if (S_emit_range(v, off, len, 0, &data, &zero) < 0) return;
		c = last + 1;
	}
	memset(b->w, 0, b->nwords * sizeof(uint64_t));
	out_line("stat send id=%d kind=%s chunks=%llu bytes=%llu runs=%llu secs=%.2f csecs=%.2f", v->id, final ? "final" : "delta",
		(unsigned long long)chunks, (unsigned long long)data, (unsigned long long)runs, now_s() - t0, S_ctime);
	OK("send id=%d", v->id);
}

static uint64_t S_lost_seen;
static void S_epoch(long settle_ms, long max_ms)
{
	double t0 = now_s(); char dirty[2048]; int n = 0, i; uint64_t lost;
	if (S_tracker.mode == 0) { ERR("epoch: no tracker (track first)"); return; }
	/* push the page cache to the disk first, so a pass sees what the
	 * applications wrote instead of leaving it all to the final delta (the
	 * freeze will flush it anyway); not on a frozen filesystem */
	if (!S_nfrozen) for (i = 0; i < S_nvols; i++) {
		if (!S_vols[i].mnt[0]) continue;
		int fd = open(S_vols[i].mnt, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		if (fd >= 0) { syncfs(fd); close(fd); }
	}
	if (tracker_flip(&S_tracker) < 0) { ERR("epoch: %s", S_tracker.err); return; }
	/* settle: a bio queued before the flip may still be in flight; wait until
	 * nothing is, but at least settle_ms and at most max_ms */
	for (;;) {
		double el = (now_s() - t0) * 1000; long inf = 0;
		for (i = 0; i < S_nvols; i++) { long w = inflight_writes(&S_vols[i]); if (w > 0) inf += w; }
		if ((el >= settle_ms && inf == 0) || el >= max_ms) break;
		usleep(20000);
	}
	for (i = 0; i < S_nvols; i++)
		n += snprintf(dirty + n, sizeof dirty - n, "%s%d:%llu", i ? "," : "", S_vols[i].id, (unsigned long long)(bitmap_count(&S_vols[i].pending) << S_chunk_shift));
	lost = tracker_lost(&S_tracker);
	OK("epoch dirty=%s lost=%llu settle=%.2f", dirty, (unsigned long long)(lost - S_lost_seen), now_s() - t0);
	S_lost_seen = lost;
}


static int str_depth_cmp(const void *a, const void *b) { return (int)strlen(*(const char *const *)b) - (int)strlen(*(const char *const *)a); }
/* the mountpoints to freeze: every volume's and every "mnt", each once, deepest first */
static int S_freeze_list(const char **list)
{
	int n = 0, i, j;
	for (i = 0; i < S_nvols; i++) {
		if (!S_vols[i].mnt[0]) continue;
		for (j = 0; j < n; j++) if (!strcmp(list[j], S_vols[i].mnt)) break;
		if (j == n) list[n++] = S_vols[i].mnt;
	}
	for (i = 0; i < S_nmnts; i++) {
		for (j = 0; j < n; j++) if (!strcmp(list[j], S_mnts[i])) break;
		if (j == n) list[n++] = S_mnts[i];
	}
	qsort(list, n, sizeof list[0], str_depth_cmp);
	return n;
}
static void S_freeze(void)
{
	const char *order[2 * MAX_VOLS]; int n, i, j; double t0 = now_s();
	char skipped[1024] = ""; size_t sl = 0;
	if (S_nfrozen) { ERR("already frozen"); return; }
	n = S_freeze_list(order);
	for (i = 0; i < n; i++) {
		/* ONE ioctl per mountpoint: a second FIFREEZE on a filesystem this loop
		 * has just frozen answers EBUSY, and the error path below would leave it
		 * frozen with its fd unrecorded (seen on Rocky's /boot, 2026-10-21) */
		int fd = open(order[i], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		int rc = (fd < 0) ? -1 : ioctl(fd, FIFREEZE, 0);
		int e = errno;
		if (rc < 0 && fd >= 0 && e == EOPNOTSUPP) {
			/* vfat and friends have no freeze: an ESP changes only on a kernel or grub update, copied as it is */
			close(fd); out_line("log %s cannot be frozen (no freeze on this filesystem): copied as it is", order[i]);
			sl += snprintf(skipped + sl, sizeof skipped - sl, "%s%s", sl ? "," : "", order[i]);
			if (sl >= sizeof skipped) sl = sizeof skipped - 1;
			continue;
		}
		if (rc < 0) {
			if (fd >= 0) close(fd);
			for (j = 0; j < S_nfrozen; j++) { ioctl(S_frozen_fds[j], FITHAW, 0); close(S_frozen_fds[j]); }
			S_nfrozen = 0;
			ERR("fsfreeze %s: %s", order[i], strerror(e)); return;
		}
		S_frozen_fds[S_nfrozen++] = fd;
		out_line("log frozen %s", order[i]);
	}
	OK("freeze n=%d skipped=%s secs=%.2f", S_nfrozen, skipped[0] ? skipped : "-", now_s() - t0);
}

static void S_thaw(void)
{
	for (int j = S_nfrozen - 1; j >= 0; j--) { ioctl(S_frozen_fds[j], FITHAW, 0); close(S_frozen_fds[j]); }
	S_nfrozen = 0;
}

static void S_hash(struct volume *v)
{
	struct sha256_ctx c; uint64_t off; char hex[65]; double t0 = now_s();
	sha256_init(&c);
	for (off = 0; off < v->size; off += S_run) {
		uint64_t len = v->size - off < S_run ? v->size - off : S_run;
		if (S_read(v, off, len) < 0) { ERR("read %s at %llu: %s", v->dev, (unsigned long long)off, strerror(errno)); return; }
		sha256_update(&c, S_buf, len);
	}
	sha256_final(&c, hex);
	out_line("hash %d %s", v->id, hex);
	OK("hash id=%d secs=%.2f", v->id, now_s() - t0);
}

static int S_freeze_list(const char **list);
/* the cutover poller: a detached child of serve that, with the donor frozen and
 * this session gone, keeps connecting to the recipient (HOST:PORT, numeric)
 * and executes the one command it is handed: netdown, poweroff, thaw, ping or
 * exit. Nothing on the donor's disks is touched: the binary runs from the
 * tmpfs it was copied to, the only files it opens are /sys/class/net (the
 * interfaces) and the frozen mountpoints for FITHAW. */
static int S_spawn_poller(const char *host, const char *port, const char *token)
{
	char exe[PATH_MAX]; ssize_t n; pid_t pid; int i, argc = 0; char *argv[8 + 2 * MAX_VOLS];
	n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	if (n <= 0) return -1;
	exe[n] = 0;
	argv[argc++] = exe; argv[argc++] = "poll"; argv[argc++] = (char *)host; argv[argc++] = (char *)port; argv[argc++] = (char *)token;
	{ const char *list[2 * MAX_VOLS]; int n = S_freeze_list(list); for (i = 0; i < n && argc < 7 + 2 * MAX_VOLS; i++) argv[argc++] = (char *)list[i]; }
	argv[argc] = NULL;
	/* systemd donors: a transient service is not tied to the ssh session that
	 * spawned us. The double-fork below survived manual tests, yet the poller
	 * of a real run logged its start and then vanished before the cutover
	 * (D24); systemd-run puts it in its own unit and cgroup. */
	if (access("/run/systemd/system", F_OK) == 0) {
		const char *sr = access("/usr/bin/systemd-run", X_OK) == 0 ? "/usr/bin/systemd-run" :
		                 access("/bin/systemd-run", X_OK) == 0 ? "/bin/systemd-run" : NULL;
		if (sr) {
			char unit[64]; char *sa[16 + 2 * MAX_VOLS]; int k = 0, st = 0; pid_t sp;
			snprintf(unit, sizeof unit, "migrator-poller-%d", (int)getpid());
			sa[k++] = (char *)sr;
			sa[k++] = "--unit"; sa[k++] = unit;
			sa[k++] = "--collect";
			sa[k++] = "--service-type=exec";
			sa[k++] = "--property=StandardOutput=file:/run/migrator/poller.log";
			sa[k++] = "--property=StandardError=file:/run/migrator/poller.log";
			sa[k++] = "--";
			for (i = 0; i < argc && k < (int)(sizeof sa / sizeof *sa) - 1; i++) sa[k++] = argv[i];
			sa[k] = NULL;
			sp = fork();
			if (sp == 0) { execv(sr, sa); _exit(127); }
			if (sp > 0 && waitpid(sp, &st, 0) == sp && WIFEXITED(st) && WEXITSTATUS(st) == 0) return 0;
			/* fall through to the double-fork when systemd-run refused */
		}
	}
	pid = fork();
	if (pid < 0) return -1;
	if (pid == 0) {
		/* detach: a new session, no terminal, no inherited fds; the second fork
		 * leaves no zombie for serve to reap. stdout/stderr go to a log on the
		 * donor's tmpfs: a poller that never came up is otherwise invisible
		 * (D24: serve said poll=started but no poller existed minutes later) */
		setsid();
		if (fork() != 0) _exit(0);
		int fd = open("/dev/null", O_RDWR);
		if (fd >= 0) { dup2(fd, 0); if (fd > 2) close(fd); }
		int lg = open("/run/migrator/poller.log", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
		if (lg >= 0) { dup2(lg, 1); dup2(lg, 2); if (lg > 2) close(lg); }
		for (i = 3; i < 1024; i++) close(i);
		execv(exe, argv);
		_exit(127);
	}
	waitpid(pid, NULL, 0);
	return 0;
}

static int connect_numeric(const char *host, int port)
{
	struct sockaddr_in a4; struct sockaddr_in6 a6; int fd;
	memset(&a4, 0, sizeof a4); memset(&a6, 0, sizeof a6);
	if (inet_pton(AF_INET, host, &a4.sin_addr) == 1) {
		a4.sin_family = AF_INET; a4.sin_port = htons(port);
		fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); if (fd < 0) return -1;
		if (connect(fd, (struct sockaddr *)&a4, sizeof a4) < 0) { close(fd); return -1; }
		return fd;
	}
	if (inet_pton(AF_INET6, host, &a6.sin6_addr) == 1) {
		a6.sin6_family = AF_INET6; a6.sin6_port = htons(port);
		fd = socket(AF_INET6, SOCK_STREAM | SOCK_CLOEXEC, 0); if (fd < 0) return -1;
		if (connect(fd, (struct sockaddr *)&a6, sizeof a6) < 0) { close(fd); return -1; }
		return fd;
	}
	return -1;
}
static int read_line_fd(int fd, char *buf, size_t n, int timeout_s)
{
	size_t got = 0; struct timeval tv = { timeout_s, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	while (got + 1 < n) {
		ssize_t r = read(fd, buf + got, 1);
		if (r <= 0) return -1;
		if (buf[got] == '\n') break;
		got++;
	}
	buf[got] = 0;
	return (int)got;
}
static void ifaces_down(void)
{
	DIR *d = opendir("/sys/class/net"); struct dirent *de; int s;
	if (!d) return;
	s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	while (s >= 0 && (de = readdir(d))) {
		struct ifreq ifr;
		if (de->d_name[0] == '.' || !strcmp(de->d_name, "lo")) continue;
		memset(&ifr, 0, sizeof ifr); snprintf(ifr.ifr_name, IFNAMSIZ, "%s", de->d_name);
		if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0) continue;
		ifr.ifr_flags &= ~IFF_UP;
		ioctl(s, SIOCSIFFLAGS, &ifr);
	}
	if (s >= 0) close(s);
	closedir(d);
}
static int poll_thaw(int argc, char **argv)
{
	int bad = 0, i;
	for (i = 4; i < argc; i++) {
		int m = open(argv[i], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		/* the list names every mountpoint the transfer looked at, including the
		 * vfat ESP that cannot be frozen at all: a failed FITHAW there is not a
		 * failed rollback (seen on a bios donor with /boot/efi, D23). EINVAL is
		 * what FITHAW returns for a filesystem that is not frozen -- the ESP was
		 * never frozen, so it must not count as a failed thaw either (D27). */
		if (m < 0) { bad++; continue; }
		if (ioctl(m, FITHAW, 0) < 0 && errno != EOPNOTSUPP && errno != ENOTTY && errno != EINVAL) bad++;
		close(m);
	}
	return bad;
}
static int cmd_poll(int argc, char **argv)
{
	const char *host, *token; int port; time_t t0 = time(NULL), last_ok = time(NULL);
	long thaw_after = 1800;
	if (argc < 4) die("usage: migrator-agent poll HOST PORT TOKEN [MOUNTPOINT...]");
	host = argv[1]; port = atoi(argv[2]); token = argv[3];
	{ const char *e = getenv("MIGRATOR_POLL_THAW_AFTER"); if (e && atol(e) > 0) thaw_after = atol(e); }
	fprintf(stderr, "poll: start host=%s port=%d mounts=%d thaw_after=%ld\n", host, port, argc - 4, thaw_after);
	signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
	for (;;) {
		char line[512]; int fd, n, bad;
		/* the recipient crashed or was never rebooted: nobody will send a cutover
		 * command, so thaw rather than keep the donor frozen for a week */
		if (time(NULL) - last_ok > thaw_after || time(NULL) - t0 > 7 * 24 * 3600) {
			bad = poll_thaw(argc, argv);
			fprintf(stderr, "poll: no recipient for %ld s: thawed (%d mountpoint(s) failed)\n",
				(long)(time(NULL) - last_ok), bad);
			return bad ? 1 : 0;
		}
		fd = connect_numeric(host, port);
		if (fd < 0) { sleep(3); continue; }
		snprintf(line, sizeof line, "MIGRATOR-POLL %s\n", token);
		if (write_all(fd, line, strlen(line)) < 0 || (n = read_line_fd(fd, line, sizeof line, 30)) < 0) {
			/* A TCP connect can succeed with nothing behind it: a relay whose
			 * forwarded port has no listener passes the SYN and drops it
			 * (D35: the cutover tunnel pointed at the wrong port).  Counting
			 * that as "the recipient is there" kept last_ok fresh for ever, so
			 * the thaw below never fired and the donor stayed frozen until
			 * someone reset the machine (D36).  Only an answer counts. */
			{ static int silent; if (!silent) { fprintf(stderr, "poll: %s:%d accepts but never answers: still waiting\n", host, port); silent = 1; } }
			close(fd); sleep(3); continue;
		}
		{ static int logged; if (!logged) { fprintf(stderr, "poll: connected to %s:%d\n", host, port); logged = 1; } }
		last_ok = time(NULL);
		if (!strcmp(line, "ping")) { write_all(fd, "ok ping\n", 8); close(fd); sleep(3); continue; }
		if (!strcmp(line, "exit")) { write_all(fd, "ok exit\n", 8); close(fd); return 0; }
		if (!strcmp(line, "thaw")) {
			bad = poll_thaw(argc, argv);
			if (bad) snprintf(line, sizeof line, "err thaw: %d mountpoint(s) failed\n", bad); else snprintf(line, sizeof line, "ok thaw\n");
			write_all(fd, line, strlen(line)); close(fd);
			return bad ? 1 : 0;
		}
		if (!strcmp(line, "netdown")) {
			write_all(fd, "ok netdown\n", 11); close(fd);
			sleep(1); ifaces_down();
			return 0;
		}
		if (!strcmp(line, "poweroff")) {
			write_all(fd, "ok poweroff\n", 12); close(fd);
			sleep(1); ifaces_down();
			reboot(RB_POWER_OFF);
			return 0;
		}
		write_all(fd, "err unknown command\n", 20); close(fd); sleep(3);
	}
}
/* migrator-agent cutover --port P --token T [--timeout S] ACTION: on the recipient,
 * wait for the donor's poller and hand it ACTION; prints what it answered */
static int cmd_cutover(int argc, char **argv)
{
	int port = 0, timeout = 300, i, ls, one = 1; const char *token = NULL, *action = NULL; struct sockaddr_in6 a6; time_t t0;
	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--token") && i + 1 < argc) token = argv[++i];
		else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atoi(argv[++i]);
		else action = argv[i];
	}
	if (!port || !token || !action) die("usage: migrator-agent cutover --port P --token T [--timeout S] ping|netdown|poweroff|thaw|exit");
	ls = socket(AF_INET6, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (ls < 0) die("socket: %s", strerror(errno));
	setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	memset(&a6, 0, sizeof a6); a6.sin6_family = AF_INET6; a6.sin6_port = htons(port); a6.sin6_addr = in6addr_any;   /* dual stack: v4 too */
	if (bind(ls, (struct sockaddr *)&a6, sizeof a6) < 0 || listen(ls, 8) < 0) die("cannot listen on port %d: %s", port, strerror(errno));
	t0 = time(NULL);
	for (;;) {
		struct timeval tv = { 2, 0 }; fd_set rf; int fd; char line[512];
		if (time(NULL) - t0 > timeout) { printf("timeout: no poll from the donor on port %d within %d s\n", port, timeout); return 2; }
		FD_ZERO(&rf); FD_SET(ls, &rf);
		if (select(ls + 1, &rf, NULL, NULL, &tv) <= 0) continue;
		fd = accept(ls, NULL, NULL); if (fd < 0) continue;
		if (read_line_fd(fd, line, sizeof line, 10) < 0 || strncmp(line, "MIGRATOR-POLL ", 14) || strcmp(line + 14, token)) { close(fd); continue; }
		snprintf(line, sizeof line, "%s\n", action);
		if (write_all(fd, line, strlen(line)) < 0) { close(fd); continue; }
		if (read_line_fd(fd, line, sizeof line, 30) < 0) { printf("the donor took '%s' and went away (no answer)\n", action); close(fd); return !strcmp(action, "netdown") || !strcmp(action, "poweroff") ? 0 : 1; }
		printf("donor: %s\n", line); close(fd);
		return strncmp(line, "ok", 2) == 0 ? 0 : 1;
	}
}

static int S_keep_frozen;
static void S_atexit(void)
{
	/* a dropped session, a write error, a crash: never leave the donor frozen
	 * by accident; only "quit" (without thaw) means "stay frozen for the cutover" */
	if (!S_keep_frozen) S_thaw();
}
static int cmd_serve(int argc, char **argv)
{
	char line[1024]; struct utsname u; (void)argc; (void)argv;
	signal(SIGPIPE, SIG_IGN);
	atexit(S_atexit);
	uname(&u);
	S_buf = aligned_buf(MAX_RUN);
	while (fgets(line, sizeof line, stdin)) {
		char *a[8]; int n = 0; char *p = strtok(line, " \t\r\n");
		while (p && n < 8) { a[n++] = p; p = strtok(NULL, " \t\r\n"); }
		if (!n) continue;
		if (!strcmp(a[0], "hello")) {
			OK("hello version=%s kernel=%s arch=%s pid=%d", AGENT_VERSION, u.release, u.machine, getpid());
		} else if (!strcmp(a[0], "vol") && n >= 3) {
			char err[512]; struct volume *v;
			if (S_nvols == MAX_VOLS) { ERR("too many volumes"); continue; }
			if (S_tracker.mode) { ERR("vol after track"); continue; }
			v = &S_vols[S_nvols]; memset(v, 0, sizeof *v);
			v->id = atoi(a[1]);
			if (S_find(v->id)) { ERR("duplicate volume id %d", v->id); continue; }
			if (resolve_volume(v, a[2], err, sizeof err) < 0) { ERR("vol %s: %s", a[2], err); continue; }
			v->fd = open(v->dev, O_RDONLY | O_DIRECT | O_CLOEXEC);
			if (v->fd < 0) { ERR("open %s O_DIRECT: %s", v->dev, strerror(errno)); continue; }
			S_nvols++;
			OK("vol id=%d dev=%s size=%llu fs=%s mnt=%s trace=%u:%u off=%llu", v->id, v->dev, (unsigned long long)v->size,
				v->fstype[0] ? v->fstype : "-", v->mnt[0] ? v->mnt : "-", v->tmaj, v->tmin, (unsigned long long)v->toff);
		} else if (!strcmp(a[0], "comp") && n >= 2) {
			char *colon = strchr(a[1], ':'); int lvl = S_clevel;
			if (colon) { *colon = 0; lvl = atoi(colon + 1); }
			if (!strcmp(a[1], "none")) { S_comp = 0; OK("comp mode=none level=0"); continue; }
			if (strcmp(a[1], "zstd")) { ERR("comp %s: want none or zstd[:LEVEL]", a[1]); continue; }
			if (lvl < 1) lvl = 1;
			if (lvl > 19) lvl = 19;
			if (!S_zbuf) {
				S_zcap = ZSTD_compressBound(MAX_RUN); S_zbuf = malloc(S_zcap);
				if (!S_zbuf) { ERR("comp: out of memory for %zu bytes", S_zcap); continue; }
			}
			S_comp = 1; S_clevel = lvl;
			OK("comp mode=zstd level=%d zstd=%s", S_clevel, ZSTD_versionString());
		} else if (!strcmp(a[0], "mnt") && n >= 2) {
			/* freeze-only: a filesystem that is copied by files (tar passes) and must be frozen with the rest */
			char real[PATH_MAX]; int j;
			if (S_nmnts == MAX_VOLS) { ERR("too many mountpoints"); continue; }
			if (!realpath(a[1], real)) { ERR("mnt %s: %s", a[1], strerror(errno)); continue; }
			for (j = 0; j < S_nmnts; j++) if (!strcmp(S_mnts[j], real)) break;
			if (j == S_nmnts) snprintf(S_mnts[S_nmnts++], sizeof S_mnts[0], "%s", real);
			OK("mnt path=%s", real);
		} else if (!strcmp(a[0], "track")) {
			const char *mode = n > 1 ? a[1] : "auto"; uint64_t chunk = n > 2 ? parse_size(a[2]) : DEFAULT_CHUNK;
			if (!S_nvols) { ERR("track: no volumes"); continue; }
			if (S_tracker.mode) { ERR("already tracking"); continue; }
			if (chunk < 4096 || chunk > MAX_RUN || (chunk & (chunk - 1))) { ERR("chunk must be a power of two between 4K and 8M"); continue; }
			S_chunk_shift = __builtin_ctzll(chunk);
			memset(&S_tracker, 0, sizeof S_tracker);
			S_tracker.vols = S_vols; S_tracker.nvols = S_nvols; S_tracker.chunk_shift = S_chunk_shift;
			if (tracker_start(&S_tracker, mode) < 0) { ERR("track: %s", S_tracker.err ? S_tracker.err : "failed"); S_tracker.mode = 0; continue; }
			OK("track mode=%s chunk=%llu maxch=%u", S_tracker.mode == 1 ? "bpf" : "ftrace", (unsigned long long)chunk, S_tracker.maxch);
		} else if (!strcmp(a[0], "run") && n >= 2) {
			uint64_t r = parse_size(a[1]);
			if (r < 65536 || r > MAX_RUN) { ERR("run must be between 64K and 8M"); continue; }
			S_run = r; OK("run bytes=%llu", (unsigned long long)S_run);
		} else if (!strcmp(a[0], "epoch")) {
			S_epoch(n > 1 ? atol(a[1]) : 1000, n > 2 ? atol(a[2]) : 10000);
		} else if (!strcmp(a[0], "full") && n >= 2) {
			struct volume *v = S_find(atoi(a[1])); if (!v) { ERR("no volume %s", a[1]); continue; }
			S_full(v);
		} else if (!strcmp(a[0], "send") && n >= 2) {
			struct volume *v = S_find(atoi(a[1])); if (!v) { ERR("no volume %s", a[1]); continue; }
			S_send(v, n > 2 && !strcmp(a[2], "final"));
		} else if (!strcmp(a[0], "freeze")) {
			S_freeze();
		} else if (!strcmp(a[0], "thaw")) {
			S_thaw(); OK("thaw");
		} else if (!strcmp(a[0], "hash") && n >= 2) {
			struct volume *v = S_find(atoi(a[1])); if (!v) { ERR("no volume %s", a[1]); continue; }
			S_hash(v);
		} else if (!strcmp(a[0], "stats")) {
			OK("stats lost=%llu frozen=%d", (unsigned long long)tracker_lost(&S_tracker), S_nfrozen);
		} else if (!strcmp(a[0], "quit")) {
			int poll_at = 0;
			if (n > 1 && !strcmp(a[1], "thaw")) S_thaw(); else S_keep_frozen = 1;
			if (n > 4 && !strcmp(a[n - 4], "poll")) poll_at = n - 3;
			tracker_stop(&S_tracker);
			if (poll_at && S_spawn_poller(a[poll_at], a[poll_at + 1], a[poll_at + 2]) < 0) { ERR("cannot start the cutover poller"); S_thaw(); S_keep_frozen = 0; return 1; }
			OK("quit frozen=%d poll=%s", S_nfrozen, poll_at ? "started" : "no");
			return 0;
		} else {
			ERR("unknown command %s", a[0]);
		}
	}
	/* the session dropped: never leave the donor frozen by accident */
	S_thaw();
	tracker_stop(&S_tracker);
	return 1;
}

/* ---- pull (the recipient) ------------------------------------------------ */

struct target {
	int id; char src[256]; char dst[256]; char mnt[256];
	int unfrozen;            /* its filesystem has no freeze (vfat): the final delta is not a quiescent point */
	int prezeroed;           /* the whole target was zeroed in one call: pass 1's zero frames are then no-ops */
	uint64_t size;           /* the donor volume's size */
	int fd, fd_buf;          /* O_DIRECT and buffered fds */
	int is_blk;
	uint64_t written, zeroed;
	char donor_hash[65];
};

struct reader { int fd; char *buf; size_t head, tail, cap; int eof; int stall; };
/* Nothing at all for `stall` seconds means the path to the donor is wedged, not
 * slow: a network that goes one-way dead leaves both ends waiting forever (the
 * donor blocked in pipe_write, us in read), and without this the transfer hangs
 * until ssh's own keepalives give up ten minutes later - or longer. Seen on the
 * stand's two-VM segment at ~1M packets (2026-10-21). 0 = wait forever. */
static int reader_ready(struct reader *r)
{
	struct pollfd pfd = { .fd = r->fd, .events = POLLIN };
	int n;
	if (r->stall <= 0) return 1;
	do { n = poll(&pfd, 1, r->stall * 1000); } while (n < 0 && errno == EINTR);
	if (n == 0) { errno = ETIMEDOUT; return 0; }
	return n > 0 ? 1 : -1;
}
static int reader_fill(struct reader *r)
{
	if (r->head) { memmove(r->buf, r->buf + r->head, r->tail - r->head); r->tail -= r->head; r->head = 0; }
	if (r->tail == r->cap) return 0;
	if (reader_ready(r) != 1) return -1;
	ssize_t n = read(r->fd, r->buf + r->tail, r->cap - r->tail);
	if (n < 0) { if (errno == EINTR) return 1; return -1; }
	if (n == 0) { r->eof = 1; return 0; }
	r->tail += n; return 1;
}
static char *reader_line(struct reader *r)
{
	for (;;) {
		char *nl = memchr(r->buf + r->head, '\n', r->tail - r->head);
		if (nl) { *nl = 0; char *l = r->buf + r->head; r->head = nl + 1 - r->buf; return l; }
		if (r->eof) return NULL;
		if (reader_fill(r) < 0) return NULL;
		if (r->tail == r->cap && r->head == 0) die("line too long in the stream");
	}
}
static int reader_exact(struct reader *r, uint8_t *dst, size_t n)
{
	size_t have = r->tail - r->head;
	if (have > n) have = n;
	memcpy(dst, r->buf + r->head, have); r->head += have; n -= have; dst += have;
	while (n) {
		if (reader_ready(r) != 1) return -1;
		ssize_t k = read(r->fd, dst, n);
		if (k < 0) { if (errno == EINTR) continue; return -1; }
		if (k == 0) return -1;
		dst += k; n -= k;
	}
	return 0;
}

static struct target P_t[MAX_VOLS]; static int P_n;
static struct reader P_r;
static int P_cmd_fd;
static uint8_t *P_buf;
static pid_t P_child;
static int P_quiet;
static int P_stall = 300;      /* seconds of complete silence from the donor that count as a wedged path */
static uint8_t *P_zbuf; static size_t P_zcap;
static uint64_t P_wire_bytes;  /* what actually crossed the link in this pass */
static double P_pass_csecs;    /* seconds the donor spent compressing this pass */

static void pinfo(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt); printf("pull: "); vfprintf(stdout, fmt, ap); printf("\n"); va_end(ap); fflush(stdout);
}
static struct target *P_find(int id) { for (int i = 0; i < P_n; i++) if (P_t[i].id == id) return &P_t[i]; return NULL; }

static int P_write(struct target *t, uint64_t off, const uint8_t *buf, uint64_t len)
{
	int fd = (t->is_blk && (off % 4096 == 0) && (len % 4096 == 0)) ? t->fd : t->fd_buf;
	uint64_t done = 0;
	while (done < len) {
		ssize_t w = pwrite(fd, buf + done, len - done, off + done);
		if (w < 0) { if (errno == EINTR) continue; if (errno == EINVAL && fd == t->fd) { fd = t->fd_buf; continue; } return -1; }
		done += w;
	}
	t->written += len;
	return 0;
}
/* P_prezero: zero the WHOLE target once, before pass 1. A zero frame then costs
 * nothing. Per-frame BLKZEROOUT looked cheap and was not: ~1500 synchronous 4 MiB
 * ioctls through dm-linear on a nested VM took over ten minutes for a 9.4 GiB
 * volume, with the donor blocked in pipe_write all that time (Rocky 9,
 * 2026-10-21). One call lets the block layer offload it (write-zeroes or unmap)
 * or at least queue it properly. The copy must really hold zeros there: the
 * target disk may carry an old system, and sha256 of the copy has to match. */
static void P_prezero(struct target *t)
{
	uint64_t range[2] = { 0, t->size }; double t0 = now_s();
	if (!t->is_blk) { t->prezeroed = 1; return; }   /* a fresh O_TRUNC file reads as zeros */
	if (ioctl(t->fd_buf, BLKZEROOUT, range) == 0) {
		t->prezeroed = 1;
		pinfo("vol %d: %s zeroed in one call (%.1f s); the full pass then sends only what is not zero", t->id, t->dst, now_s() - t0);
		return;
	}
	pinfo("vol %d: %s does not take a whole-device zero (%s): every zero range is written on its own", t->id, t->dst, strerror(errno));
}
static int P_zero(struct target *t, uint64_t off, uint64_t len, int pass)
{
	t->zeroed += len;
	if (t->prezeroed) return 0;
	if (t->is_blk) {
		uint64_t range[2] = { off, len };
		if (ioctl(t->fd_buf, BLKZEROOUT, range) == 0) return 0;
	} else if (pass == 1) {
		return 0;   /* a fresh sparse file reads as zeros */
	}
	/* write zeros the slow way */
	static uint8_t *z; if (!z) z = calloc(1, MAX_RUN);
	while (len) { uint64_t n = len < MAX_RUN ? len : MAX_RUN; t->written -= n; if (P_write(t, off, z, n) < 0) return -1; off += n; len -= n; }
	return 0;
}

/* send a command and process the stream up to its ok/err; returns the ok payload (static) or NULL (err/eof) */
static uint64_t P_pass_bytes; static int P_pass;
static const char *kv(const char *s, const char *key);
static char *P_expect(const char *cmd)
{
	static char okbuf[2048]; char line[64];
	snprintf(line, sizeof line, "%s\n", cmd);
	if (write_all(P_cmd_fd, line, strlen(line)) < 0) { pinfo("cannot send '%s': %s", cmd, strerror(errno)); return NULL; }
	for (;;) {
		char *l = reader_line(&P_r);
		if (!l) {
			if (errno == ETIMEDOUT) pinfo("nothing from the donor for %d s while waiting for '%s': the path to it is wedged (the donor is NOT frozen; check the network, then run transfer again)", P_r.stall, cmd);
			else pinfo("the stream ended while waiting for '%s'", cmd);
			return NULL;
		}
		if (!strncmp(l, "data ", 5)) {
			int id; unsigned long long off, len;
			if (sscanf(l + 5, "%d %llu %llu", &id, &off, &len) != 3 || len > MAX_RUN) die("bad data frame: %s", l);
			struct target *t = P_find(id); if (!t) die("data frame for unknown volume %d", id);
			if (reader_exact(&P_r, P_buf, len) < 0) {
				if (errno == ETIMEDOUT) pinfo("nothing from the donor for %d s inside a data frame of volume %d: the path to it is wedged (the donor is NOT frozen; check the network, then run transfer again)", P_r.stall, id);
				else pinfo("the stream ended inside a data frame");
				return NULL;
			}
			if (P_write(t, off, P_buf, len) < 0) { pinfo("write %s at %llu: %s", t->dst, off, strerror(errno)); return NULL; }
			P_pass_bytes += len; P_wire_bytes += len;
		} else if (!strncmp(l, "zdata ", 6)) {
			int id; unsigned long long off, raw, comp;
			if (sscanf(l + 6, "%d %llu %llu %llu", &id, &off, &raw, &comp) != 4 || raw > MAX_RUN || comp > P_zcap) die("bad zdata frame: %s", l);
			struct target *t = P_find(id); if (!t) die("zdata frame for unknown volume %d", id);
			if (reader_exact(&P_r, P_zbuf, comp) < 0) {
				if (errno == ETIMEDOUT) pinfo("nothing from the donor for %d s inside a compressed frame of volume %d: the path to it is wedged (the donor is NOT frozen)", P_r.stall, id);
				else pinfo("the stream ended inside a compressed frame");
				return NULL;
			}
			size_t un = ZSTD_decompress(P_buf, MAX_RUN, P_zbuf, comp);
			if (ZSTD_isError(un) || un != raw) die("volume %d at %llu: cannot decompress %llu bytes into %llu (%s)", id, off, comp, raw, ZSTD_isError(un) ? ZSTD_getErrorName(un) : "short");
			if (P_write(t, off, P_buf, raw) < 0) { pinfo("write %s at %llu: %s", t->dst, off, strerror(errno)); return NULL; }
			P_pass_bytes += raw; P_wire_bytes += comp;
		} else if (!strncmp(l, "zero ", 5)) {
			int id; unsigned long long off, len;
			if (sscanf(l + 5, "%d %llu %llu", &id, &off, &len) != 3) die("bad zero frame: %s", l);
			struct target *t = P_find(id); if (!t) die("zero frame for unknown volume %d", id);
			if (P_zero(t, off, len, P_pass) < 0) { pinfo("zero %s at %llu: %s", t->dst, off, strerror(errno)); return NULL; }
		} else if (!strncmp(l, "ok ", 3) || !strcmp(l, "ok")) {
			snprintf(okbuf, sizeof okbuf, "%s", l + 2 + (l[2] == ' '));
			return okbuf;
		} else if (!strncmp(l, "err ", 4)) {
			pinfo("donor: %s", l + 4); return NULL;
		} else if (!strncmp(l, "hash ", 5)) {
			int id; char hex[65];
			if (sscanf(l + 5, "%d %64s", &id, hex) == 2) { struct target *t = P_find(id); if (t) snprintf(t->donor_hash, sizeof t->donor_hash, "%s", hex); }
		} else if (!strncmp(l, "stat ", 5)) {
			const char *cs = kv(l + 5, "csecs");
			if (cs) P_pass_csecs += atof(cs);
			if (!P_quiet) pinfo("donor %s", l + 5);
		} else if (!strncmp(l, "log ", 4)) {
			pinfo("donor: %s", l + 4);
		} else {
			pinfo("donor? %s", l);
		}
	}
}
static const char *kv(const char *s, const char *key)
{
	static char vals[8][256]; static int slot; char *val = vals[slot++ & 7];
	size_t kl = strlen(key); const char *p = s;
	while ((p = strstr(p, key))) {
		if ((p == s || p[-1] == ' ') && p[kl] == '=') {
			const char *e = strchr(p + kl + 1, ' '); size_t n = e ? (size_t)(e - p - kl - 1) : strlen(p + kl + 1);
			if (n >= 256) n = 255;
			memcpy(val, p + kl + 1, n); val[n] = 0; return val;
		}
		p += kl;
	}
	return NULL;
}

static int target_open(struct target *t)
{
	struct stat st;
	if (stat(t->dst, &st) == 0 && S_ISBLK(st.st_mode)) {
		uint64_t sz;
		t->is_blk = 1;
		t->fd = open(t->dst, O_WRONLY | O_DIRECT | O_CLOEXEC);
		t->fd_buf = open(t->dst, O_WRONLY | O_CLOEXEC);
		if (t->fd < 0 || t->fd_buf < 0) { pinfo("open %s: %s", t->dst, strerror(errno)); return -1; }
		if (ioctl(t->fd_buf, BLKGETSIZE64, &sz) < 0) { pinfo("%s: BLKGETSIZE64: %s", t->dst, strerror(errno)); return -1; }
		if (sz < t->size) { pinfo("%s is %llu bytes, the donor volume %d is %llu: too small", t->dst, (unsigned long long)sz, t->id, (unsigned long long)t->size); return -1; }
	} else {
		t->is_blk = 0;
		t->fd_buf = open(t->dst, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
		if (t->fd_buf < 0) { pinfo("open %s: %s", t->dst, strerror(errno)); return -1; }
		t->fd = t->fd_buf;
		if (ftruncate(t->fd_buf, t->size) < 0) { pinfo("truncate %s: %s", t->dst, strerror(errno)); return -1; }
	}
	return 0;
}

/* The copy was written with O_DIRECT, so reading it back buffered can hand us
 * pages some earlier reader left in the block device's cache (udev, blkid, the
 * partition scan): mixing the two on one device is not coherent. The same trap
 * cost the PoC a wrong delta. So: drop the device's cache first (BLKFLSBUF) and
 * read O_DIRECT; a device that refuses O_DIRECT falls back to buffered, which is
 * then at least reading a cache we have just emptied. */
/* P_tune_comp: pick the zstd level from two measurements, after every pass.
 *
 * The donor tells us how long it spent compressing (csecs), so we know what its
 * cpu can produce: comp_rate = raw bytes / csecs. We know what the link took:
 * wire_rate = wire bytes / seconds. Compression is free while the donor can
 * produce faster than the link can carry, and it becomes the bottleneck the
 * moment it cannot. So: climb a level while comp_rate stays well above
 * wire_rate and the data actually compresses; step back down when it does not.
 * A level that was tried and lost is not tried again (ceiling), so this settles
 * instead of oscillating. -o compress=zstd:N pins a level and skips all of it.
 */
static const int P_LEVELS[] = { 1, 3, 5, 7 };
static int P_lvl_idx, P_lvl_ceiling = 3;   /* index into P_LEVELS */
static double P_last_raw_rate;
static int P_tune_comp(double secs, uint64_t raw, uint64_t wire, double csecs, char *cmd, size_t cmdsz)
{
	double comp_rate, wire_rate, raw_rate, ratio;
	int want = P_lvl_idx;
	if (secs <= 0.05 || raw < 32u << 20 || csecs <= 0.001) return 0;   /* too little to judge */
	raw_rate = raw / secs;
	wire_rate = wire / secs;
	comp_rate = raw / csecs;
	ratio = wire ? (double)raw / (double)wire : 1.0;
	/* the donor's cpu is the limit: come down, and remember not to go back up */
	if (comp_rate < wire_rate * 1.2) {
		if (P_lvl_idx > 0) { P_lvl_ceiling = P_lvl_idx - 1; want = P_lvl_idx - 1; }
	} else if (comp_rate > wire_rate * 2.0 && ratio > 1.15 && P_lvl_idx < P_lvl_ceiling) {
		/* the link is the limit and the data does compress: a level up is free */
		if (P_last_raw_rate == 0 || raw_rate >= P_last_raw_rate * 0.95) want = P_lvl_idx + 1;
		else P_lvl_ceiling = P_lvl_idx;
	}
	P_last_raw_rate = raw_rate;
	if (want == P_lvl_idx) return 0;
	pinfo("compression: donor %.0f MiB/s at zstd:%d, link %.0f MiB/s, ratio %.2fx -> zstd:%d",
		comp_rate / 1048576, P_LEVELS[P_lvl_idx], wire_rate / 1048576, ratio, P_LEVELS[want]);
	P_lvl_idx = want;
	snprintf(cmd, cmdsz, "comp zstd:%d", P_LEVELS[P_lvl_idx]);
	return 1;
}

static int target_hash(struct target *t, char hex[65])
{
	struct sha256_ctx c; uint64_t off; int fd, bfd;
	bfd = open(t->dst, O_RDONLY | O_CLOEXEC);
	if (bfd >= 0) { fsync(bfd); if (t->is_blk) ioctl(bfd, BLKFLSBUF, 0); close(bfd); }
	fd = open(t->dst, O_RDONLY | O_DIRECT | O_CLOEXEC);
	if (fd < 0) fd = open(t->dst, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return -1;
	sha256_init(&c);
	for (off = 0; off < t->size; off += MAX_RUN) {
		uint64_t len = t->size - off < MAX_RUN ? t->size - off : MAX_RUN, got = 0;
		while (got < len) {
			ssize_t r = pread(fd, P_buf + got, len - got, off + got);
			if (r < 0 && errno == EINVAL && got == 0 && len % 4096) {
				/* an O_DIRECT tail that is not a multiple of the block size: finish buffered */
				int b = open(t->dst, O_RDONLY | O_CLOEXEC);
				if (b < 0) { close(fd); return -1; }
				while (got < len) { r = pread(b, P_buf + got, len - got, off + got); if (r <= 0) { close(b); close(fd); return -1; } got += r; }
				close(b); break;
			}
			if (r <= 0) { close(fd); return -1; }
			got += r;
		}
		sha256_update(&c, P_buf, len);
	}
	close(fd); sha256_final(&c, hex);
	return 0;
}

static int spawn(const char *cmd)
{
	int in[2], out[2];
	if (pipe2(in, O_CLOEXEC) < 0 || pipe2(out, O_CLOEXEC) < 0) die("pipe: %s", strerror(errno));
	P_child = fork();
	if (P_child < 0) die("fork: %s", strerror(errno));
	if (P_child == 0) {
		dup2(in[0], 0); dup2(out[1], 1);
		execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
		_exit(127);
	}
	close(in[0]); close(out[1]);
	P_cmd_fd = in[1];
	P_r.fd = out[0]; P_r.cap = 1 << 20; P_r.buf = malloc(P_r.cap); P_r.head = P_r.tail = 0; P_r.eof = 0;
	P_r.stall = P_stall;
	return 0;
}

static void usage_pull(void)
{
	fprintf(stderr,
"usage: migrator-agent pull --ssh 'CMD' --vol ID=DONOR_PATH=LOCAL_DEV ... [options]\n"
"  CMD runs the donor's 'migrator-agent serve' with its stdin/stdout on this session, e.g.\n"
"    'ssh root@10.0.0.12 /run/migrator-agent serve' or '... \"serve | zstd -q -1\" | zstd -d -q'\n"
"  --chunk SIZE      dirty granularity, power of two (default 64K)\n"
"  --run SIZE        read/frame size, up to 8M (default 4M)\n"
"  --tracker MODE    auto | bpf | ftrace (default auto)\n"
"  --passes N        delta passes at most (default 8)\n"
"  --converge S      freeze once the pending delta would take <= S seconds at the measured rate (default 10)\n"
"  --patience S      extra copying worth trading for that shorter freeze (default 1800): when the measured\n"
"                    write and link rates say more passes would converge but cost more than this, stop and\n"
"                    take the window on offer instead\n"
"  --max-est S       when not converging: freeze anyway if the estimate is <= S seconds (default 100)\n"
"  --freeze MODE     auto | ask (print ASK and read go/abort on stdin) | never\n"
"  --settle MS       wait for in-flight writes after every epoch, at least this (default 1000)\n"
"  --stall SECS      complete silence from the donor for this long = a wedged path, fail instead of hanging (default 300, 0 = never)\n"
"  --compress MODE   auto (default) | none | zstd[:LEVEL]: each data frame's payload, compressed on the donor.\n"
"                    auto climbs the level while the donor's cpu stays ahead of the link and the data compresses,\n"
"                    and comes back down when it does not; both rates are measured, not assumed. Never the\n"
"                    session - a stream compressor would buffer the handshake. A frame that does not shrink goes raw.\n"
"  --verify          sha256 of every frozen volume on the donor against what was written here\n"
"  --thaw            unfreeze the donor at the end (tests); default: the donor stays frozen\n"
"  --freeze-also MNT a mountpoint copied by other means (files) that must be frozen with the rest (repeatable)\n"
"  --before-freeze C a local command run once the block passes converge, before the freeze (files passes)\n"
"  --after-freeze C  a local command run after the final block deltas, the donor frozen (the files' last pass)\n"
"  --precheck C      freeze twice: after the first final deltas thaw the donor, run C here (a pre-check on the\n"
"                    consistent copy), then catch up and freeze again; C failing ends the transfer, donor thawed\n"
"  --cutover IP:PORT the donor keeps polling this address (ours, as the donor sees it) for the cutover\n"
"                    command: 'migrator-agent cutover --port PORT --token T netdown|poweroff|thaw'; a CUTOVER line names the token\n"
"  --quiet           no donor stat lines\n");
	exit(2);
}

static int cmd_pull(int argc, char **argv)
{
	const char *ssh = NULL, *tracker = "auto", *freeze_mode = "auto"; uint64_t chunk = DEFAULT_CHUNK, run = DEFAULT_RUN;
	int passes = 8, verify = 0, thaw = 0, stall = 300; double converge = 10, max_est = 100; long settle = 1000;
	const char *cutover = NULL; char token[33] = ""; const char *compress = "auto";
	double wr_rate = 0, t_epoch = 0;   /* how fast the donor dirties blocks, and when the last epoch closed */
	double patience = 1800;            /* seconds of extra copying worth trading for a shorter freeze */
	int auto_comp = 0, noncv_now = 0;
	const char *before_freeze = NULL, *after_freeze = NULL, *precheck = NULL; const char *also[MAX_VOLS]; int nalso = 0, hooked = 0, round = 1;
	int i; char cmd[512], *ok; double t_start = now_s(), rate = 0, t0;
	uint64_t full_data = 0, total_sent = 0, prev_dirty = 0; int stalled = 0, pass;
	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--ssh") && i + 1 < argc) ssh = argv[++i];
		else if (!strcmp(argv[i], "--vol") && i + 1 < argc) {
			char *spec = argv[++i], *p1 = strchr(spec, '='), *p2 = p1 ? strchr(p1 + 1, '=') : NULL;
			if (!p1 || !p2 || P_n == MAX_VOLS) usage_pull();
			*p1 = 0; *p2 = 0;
			P_t[P_n].id = atoi(spec); snprintf(P_t[P_n].src, sizeof P_t[P_n].src, "%s", p1 + 1); snprintf(P_t[P_n].dst, sizeof P_t[P_n].dst, "%s", p2 + 1);
			P_n++;
		}
		else if (!strcmp(argv[i], "--chunk") && i + 1 < argc) chunk = parse_size(argv[++i]);
		else if (!strcmp(argv[i], "--run") && i + 1 < argc) run = parse_size(argv[++i]);
		else if (!strcmp(argv[i], "--tracker") && i + 1 < argc) tracker = argv[++i];
		else if (!strcmp(argv[i], "--passes") && i + 1 < argc) passes = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--converge") && i + 1 < argc) converge = atof(argv[++i]);
		else if (!strcmp(argv[i], "--max-est") && i + 1 < argc) max_est = atof(argv[++i]);
		else if (!strcmp(argv[i], "--freeze") && i + 1 < argc) freeze_mode = argv[++i];
		else if (!strcmp(argv[i], "--settle") && i + 1 < argc) settle = atol(argv[++i]);
		else if (!strcmp(argv[i], "--stall") && i + 1 < argc) stall = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--compress") && i + 1 < argc) compress = argv[++i];
		else if (!strcmp(argv[i], "--patience") && i + 1 < argc) patience = atof(argv[++i]);
		else if (!strcmp(argv[i], "--cutover") && i + 1 < argc) cutover = argv[++i];
		else if (!strcmp(argv[i], "--freeze-also") && i + 1 < argc && nalso < MAX_VOLS) also[nalso++] = argv[++i];
		else if (!strcmp(argv[i], "--before-freeze") && i + 1 < argc) before_freeze = argv[++i];
		else if (!strcmp(argv[i], "--after-freeze") && i + 1 < argc) after_freeze = argv[++i];
		else if (!strcmp(argv[i], "--precheck") && i + 1 < argc) precheck = argv[++i];
		else if (!strcmp(argv[i], "--verify")) verify = 1;
		else if (!strcmp(argv[i], "--thaw")) thaw = 1;
		else if (!strcmp(argv[i], "--quiet")) P_quiet = 1;
		else usage_pull();
	}
	if (!ssh || (!P_n && !nalso)) usage_pull();
	if (run > MAX_RUN) die("--run above 8M");
	signal(SIGPIPE, SIG_IGN);
	P_buf = aligned_buf(MAX_RUN);
	P_stall = stall;
	spawn(ssh);

	if (!(ok = P_expect("hello"))) goto fail;
	pinfo("donor agent %s, kernel %s %s", kv(ok, "version") ? kv(ok, "version") : "?", kv(ok, "kernel") ? kv(ok, "kernel") : "?", kv(ok, "arch") ? kv(ok, "arch") : "");
	if (kv(ok, "version") && strcmp(kv(ok, "version"), AGENT_VERSION)) pinfo("WARN: this agent is %s, the donor's is %s", AGENT_VERSION, kv(ok, "version"));
	for (i = 0; i < P_n; i++) {
		snprintf(cmd, sizeof cmd, "vol %d %s", P_t[i].id, P_t[i].src);
		if (!(ok = P_expect(cmd))) goto fail;
		P_t[i].size = strtoull(kv(ok, "size") ? kv(ok, "size") : "0", NULL, 10);
		snprintf(P_t[i].mnt, sizeof P_t[i].mnt, "%s", kv(ok, "mnt") ? kv(ok, "mnt") : "-");
		pinfo("vol %d: %s = %s (%s, mounted at %s), %llu bytes, traced on %s+%s -> %s", P_t[i].id, P_t[i].src, kv(ok, "dev"), kv(ok, "fs"), kv(ok, "mnt"),
			(unsigned long long)P_t[i].size, kv(ok, "trace"), kv(ok, "off"), P_t[i].dst);
		if (target_open(&P_t[i]) < 0) goto fail;
	}
	if (strcmp(compress, "none")) {
		P_zcap = ZSTD_compressBound(MAX_RUN); P_zbuf = aligned_buf(P_zcap);
		if (!strcmp(compress, "auto")) { auto_comp = 1; snprintf(cmd, sizeof cmd, "comp zstd:%d", P_LEVELS[P_lvl_idx]); }
		else snprintf(cmd, sizeof cmd, "comp %s", compress);
		if (!(ok = P_expect(cmd))) goto fail;
		pinfo("data frames compressed on the donor: %s (the session itself never is)%s", ok,
			auto_comp ? ", level chosen from the measured donor cpu and link" : "");
	}
	for (i = 0; i < nalso; i++) {
		snprintf(cmd, sizeof cmd, "mnt %s", also[i]);
		if (!(ok = P_expect(cmd))) goto fail;
		pinfo("freeze also: %s (copied by files)", kv(ok, "path"));
	}
	snprintf(cmd, sizeof cmd, "run %llu", (unsigned long long)run);
	if (!(ok = P_expect(cmd))) goto fail;
	if (!P_n) {
		/* nothing to copy block by block: only the freeze, the hooks and the poller */
		pinfo("no block volumes: freezing after the hooks");
		if (before_freeze) { pinfo("before the freeze: %s", before_freeze); if (system(before_freeze) != 0) { pinfo("the before-freeze command failed"); goto fail; } }
		pass = 1; goto freeze;
	}
	snprintf(cmd, sizeof cmd, "track %s %llu", tracker, (unsigned long long)chunk);
	if (!(ok = P_expect(cmd))) goto fail;
	pinfo("tracking by %s, chunk %llu", kv(ok, "mode"), (unsigned long long)chunk);
	if (!(ok = P_expect("epoch 0 0"))) goto fail;

	/* pass 1: everything, onto a target that is zero to begin with */
	P_pass = 1; P_pass_bytes = 0; P_wire_bytes = 0; P_pass_csecs = 0;
	for (i = 0; i < P_n; i++) P_prezero(&P_t[i]);
	t0 = now_s();
	for (i = 0; i < P_n; i++) {
		snprintf(cmd, sizeof cmd, "full %d", P_t[i].id);
		if (!(ok = P_expect(cmd))) goto fail;
	}
	{
		double secs = now_s() - t0; char b1[32], b2[32], b3[32], wire[96] = ""; uint64_t z = 0;
		for (i = 0; i < P_n; i++) z += P_t[i].zeroed;
		full_data = P_pass_bytes; total_sent = P_pass_bytes; rate = secs > 0 ? P_pass_bytes / secs : 0;
		if (P_wire_bytes && P_wire_bytes < P_pass_bytes)
			snprintf(wire, sizeof wire, " (%s on the wire, %.1fx)", mib(P_wire_bytes, b3, sizeof b3), (double)P_pass_bytes / (double)P_wire_bytes);
		pinfo("pass 1 full: %s data, %s zero, %.1f s, %.1f MiB/s%s", mib(P_pass_bytes, b1, sizeof b1), mib(z, b2, sizeof b2), secs, rate / 1048576, wire);
		if (auto_comp && P_tune_comp(secs, P_pass_bytes, P_wire_bytes, P_pass_csecs, cmd, sizeof cmd) && !(ok = P_expect(cmd))) goto fail;
	}

	/* the epochs; a pre-check (round 1 frozen, thawed, precheckd) is followed by round 2 */
round:
	for (pass = (round == 1 ? 2 : pass + 1); ; pass++) {
		uint64_t dirty = 0, lost; double est; const char *d; char b1[32];
		snprintf(cmd, sizeof cmd, "epoch %ld %ld", settle, settle * 10 > 10000 ? settle * 10 : 10000);
		if (!(ok = P_expect(cmd))) goto fail;
		d = kv(ok, "dirty");
		for (const char *p = d; p && *p; ) { int id; unsigned long long b; if (sscanf(p, "%d:%llu", &id, &b) == 2) dirty += b; p = strchr(p, ','); if (p) p++; }
		lost = strtoull(kv(ok, "lost") ? kv(ok, "lost") : "0", NULL, 10);
		est = rate > 0 ? dirty / rate : 0;
		noncv_now = 0;
		/* how fast the donor dirties blocks: this epoch's dirty set over the time since
		 * the previous one closed. With the link rate that is everything needed to say
		 * whether the passes can converge at all, instead of finding out in eight tries. */
		if (t_epoch > 0 && now_s() - t_epoch > 0.5) {
			/* smoothed: one epoch of a busier minute should not make the prediction
			 * jump from "35 passes" to "never" and back. Half the weight on the new
			 * measurement keeps it responsive while the printed numbers stay calm. */
			double now_rate = dirty / (now_s() - t_epoch);
			wr_rate = wr_rate > 0 ? (wr_rate + now_rate) / 2 : now_rate;
		}
		t_epoch = now_s();
		pinfo("pass %d: %s pending (%s), estimated %.1f s at %.1f MiB/s%s", pass, mib(dirty, b1, sizeof b1), d ? d : "", est, rate / 1048576, lost ? " LOST EVENTS" : "");
		if (wr_rate > 0 && rate > 0) {
			double r = wr_rate / rate; char b4[32], b5[32];
			if (r >= 0.95) {
				pinfo("the donor writes %s/s and the link carries %s/s: the deltas cannot shrink, this will not converge",
					mib((uint64_t)wr_rate, b4, sizeof b4), mib((uint64_t)rate, b5, sizeof b5));
			} else {
				/* Each pass multiplies the delta by r, so the passes still needed are
				 * log(target/delta)/log(r) and their cost is the sum of delta_i/rate.
				 * Both are printed: the operator is trading copying time for a shorter
				 * freeze, and should see the exchange rate. The trade is taken
				 * automatically only while it stays inside the patience budget. */
				double target = converge * rate, dd = (double)dirty, extra = 0; int k = 0;
				while (dd > target && k < 64) { extra += dd / rate; dd *= r; k++; }
				pinfo("the donor writes %s/s, the link carries %s/s (%.2fx): about %d more pass(es), ~%.0f min, to a %.0f s window",
					mib((uint64_t)wr_rate, b4, sizeof b4), mib((uint64_t)rate, b5, sizeof b5), r, k, extra / 60, converge);
				if (k > passes - (pass - 1)) {
					if (extra <= patience) {
						pinfo("raising the pass limit from %d to %d: it will converge, and the %.0f min of copying fit the patience budget (%.0f min)",
							passes, pass - 1 + k, extra / 60, patience / 60);
						passes = pass - 1 + k;
					} else {
						pinfo("%d more passes would take ~%.0f min, past the patience budget of %.0f min (--patience): taking the window that is on offer instead",
							k, extra / 60, patience / 60);
						noncv_now = 1;
					}
				}
			}
		}
		if (lost) {
			/* something slipped past the tracker (a ring that wrapped, a trace
			 * buffer overrun): the only safe answer is to read everything again */
			pinfo("the tracker lost %llu event(s) since the last epoch: a full pass again", (unsigned long long)lost);
			P_pass = pass; P_pass_bytes = 0; t0 = now_s();
			for (i = 0; i < P_n; i++) { snprintf(cmd, sizeof cmd, "full %d", P_t[i].id); if (!(ok = P_expect(cmd))) goto fail; }
			{ double secs = now_s() - t0; if (secs > 0.05) rate = P_pass_bytes / secs; total_sent += P_pass_bytes;
			  pinfo("pass %d full again: %s in %.1f s", pass, mib(P_pass_bytes, b1, sizeof b1), secs); }
			prev_dirty = 0; stalled = 0;
			continue;
		}
		int converged = est <= converge;
		int noncv = 0; const char *why = "";
		if (!converged) {
			if (noncv_now) { noncv = 1; why = "more passes than the patience budget allows"; }
			else if (wr_rate > 0 && rate > 0 && wr_rate / rate >= 0.95) { noncv = 1; why = "the donor writes as fast as the link carries"; }
			else if (pass - 1 > passes) { noncv = 1; why = "pass limit"; }
			else if (prev_dirty && dirty >= prev_dirty * 8 / 10) { if (++stalled >= 2) { noncv = 1; why = "delta not shrinking"; } }
			else stalled = 0;
			if (!noncv && full_data && total_sent > 3 * full_data) { noncv = 1; why = "3x the data sent"; }
		}
		if ((converged || noncv) && before_freeze && !hooked) {
			/* the files volumes catch up now (their passes), while the tracker goes on;
			 * then one more round of block deltas before the decision is final */
			hooked = 1;
			pinfo("before the freeze: %s", before_freeze);
			if (system(before_freeze) != 0) { pinfo("the before-freeze command failed"); goto fail; }
			converged = 0; noncv = 0; stalled = 0;
		}
		if (converged) { pinfo("converged at pass %d: %.1f s <= %.1f s", pass, est, converge); break; }
		if (noncv) {
			pinfo("not converging (%s): the final delta would take about %.1f s", why, est);
			if (!strcmp(freeze_mode, "never")) { pinfo("--freeze never: giving up"); goto fail; }
			if (!strcmp(freeze_mode, "ask")) {
				char ans[64]; printf("ASK freeze now? the donor would be frozen for about %.1f s (go/abort): ", est); fflush(stdout);
				if (!fgets(ans, sizeof ans, stdin) || strncmp(ans, "go", 2)) { pinfo("aborted by the operator"); goto fail; }
			} else if (est > max_est) {
				pinfo("the shortest freeze on offer is %.0f s, above the %.0f s this run was allowed (--max-est): nothing is frozen, the donor is untouched", est, max_est);
				pinfo("what changes it: a faster link, less writing on the donor while it copies, or -o max-est=%.0f if that downtime is acceptable", est + 60);
				goto fail;
			}
			break;
		}
		P_pass = pass; P_pass_bytes = 0; P_wire_bytes = 0; P_pass_csecs = 0; t0 = now_s();
		for (i = 0; i < P_n; i++) { snprintf(cmd, sizeof cmd, "send %d", P_t[i].id); if (!(ok = P_expect(cmd))) goto fail; }
		{
			double secs = now_s() - t0; char b2[32];
			if (P_pass_bytes > 4 * 1048576 && secs > 0.05) rate = P_pass_bytes / secs;
			total_sent += P_pass_bytes;
			if (P_wire_bytes && P_wire_bytes < P_pass_bytes) pinfo("pass %d sent: %s in %.1f s (%s on the wire)", pass, mib(P_pass_bytes, b1, sizeof b1), secs, mib(P_wire_bytes, b2, sizeof b2));
			else pinfo("pass %d sent: %s in %.1f s", pass, mib(P_pass_bytes, b1, sizeof b1), secs);
			if (auto_comp && P_tune_comp(secs, P_pass_bytes, P_wire_bytes, P_pass_csecs, cmd, sizeof cmd) && !(ok = P_expect(cmd))) goto fail;
		}
		prev_dirty = dirty;
	}

	/* the final: freeze, one more epoch, send everything pending, the after-freeze hook */
freeze:
	{
		double tf = now_s(), tfreeze, tsent; char b1[32]; uint64_t dirty = 0; const char *d;
		if (!(ok = P_expect("freeze"))) goto fail;
		tfreeze = now_s() - tf;
		{
			/* a filesystem without freeze (an ESP) keeps the right to change: its volume gets
			 * one more delta after the others and is reported, never silently trusted */
			const char *sk = kv(ok, "skipped"); char list[1024];
			snprintf(list, sizeof list, "%s", (sk && strcmp(sk, "-")) ? sk : "");
			for (i = 0; i < P_n; i++) {
				char needle[300]; P_t[i].unfrozen = 0;
				if (!list[0] || !P_t[i].mnt[0]) continue;
				snprintf(needle, sizeof needle, ",%s,", P_t[i].mnt);
				char padded[1100]; snprintf(padded, sizeof padded, ",%s,", list);
				if (strstr(padded, needle)) { P_t[i].unfrozen = 1; pinfo("vol %d (%s) is on a filesystem that cannot be frozen: its copy is as-of-now, not a quiescent snapshot", P_t[i].id, P_t[i].mnt); }
			}
		}
		if (P_n) {
			snprintf(cmd, sizeof cmd, "epoch 100 2000");
			if (!(ok = P_expect(cmd))) goto fail;
			d = kv(ok, "dirty");
			for (const char *p = d; p && *p; ) { int id; unsigned long long b; if (sscanf(p, "%d:%llu", &id, &b) == 2) dirty += b; p = strchr(p, ','); if (p) p++; }
			P_pass = pass; P_pass_bytes = 0;
			for (i = 0; i < P_n; i++) { snprintf(cmd, sizeof cmd, "send %d final", P_t[i].id); if (!(ok = P_expect(cmd))) goto fail; }
			/* the unfrozen ones once more: everything written while the others were sent */
			for (i = 0; i < P_n; i++) if (P_t[i].unfrozen) {
				if (!(ok = P_expect("epoch 200 3000"))) goto fail;
				snprintf(cmd, sizeof cmd, "send %d final", P_t[i].id);
				if (!(ok = P_expect(cmd))) goto fail;
			}
			for (i = 0; i < P_n; i++) { fsync(P_t[i].fd_buf); }
		}
		if (after_freeze) {
			/* the files volumes' last pass, from the frozen filesystems */
			pinfo("after the freeze: %s", after_freeze);
			if (system(after_freeze) != 0) { pinfo("the after-freeze command failed: thawing"); goto fail; }
		}
		tsent = now_s() - tf;
		pinfo("final (round %d): freeze %.2f s, %s pending, sent %s, frozen window %.2f s", round, tfreeze, mib(dirty, b1, sizeof b1), mib(P_pass_bytes, b1, sizeof b1), tsent);
		if (precheck && round == 1) {
			/* the copy is consistent now: thaw the donor (the tracker goes on), precheck
			 * on this side, then catch up with what was written meanwhile and freeze again */
			if (!(ok = P_expect("thaw"))) goto fail;
			pinfo("thawed for the pre-check: %s", precheck);
			if (system(precheck) != 0) { pinfo("the pre-check failed: the donor runs on, nothing is frozen"); goto fail; }
			pinfo("pre-check ok: catching up and freezing again");
			round = 2; hooked = 0; prev_dirty = 0; stalled = 0;
			if (P_n) goto round;
			if (before_freeze) { pinfo("before the freeze: %s", before_freeze); if (system(before_freeze) != 0) { pinfo("the before-freeze command failed"); goto fail; } }
			goto freeze;
		}
		if (verify) {
			int bad = 0;
			for (i = 0; i < P_n; i++) {
				char hex[65];
				snprintf(cmd, sizeof cmd, "hash %d", P_t[i].id);
				if (!(ok = P_expect(cmd))) goto fail;
				if (target_hash(&P_t[i], hex) < 0) { pinfo("cannot hash %s: %s", P_t[i].dst, strerror(errno)); goto fail; }
				if (!strcmp(hex, P_t[i].donor_hash)) pinfo("vol %d: sha256 %s equal", P_t[i].id, hex);
				else if (P_t[i].unfrozen) pinfo("vol %d (%s): sha256 differs (donor %.16s..., here %.16s...), as expected on a filesystem that cannot be frozen and is still being written: the copy holds every block the tracker saw", P_t[i].id, P_t[i].mnt, P_t[i].donor_hash, hex);
				else { pinfo("vol %d: MISMATCH donor %s, here %s", P_t[i].id, P_t[i].donor_hash, hex); bad = 1; }
			}
			if (bad) goto fail;
		}
		if (cutover && !thaw) {
			/* the poller: the donor stays frozen and comes to us for the cutover command */
			const char *colon = strrchr(cutover, ':'); char host[128]; uint8_t rnd[16]; int fd;
			if (!colon) die("--cutover wants HOST:PORT");
			snprintf(host, sizeof host, "%.*s", (int)(colon - cutover), cutover);
			fd = open("/dev/urandom", O_RDONLY); if (fd < 0 || read(fd, rnd, 16) != 16) die("/dev/urandom: %s", strerror(errno)); close(fd);
			for (i = 0; i < 16; i++) sprintf(token + 2 * i, "%02x", rnd[i]);
			snprintf(cmd, sizeof cmd, "quit poll %s %s %s", host, colon + 1, token);
			if (!(ok = P_expect(cmd))) goto fail;
			printf("CUTOVER host=%s port=%s token=%s\n", host, colon + 1, token);
		} else if (!(ok = P_expect(thaw ? "quit thaw" : "quit"))) goto fail;
		printf("RESULT ok passes=%d full_data=%llu total_sent=%llu final_bytes=%llu frozen_s=%.2f secs=%.1f donor=%s\n", pass, (unsigned long long)full_data,
			(unsigned long long)(total_sent + P_pass_bytes), (unsigned long long)P_pass_bytes, tsent, now_s() - t_start, thaw ? "thawed" : "frozen");
		fflush(stdout);
	}
	close(P_cmd_fd); waitpid(P_child, NULL, 0);
	return 0;
fail:
	printf("RESULT fail\n"); fflush(stdout);
	close(P_cmd_fd); kill(P_child, SIGTERM); waitpid(P_child, NULL, 0);
	return 1;
}

/* ---- probe, hash ---------------------------------------------------------- */

static int cmd_probe(int argc, char **argv)
{
	struct utsname u; char tracefs[128]; int i;
	uname(&u);
	printf("version=%s\nkernel=%s\narch=%s\n", AGENT_VERSION, u.release, u.machine);
	printf("tracefs=%s\n", find_tracefs(tracefs, sizeof tracefs) ? tracefs : "-");
	printf("bpf=%s\n", kernel_version() >= 40014 ? "maybe" : "no");
	for (i = 1; i < argc; i++) {
		struct volume v; char err[256];
		memset(&v, 0, sizeof v);
		if (resolve_volume(&v, argv[i], err, sizeof err) < 0) { printf("vol %s: ERROR %s\n", argv[i], err); continue; }
		printf("vol %s: dev=%s size=%llu fs=%s mnt=%s trace=%u:%u off=%llu inflight=%ld\n", argv[i], v.dev, (unsigned long long)v.size,
			v.fstype[0] ? v.fstype : "-", v.mnt[0] ? v.mnt : "-", v.tmaj, v.tmin, (unsigned long long)v.toff, inflight_writes(&v));
	}
	return 0;
}

static int cmd_hash(int argc, char **argv)
{
	struct sha256_ctx c; uint64_t size, off; char hex[65]; int fd; uint8_t *buf;
	if (argc < 2) die("usage: migrator-agent hash DEV_OR_FILE [BYTES]");
	fd = open(argv[1], O_RDONLY | O_CLOEXEC);
	if (fd < 0) die("%s: %s", argv[1], strerror(errno));
	if (argc > 2) size = strtoull(argv[2], NULL, 10);
	else { struct stat st; fstat(fd, &st); if (S_ISBLK(st.st_mode)) ioctl(fd, BLKGETSIZE64, &size); else size = st.st_size; }
	buf = aligned_buf(MAX_RUN); sha256_init(&c);
	for (off = 0; off < size; off += MAX_RUN) {
		uint64_t len = size - off < MAX_RUN ? size - off : MAX_RUN, got = 0;
		while (got < len) { ssize_t r = pread(fd, buf + got, len - got, off + got); if (r <= 0) die("read %s at %llu: %s", argv[1], (unsigned long long)(off + got), r ? strerror(errno) : "short"); got += r; }
		sha256_update(&c, buf, len);
	}
	sha256_final(&c, hex);
	printf("%s  %s %llu\n", hex, argv[1], (unsigned long long)size);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: migrator-agent serve | pull ... | probe [PATH...] | hash DEV [BYTES] | cutover --port P --token T ACTION | version\n"); return 2; }
	if (!strcmp(argv[1], "version")) { printf("%s\n", AGENT_VERSION); return 0; }
	if (!strcmp(argv[1], "serve")) return cmd_serve(argc - 1, argv + 1);
	if (!strcmp(argv[1], "pull")) return cmd_pull(argc - 1, argv + 1);
	if (!strcmp(argv[1], "probe")) return cmd_probe(argc - 1, argv + 1);
	if (!strcmp(argv[1], "hash")) return cmd_hash(argc - 1, argv + 1);
	if (!strcmp(argv[1], "poll")) return cmd_poll(argc - 1, argv + 1);
	if (!strcmp(argv[1], "cutover")) return cmd_cutover(argc - 1, argv + 1);
	fprintf(stderr, "migrator-agent: unknown command %s\n", argv[1]);
	return 2;
}
