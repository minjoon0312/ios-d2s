/*
 * redwood_d2s.c: y2sios's libdrm stand-in interface (src/redwood-drm/xf86drm.h of
 * stormtroopxyz/y2sios, MIT) implemented over our d2sdrm (tools/d2s-gl/d2sdrm.c)
 * instead of y2sios's RedwoodMali IOKit service.
 *
 * tools/d2s-metal/build.sh copies this file to Mesa 25.0.7's src/redwood-drm/redwood_drm.c,
 * the path y2sios's air-panfrost.patch compiles into libredwoodair. d2sdrm.c itself is
 * compiled on its own (with Mesa 26.x's panfrost UAPI header, which it was written for)
 * with three functions renamed d2s_*, so the versions here can sit in front of them:
 *
 *   drmIoctl            Mesa 25.0.7 speaks panfrost UAPI 1.3, whose SUBMIT struct is 8 bytes
 *                       shorter than d2sdrm's (no jm_ctx_handle): the request code differs, so
 *                       it is widened here. Every other request code is identical (checked:
 *                       METAL_PORT.md, "UAPI").
 *   drmPrimeFDToHandle  y2sios passes the IOSurface ID itself where Linux passes a dma-buf fd
 *                       (air_metal.c, rwa_texture_from_surface). d2sdrm wants a placeholder
 *                       descriptor from d2sdrm_surface_fd(). Panfrost 25.0.7 also asks twice
 *                       for one import (pan_bo.c, then pan_kmod.c), and Linux answers both with
 *                       the same GEM handle, so the answer is remembered until the handle closes.
 *   drmCloseBufferHandle forgets that answer.
 */
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioccom.h>
#include <sys/mman.h>
#include <sys/types.h>

#include "xf86drm.h"
#include "drm-uapi/panfrost_drm.h"

int d2s_drmIoctl(int fd, unsigned long request, void *arg);
int d2s_drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle);
int d2s_drmCloseBufferHandle(int fd, uint32_t handle);
int d2sdrm_surface_fd(int drm_fd, uint32_t iosurface_id);
void *d2sdrm_mmap(int fd, off_t offset, size_t size);
uint64_t d2sdrm_bo_size(int fd, uint32_t handle);
void d2sdrm_log(int fd, const char *fmt, ...);

_Static_assert(sizeof(struct drm_panfrost_submit) == 0x28, "panfrost UAPI 1.3 SUBMIT expected");

/* d2sdrm's SUBMIT (UAPI 1.5 header): the 1.3 struct, then jm_ctx_handle and a pad */
struct submit15 {
	struct drm_panfrost_submit s;
	uint32_t jm_ctx_handle;
	uint32_t pad;
};

#define MAX_IMPORTS 256
static pthread_mutex_t imports_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
	uint32_t surface;	/* IOSurface ID, 0: free */
	uint32_t handle;
} imports[MAX_IMPORTS];

static void
forget_handle(uint32_t handle)
{
	pthread_mutex_lock(&imports_lock);
	for (int i = 0; i < MAX_IMPORTS; i++) {
		if (imports[i].surface != 0 && imports[i].handle == handle) {
			imports[i].surface = 0;
		}
	}
	pthread_mutex_unlock(&imports_lock);
}

static uint32_t
known_handle(uint32_t surface)
{
	uint32_t h = 0;
	pthread_mutex_lock(&imports_lock);
	for (int i = 0; i < MAX_IMPORTS; i++) {
		if (imports[i].surface == surface) {
			h = imports[i].handle;
			break;
		}
	}
	pthread_mutex_unlock(&imports_lock);
	return h;
}

int
drmIoctl(int fd, unsigned long request, void *arg)
{
	if (request == DRM_IOCTL_PANFROST_SUBMIT) {
		struct submit15 wide;
		memset(&wide, 0, sizeof(wide));
		memcpy(&wide.s, arg, sizeof(wide.s));
		unsigned long req15 = (request & ~((unsigned long)IOCPARM_MASK << 16)) |
		    ((unsigned long)(sizeof(wide) & IOCPARM_MASK) << 16);
		int r = d2s_drmIoctl(fd, req15, &wide);
		int e = errno;
		memcpy(arg, &wide.s, sizeof(wide.s));
		errno = e;
		return r;
	}
	if (request == DRM_IOCTL_GEM_CLOSE) {
		forget_handle(((struct drm_gem_close *)arg)->handle);
	}
	return d2s_drmIoctl(fd, request, arg);
}

