/* Host test of d2sdrm.c cache policy (Boot A) against a mock D2SGPU and IOSurface.
 *   W=tools/d2s-metal/work; clang -Wall -I$W/uapi26 -Itools/d2s-gl/libdrm -Itools/d2s-gpu -Itools/d2s-gl \
 *     tools/d2s-gl/test_d2sdrm_host.c tools/d2s-gl/d2sdrm.c -framework CoreFoundation -o /tmp/t && \
 *     for m in lean noheap all; do D2SDRM_FLUSH=$m /tmp/t; done; D2SDRM_SEED=0 /tmp/t
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#include <xf86drm.h>
#include <drm-uapi/panfrost_drm.h>
#include "d2sdrm.h"

typedef mach_port_t io_object_t;

/* ---- mock kernel ---- */
static uint32_t next_handle = 1;
static uint64_t submit_seq, gpu_done;
static uint64_t buf_size[1100];
static int destroyed[1100];
static uint64_t destroy_done_seq[1100];
static uint32_t last_pre[256], last_npre;
static int flushes[1100];
static int log_lines;

CFMutableDictionaryRef IOServiceMatching(const char *n) { (void)n; return NULL; }
io_object_t IOServiceGetMatchingService(mach_port_t m, CFDictionaryRef d) { (void)m; (void)d; return 1; }
kern_return_t IOServiceOpen(io_object_t s, task_port_t t, uint32_t ty, io_object_t *c) { (void)s; (void)t; (void)ty; *c = 2; return 0; }
kern_return_t IOServiceClose(io_object_t c) { (void)c; return 0; }
kern_return_t IOObjectRelease(io_object_t o) { (void)o; return 0; }
kern_return_t IOConnectMapMemory64(io_object_t c, uint32_t type, task_port_t t, mach_vm_address_t *a,
    mach_vm_size_t *s, uint32_t o) { (void)c; (void)t; (void)o; *a = (mach_vm_address_t)(uintptr_t)calloc(1, 4096); *s = buf_size[type]; return 0; }
kern_return_t IOConnectUnmapMemory64(io_object_t c, uint32_t t, task_port_t f, mach_vm_address_t a) { (void)c; (void)t; (void)f; (void)a; return 0; }

kern_return_t
IOConnectCallMethod(mach_port_t c, uint32_t sel, const uint64_t *in, uint32_t nin, const void *sin,
    size_t sinsz, uint64_t *out, uint32_t *nout, void *sout, size_t *soutsz)
{
	(void)c; (void)nin; (void)nout; (void)soutsz;
	switch (sel) {
	case 0: { uint32_t *i = sout; memset(sout, 0, *soutsz); i[0] = 2; i[1] = 0x72120000; return 0; }
	case 1: { uint32_t h = next_handle++; buf_size[h] = (in[0] + 16383) & ~16383ull; out[0] = h; out[1] = 0x2000000ull + h * 0x1000000ull; out[2] = buf_size[h]; return 0; }
	case 2: destroyed[in[0]] = 1; destroy_done_seq[in[0]] = gpu_done; return 0;
	case 4: printf("    [klog] %.*s\n", (int)sinsz, (const char *)sin); log_lines++; return 0;
	case 5: last_npre = (uint32_t)(sinsz / 4); memcpy(last_pre, sin, sinsz); out[0] = ++submit_seq; return 0;
	case 6: { uint64_t seq = in[0], us = in[1];
		if (seq > gpu_done && us > 0) gpu_done = seq;	/* waiting lets the GPU finish */
		out[0] = seq <= gpu_done ? 0 : 3; out[1] = out[2] = out[3] = 0; out[4] = gpu_done; return 0; }
	case 7: assert(!"BUF_WAIT must not be used any more"); return 0;
	case 8: { uint32_t h = next_handle++; buf_size[h] = 11ull << 20; out[0] = h; out[1] = 0x80000000ull + h * 0x1000000ull; out[2] = buf_size[h]; return 0; }
	case 9: memset(sout, 0, *soutsz); return 0;
	case 10: flushes[in[0]]++; return 0;
	}
	return 5;
}

