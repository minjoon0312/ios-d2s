/*
 * rwd_d2s.c: what y2sios's RedwoodMetal asked of its kernel (RedwoodGPU / RedwoodMali IOKit
 * services), answered on the d2s, where the GPU is D2SGPU and is reached only through
 * libredwoodair's d2sdrm. patch-rwm.py makes redwooddrawable.m and m2m.h call these when
 * built with -DD2S_METAL.
 *
 *   d2s_rwd_gpu_open      y2sios opens a user client of its own to describe IOSurfaces. The
 *                         d2s needs none: hand out a token, if the GPU service exists at all.
 *   d2s_rwd_surface_call  kRedwoodSurface (0x7e) "describe": answered from the IOSurface API
 *                         in this process. "take" (the kernel making a GEM buffer of the
 *                         surface) is not offered: on the d2s the import is libredwoodair's
 *                         (rwa_texture_from_surface -> drmPrimeFDToHandle -> d2sdrm), which is
 *                         the path RedwoodMetal takes whenever the compiler library is loaded.
 *   d2s_m2m_sink          y2sios's mali2metal log records (m2m.h) go to /dev/m2m, which the
 *                         d2s has not got: send them to the kernel log through d2sdrm_log,
 *                         the "D2S GPU UC" path pantest uses.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurfaceRef.h>

#include "redwood_drawable.h"

#define D2S_TOKEN ((io_connect_t)0xd25)

static void
say(char *why, size_t why_size, const char *text)
{
	if (why != NULL && why_size > 0) {
		snprintf(why, why_size, "%s", text);
	}
}

int
d2s_rwd_gpu_open(io_connect_t *connection, char *why, size_t why_size)
{
	if (connection == NULL) {
		return -1;
	}
	io_service_t s = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("D2SGPU"));
	if (s == MACH_PORT_NULL) {
		*connection = 0;
		say(why, why_size, "no D2SGPU service: the kernel has no Mali driver");
		return -1;
	}
	IOObjectRelease(s);
	*connection = D2S_TOKEN;
	return 0;
}

int
d2s_rwd_surface_call(struct rwd_surface *surface, const char *what, char *why, size_t why_size)
{
	if (surface == NULL) {
		return -1;
	}
	if (surface->handle != RWD_DESCRIBE) {
		char line[160];
		snprintf(line, sizeof(line), "d2s: the kernel does not %s surfaces; the import is "
		    "libredwoodair's (rwa_texture_from_surface)", what);
		say(why, why_size, line);
		return -1;
	}
	IOSurfaceRef s = IOSurfaceLookup(surface->surface);
	if (s == NULL) {
		say(why, why_size, "d2s: no IOSurface by that ID in this process");
		return -1;
	}
	size_t planes = IOSurfaceGetPlaneCount(s);
	surface->width = (uint32_t)IOSurfaceGetWidth(s);
	surface->height = (uint32_t)IOSurfaceGetHeight(s);
	surface->pixelFormat = IOSurfaceGetPixelFormat(s);
	surface->size = (uint64_t)IOSurfaceGetAllocSize(s);
	surface->size = (surface->size + 0x3fff) & ~(uint64_t)0x3fff;	/* whole 16 KB pages */
	if (planes <= 1) {
		surface->planes = 1;
		surface->offset = 0;
		surface->rowBytes = (uint32_t)IOSurfaceGetBytesPerRow(s);
		surface->planeOffset[0] = 0;
		surface->planeRowBytes[0] = surface->rowBytes;
	} else {
		/* plane offsets from the base addresses: the surface is mapped in this process */
		IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
		uintptr_t base = (uintptr_t)IOSurfaceGetBaseAddress(s);
		surface->planes = planes > 2 ? 2 : (uint32_t)planes;
		for (uint32_t i = 0; i < surface->planes; i++) {
			surface->planeOffset[i] =
			    (uint32_t)((uintptr_t)IOSurfaceGetBaseAddressOfPlane(s, i) - base);
			surface->planeRowBytes[i] = (uint32_t)IOSurfaceGetBytesPerRowOfPlane(s, i);
		}
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
		surface->offset = surface->planeOffset[0];
		surface->rowBytes = surface->planeRowBytes[0];
	}
	CFRelease(s);
	return 0;
}

void
d2s_m2m_sink(const char *rec)
{
	static void (*log_fn)(int, const char *, ...);
	static int looked;
	if (!looked) {
		looked = 1;
		*(void **)&log_fn = dlsym(RTLD_DEFAULT, "d2sdrm_log");
	}
	printf("m2m-nodev: %s\n", rec);
	fflush(stdout);
	if (log_fn == NULL) {
		return;
	}
	/* d2sdrm_log takes ~150 bytes a line */
	size_t n = strlen(rec);
	for (size_t at = 0; at < n; at += 130) {
		log_fn(-1, "rwm: %.130s", rec + at);
	}
}