int
drmPrimeFDToHandle(int fd, int surface, uint32_t *handle)
{
	if (surface <= 0 || handle == NULL) {
		errno = EINVAL;
		return -1;
	}
	uint32_t h = known_handle((uint32_t)surface);
	if (h != 0) {
		*handle = h;
		return 0;
	}
	int pfd = d2sdrm_surface_fd(fd, (uint32_t)surface);
	if (pfd < 0) {
		errno = EINVAL;
		return -1;
	}
	int r = d2s_drmPrimeFDToHandle(fd, pfd, &h);
	int e = errno;
	close(pfd);
	if (r != 0) {
		errno = e;
		return r;
	}
	pthread_mutex_lock(&imports_lock);
	for (int i = 0; i < MAX_IMPORTS; i++) {
		if (imports[i].surface == 0) {
			imports[i].surface = (uint32_t)surface;
			imports[i].handle = h;
			break;
		}
	}
	pthread_mutex_unlock(&imports_lock);
	*handle = h;
	return 0;
}

int
drmCloseBufferHandle(int fd, uint32_t handle)
{
	forget_handle(handle);
	return d2s_drmCloseBufferHandle(fd, handle);
}

int
drmCommandWrite(int fd, unsigned long index, const void *data, unsigned long size)
{
	unsigned long req = _IOC(IOC_IN, DRM_IOCTL_BASE, DRM_COMMAND_BASE + index, size);
	return drmIoctl(fd, req, (void *)(uintptr_t)data);
}

int
drmCommandWriteRead(int fd, unsigned long index, void *data, unsigned long size)
{
	unsigned long req = _IOC(IOC_INOUT, DRM_IOCTL_BASE, DRM_COMMAND_BASE + index, size);
	return drmIoctl(fd, req, data);
}

int
drmGetCap(int fd, uint64_t capability, uint64_t *value)
{
	(void)fd;
	if (value == NULL) {
		return -EINVAL;
	}
	*value = capability == DRM_CAP_SYNCOBJ ? 1 : 0;
	return 0;
}

int
drmSyncobjHandleToFD(int fd, uint32_t handle, int *obj_fd)
{
	(void)fd;
	(void)handle;
	(void)obj_fd;
	return -ENOSYS;
}

/* ---- y2sios's own calls (panfrost-darwin.patch, panfrost-faultdump.patch) ---- */

void *
redwood_drm_map(int fd, uint32_t handle, uint64_t size)
{
	/* d2sdrm hands out handle << 32 as the MMAP_BO offset and maps every buffer once */
	return d2sdrm_mmap(fd, (off_t)((uint64_t)handle << 32), (size_t)size);
}

void
redwood_drm_unmap(int fd, uint32_t handle, void *address)
{
	(void)fd;
	(void)handle;
	(void)address;	/* the mapping lives as long as the buffer (d2sdrm_munmap) */
}

/*
 * pan_kmod_bo_import's size question, asked with the IOSurface ID right after
 * drmPrimeFDToHandle imported it: answered from that import.
 */
int
redwood_drm_surface(int fd, struct redwood_drm_surface *surface)
{
	if (surface == NULL) {
		return -1;
	}
	uint32_t h = known_handle(surface->surface);
	uint64_t size = h != 0 ? d2sdrm_bo_size(fd, h) : 0;
	if (size == 0) {
		return -1;
	}
	surface->handle = h;
	surface->size = size;
	return 0;
}

/* job, fault and reset counts of the kernel: D2SGPU has no such query yet */
int
redwood_drm_counts(uint64_t counts[4])
{
	memset(counts, 0, 4 * sizeof(uint64_t));
	return -1;
}