/* ---- mock IOSurface ---- */
static uint32_t seeds[64];
static CFTypeRef refs[64];
void *IOSurfaceLookup(uint32_t id) { refs[id] = CFArrayCreateMutable(NULL, 0, NULL); CFRetain(refs[id]); return (void *)refs[id]; }
uint32_t IOSurfaceGetSeed(void *s) { for (int i = 0; i < 64; i++) if (refs[i] == s) return seeds[i]; return 0; }

/* ---- helpers ---- */
static int fd;
static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint32_t mkbo(uint32_t size, uint32_t flags) {
	struct drm_panfrost_create_bo a = { .size = size, .flags = flags };
	assert(drmIoctl(fd, DRM_IOCTL_PANFROST_CREATE_BO, &a) == 0);
	return a.handle;
}
static void map(uint32_t h) {
	struct drm_panfrost_mmap_bo m = { .handle = h };
	assert(drmIoctl(fd, DRM_IOCTL_PANFROST_MMAP_BO, &m) == 0);
	assert(d2sdrm_mmap(fd, (off_t)m.offset, 4096) != NULL);
}
static int listed(uint32_t h) { for (uint32_t i = 0; i < last_npre; i++) if (last_pre[i] == h) return 1; return 0; }
static uint32_t job(uint32_t *hs, uint32_t n, int fs, uint32_t syncobj) {
	struct drm_panfrost_submit s = { .jc = 0x1000, .bo_handles = (uintptr_t)hs, .bo_handle_count = n,
		.requirements = fs ? PANFROST_JD_REQ_FS : 0, .out_sync = syncobj };
	assert(drmIoctl(fd, DRM_IOCTL_PANFROST_SUBMIT, &s) == 0);
	return (uint32_t)submit_seq;
}
#define HINT 0x40000000u
#define W 0x80000000u

