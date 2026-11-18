/* agent/agent.h — reloca-agent: the on-line relocation agent of reloca.to.
 *
 * One static binary, both ends. On the donor (its own running OS) it runs
 * "serve": registers volumes, tracks every write to them (eBPF bitmap on the
 * block_bio_queue tracepoint, or an ftrace consumer where BPF is not
 * available), streams the volumes in passes (full, then only the chunks
 * written since the previous pass), freezes the filesystems for the final
 * pass. On the recipient (the Live) it runs "pull": drives one ssh session to
 * the donor's serve, writes the stream into the target devices and decides
 * when to freeze (docs/DEVLOG.md 2026-10-21, convergence thresholds).
 * Nothing is installed on the donor and its disks are only read.
 */
#ifndef RELOCA_AGENT_H
#define RELOCA_AGENT_H
#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <sys/types.h>

#ifndef AGENT_VERSION
#define AGENT_VERSION "dev"
#endif

#define MAX_VOLS 32
#define SECTOR 512ULL
#define DEFAULT_CHUNK (64 * 1024)
#define DEFAULT_RUN (4 * 1024 * 1024)
#define MAX_RUN (8 * 1024 * 1024)
#define BPF_ENTRY_BYTES (1 << 20)        /* one map value = this many chunks (a byte each) */
#define BPF_RING 1024                    /* overflow ring slots per cpu (bios longer than maxch chunks) */

struct bitmap {
	uint64_t *w;
	uint64_t nbits;
	uint64_t nwords;
};

struct volume {
	int id;
	char path[256];          /* as registered: a mountpoint or a block device */
	char dev[256];           /* the block device (resolved) */
	char mnt[256];           /* its mountpoint, "" when not mounted */
	char fstype[32];
	uint64_t size;           /* bytes */
	unsigned maj, min;       /* of the volume's device */
	unsigned tmaj, tmin;     /* of the traced device: the whole disk for a partition */
	uint64_t toff;           /* sectors: the partition's start on the traced device, else 0 */
	char tdev_sys[256];      /* /sys/dev/block/TMAJ:TMIN */
	int fd;                  /* O_DIRECT read fd (serve) */
	int chunk_shift;         /* chunk size = 1 << chunk_shift bytes */
	uint64_t chunks;
	struct bitmap cur, closed, pending; /* ftrace: cur is written by the consumer thread */
	uint64_t bpf_base;       /* first map entry of this volume (parity 0); parity 1 at + bpf_total */
	int frozen_fd;           /* the mountpoint fd while frozen (serve) */
};

struct tracker {
	int mode;                /* 0 none, 1 bpf, 2 ftrace */
	int chunk_shift;
	struct volume *vols;
	int nvols;
	char tracefs[128];
	/* bpf */
	int map_fd, ctrl_fd, ring_fd, prog_fd;
	int *perf_fds, nperf;
	uint64_t bpf_total;      /* entries per parity */
	unsigned parity;
	unsigned maxch;          /* chunks marked per bio at most (unrolled); longer bios go to the ring */
	int ncpu_possible;
	uint64_t *ring_drained;  /* per cpu: the sequence number drained up to */
	uint64_t ring_lost;
	/* ftrace */
	int pipe_fd;
	pthread_t thread;
	volatile int flip_seen;  /* the marker number the consumer saw last */
	int flip_req;
	double grace_s;          /* after a marker, how long an event still counts for the epoch just closed */
	volatile double grace_until;
	uint64_t ov0;            /* overruns at start */
	char *err;
};

/* sha256.c */
void sha256_hex(const uint8_t *data, size_t len, char out[65]);
struct sha256_ctx { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t buflen; };
void sha256_init(struct sha256_ctx *c);
void sha256_update(struct sha256_ctx *c, const uint8_t *d, size_t n);
void sha256_final(struct sha256_ctx *c, char out[65]);

/* tracker.c */
int tracker_start(struct tracker *t, const char *want);   /* want: auto|bpf|ftrace; 0 ok, -1 error (t->err) */
int tracker_flip(struct tracker *t);                       /* closes the epoch of every volume into pending; 0 ok */
uint64_t tracker_lost(struct tracker *t);                  /* events the tracker may have missed so far */
void tracker_stop(struct tracker *t);
int kernel_version(void);                                  /* e.g. 50010 for 5.10 */
const char *find_tracefs(char *buf, size_t n);

/* bitmap helpers */
int bitmap_alloc(struct bitmap *b, uint64_t nbits);
void bitmap_free(struct bitmap *b);
static inline void bitmap_set(struct bitmap *b, uint64_t i) { __atomic_fetch_or(&b->w[i >> 6], 1ULL << (i & 63), __ATOMIC_RELAXED); }
static inline int bitmap_test(const struct bitmap *b, uint64_t i) { return (b->w[i >> 6] >> (i & 63)) & 1; }
void bitmap_or_into(struct bitmap *dst, struct bitmap *src);   /* dst |= src; src = 0 */
uint64_t bitmap_count(const struct bitmap *b);

/* util */
void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
double now_s(void);
ssize_t write_all(int fd, const void *buf, size_t n);
int read_file_str(const char *path, char *buf, size_t n);
long read_file_long(const char *path, long dflt);
int write_file_str(const char *path, const char *s);

#endif