int
main(void)
{
	const char *mode = getenv("D2SDRM_FLUSH") ? getenv("D2SDRM_FLUSH") : "lean";
	int seed = !(getenv("D2SDRM_SEED") && getenv("D2SDRM_SEED")[0] == '0');
	int lean = !strcmp(mode, "lean"), all = !strcmp(mode, "all");
	printf("== mode %s seed %d\n", mode, seed);
	fd = d2sdrm_open();
	assert(fd >= 0);
	uint32_t heap = mkbo(32 << 20, PANFROST_BO_HEAP | PANFROST_BO_NOEXEC);
	uint32_t pool = mkbo(65536, PANFROST_BO_NOEXEC);
	uint32_t shader = mkbo(65536, 0);
	uint32_t vary = mkbo(65536, PANFROST_BO_NOEXEC);
	uint32_t rt = mkbo(1 << 20, PANFROST_BO_NOEXEC);
	map(pool);
	map(shader);
	int sfd = d2sdrm_surface_fd(fd, 7), sfd2 = d2sdrm_surface_fd(fd, 8);
	uint32_t fb = 0, wall = 0;
	assert(drmPrimeFDToHandle(fd, sfd, &fb) == 0 && drmPrimeFDToHandle(fd, sfd2, &wall) == 0);
	uint32_t so = 0;
	assert(drmSyncobjCreate(fd, 0, &so) == 0);

	/* job 1: tiler job of a pass drawing into fb, sampling wall (both first use) */
	uint32_t l1[] = { pool | HINT, shader | HINT, vary | HINT | W, rt | HINT | W, fb | HINT | W, wall | HINT, heap, pool | HINT };
	job(l1, 8, 0, 0);
	CHECK(listed(pool) && listed(shader), "mapped own BOs are cleaned");
	CHECK(listed(heap) == all, "heap only in mode all");
	CHECK(listed(vary) == !lean && listed(rt) == !lean, "never-mapped BOs only outside lean");
	CHECK(listed(fb) && listed(wall), "surfaces on first use");
	uint32_t n1 = last_npre;
	CHECK(lean ? n1 == 4 : all ? n1 == 7 : n1 == 6, "deduplicated list, %u", n1);
	/* job 2: the fragment job of the same pass */
	job(l1, 8, 1, 0);
	CHECK(listed(fb) == (!seed || !lean) && listed(wall) == (!seed || !lean), "unchanged seed skips surfaces (lean)");
	/* the CPU (another process) redrew wall: its seed moved */
	seeds[8]++;
	uint32_t s3 = job(l1, 8, 1, so);
	CHECK(listed(wall), "seed change cleans wall");
	CHECK(listed(fb) == (!seed || !lean), "fb still skipped");
	/* CoreAnimation waits (the present race fix): finished jobs' written surfaces are flushed once */
	CHECK(gpu_done < s3, "not done yet");
	CHECK(drmSyncobjWait(fd, &so, 1, -1, 0, NULL) == 0, "syncobj wait");
	CHECK(gpu_done >= s3, "waited");
	if (lean) {
		CHECK(flushes[fb] == 1, "fb flushed once after 3 jobs, got %d", flushes[fb]);
		CHECK(flushes[wall] == 0, "wall only sampled: no post flush, got %d", flushes[wall]);
		CHECK(flushes[pool] == 0 && flushes[vary] == 0 && flushes[heap] == 0, "own BOs not flushed after jobs");
	} else {
		CHECK(flushes[fb] == 1 && flushes[pool] == 1 && flushes[vary] == 1, "old way: every BO flushed once per wait (deduplicated)");
		CHECK(flushes[heap] == all, "heap flushed only in mode all");
	}
	/* WAIT_BO before a CPU read of a mapped own BO: one flush, a second wait none */
	int before = flushes[pool];
	struct drm_panfrost_wait_bo wb = { .handle = pool, .timeout_ns = 0 };
	CHECK(drmIoctl(fd, DRM_IOCTL_PANFROST_WAIT_BO, &wb) == 0, "wait_bo done");
	CHECK(flushes[pool] == before + (lean ? 1 : 0), "wait_bo flushes a used mapped BO once (lean); old: already flushed after done");
	CHECK(drmIoctl(fd, DRM_IOCTL_PANFROST_WAIT_BO, &wb) == 0 && flushes[pool] == before + (lean ? 1 : 0), "no second flush");
	/* WAIT_BO on a never-mapped BO: no flush; mapping it later flushes once (it was GPU-used) */
	before = flushes[rt];
	wb.handle = rt;
	CHECK(drmIoctl(fd, DRM_IOCTL_PANFROST_WAIT_BO, &wb) == 0 && flushes[rt] == before, "never-mapped: no flush at wait");
	map(rt);
	CHECK(flushes[rt] == before + (lean ? 1 : 0), "first map of a GPU-written BO flushes (lean)");
	/* a busy BO: WAIT_BO with timeout 0 says ETIMEDOUT (the BO cache must not reuse it) */
	uint32_t l4[] = { vary | HINT | W };
	uint32_t s4 = job(l4, 1, 0, 0);
	wb.handle = vary;
	wb.timeout_ns = 0;
	int r = drmIoctl(fd, DRM_IOCTL_PANFROST_WAIT_BO, &wb);
	CHECK(r != 0, "busy never-mapped BO reported busy (the kernel never saw it in lean)");
	/* closing it waits for its job first */
	struct drm_gem_close gc = { .handle = vary };
	CHECK(drmIoctl(fd, DRM_IOCTL_GEM_CLOSE, &gc) == 0, "close");
	CHECK(destroyed[vary] && destroy_done_seq[vary] >= s4, "destroyed only after its job (%llu >= %u)",
	    (unsigned long long)destroy_done_seq[vary], s4);
	/* a surface without Mesa's access bits (pantest, Mesa 26 path) counts as written */
	uint32_t l5[] = { wall };
	uint32_t so2 = 0;
	drmSyncobjCreate(fd, 0, &so2);
	before = flushes[wall];
	job(l5, 1, 1, so2);
	drmSyncobjWait(fd, &so2, 1, -1, 0, NULL);
	CHECK(flushes[wall] == before + 1, "unhinted surface flushed after the job");
	/* close of the surface releases its IOSurface reference (CFRelease would crash on a bad one) */
	gc.handle = fb;
	CHECK(drmIoctl(fd, DRM_IOCTL_GEM_CLOSE, &gc) == 0 && destroyed[fb], "surface closed");
	printf("== %s: %d failure(s), %d log lines\n", fails ? "FAIL" : "PASS", fails, log_lines);
	return fails != 0;
}
