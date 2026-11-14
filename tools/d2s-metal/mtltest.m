/*
 * mtltest: Metal milestone 1 on the d2s. y2sios's Metal driver (RedwoodMetal, an MTLDevice
 * subclass) over libredwoodair (Mesa 25.0.7 panfrost + AIR) over d2sdrm and D2SGPU, asked the
 * way an app asks Metal: a command queue, a command buffer, one render pass that clears an
 * IOSurface-backed texture, commit, wait. The CPU then checks the pixels through the
 * IOSurface's own mapping, like pantest (tools/d2s-gl/pantest.c) one layer lower.
 *
 * Built as mtltest.dylib and inserted with the d2senv boot-arg into ONE non-UI daemon,
 * timed by default (MTLTEST_HOST): it starts at boot (RunAtLoad, KeepAlive), has a 2500 MB
 * jetsam limit, and nothing on screen depends on it, so a crash costs one timed restart.
 * It refuses to run in backboardd or SpringBoard unless built with -DMTLTEST_ALLOW_UI=1
 * (boot v12mtl: a crash there crash-looped backboardd 176 times and no screen came up).
 *
 * ONCE PER BOOT: before anything that can crash, it writes kern.bootsessionuuid to
 * /var/tmp/mtltest.ran. A restarted host that finds its own boot's UUID there only logs
 * "skipped" and does nothing else, so a crash cannot loop. A new boot has a new UUID.
 * If the marker cannot be read or written, or the UUID is empty, it does not run.
 *
 * It runs on its own thread, 8 s after load, and reports in the kernel log through
 * libredwoodair's d2sdrm_log ("D2S GPU UC: timed: mtltest: ..."). Every step is logged
 * BEFORE it is taken ("step N: ..."), so the last step line before a CRASH line names the
 * call that crashed.
 *
 * Files it expects (tools/mkfiles.py specs: METAL_PORT.md, "Test on the phone"):
 *   /usr/lib/libredwoodair.dylib     the compiler library (RedwoodMetal dlopens this path)
 *   MTLTEST_DRIVER_PATH              the driver, an MH_BUNDLE, dlopen'ed here as a file
 *                                    (build.sh passes /usr/lib/d2s-RedwoodMetal-<hash8>)
 *
 * Discovery (IOAcceleratorES + MetalPluginName, MTLCreateSystemDefaultDevice finding the
 * bundle by itself) is NOT used: the d2s kernel publishes no IOAcceleratorES yet. The device
 * object is made directly (Metal's own step 5, -initWithAcceleratorPort:), and then the two
 * preparation steps MTLAddDevice takes on every device are replayed by hand, resolved at run
 * time: the conformsToProtocol: checks, -initLimits and -initFeatureQueries (Metal.framework
 * 20H392 0x181a1b368). Without them _MTLDevice's own methods read state nothing filled
 * (boot v12mtl crashed in -[_MTLDevice supportsFamily:] on exactly that). Built with
 * -DMTLTEST_ADD_DEVICE=1 it calls MTLAddDevice instead and checks that
 * MTLCreateSystemDefaultDevice() returns the device.
 *
 * Result line: "MTLTEST OK" or "MTLTEST FAIL: <step>".
 *
 * DISCOVERY MODE (Metal stage 2, built with -DMTLTEST_DISCOVERY=1 as mtltest-disc.dylib):
 * the kernel (xnu 0164, boot-arg d2smetal>=1) publishes an IOAcceleratorES whose
 * MetalPluginName / MetalPluginClassName name /System/Library/Extensions/RedwoodMetal.bundle
 * and RedwoodMetalDevice, and shows them to the processes in d2smtlp (default timed). This
 * build loads NO driver by hand: it reads the registry as this process sees it, then asks
 * MTLCreateSystemDefaultDevice() (and MTLCopyAllDevices() where Metal exports it, which
 * 16.7.16 does not), so Metal's own discovery
 * (MTLRegisterDevices -> NSBundle -> initWithAcceleratorPort: -> MTLAddDevice) has to find
 * the device. Then the same families, clears and fill. Without d2smetal>=1 in the boot-args
 * it only logs that and touches nothing of Metal.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurfaceRef.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#ifndef MTLTEST_AIR_PATH
#define MTLTEST_AIR_PATH "/usr/lib/libredwoodair.dylib"
#endif
#ifndef MTLTEST_DRIVER_PATH
#define MTLTEST_DRIVER_PATH "/usr/lib/d2s-RedwoodMetal"
#endif
#ifndef MTLTEST_HOST
#define MTLTEST_HOST "timed"
#endif
#ifndef MTLTEST_ALLOW_UI
#define MTLTEST_ALLOW_UI 0
#endif
#ifndef MTLTEST_ADD_DEVICE
#define MTLTEST_ADD_DEVICE 0
#endif
#ifndef MTLTEST_DISCOVERY
#define MTLTEST_DISCOVERY 0
#endif
#ifndef MTLTEST_BUNDLE
#define MTLTEST_BUNDLE "/System/Library/Extensions/RedwoodMetal.bundle"
#endif
#ifndef MTLTEST_MARKER
#define MTLTEST_MARKER "/var/tmp/mtltest.ran"
#endif
#define MTLTEST_WAIT_S 10	/* per command buffer; a GPU that never answers is a FAIL, not a hang */

static int (*drm_open)(void);
static void (*drm_log)(int, const char *, ...);
static int step_no;

static void
say(const char *fmt, ...)
{
	char line[400];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	printf("mtltest: %s\n", line);
	fflush(stdout);
	if (drm_log == NULL) {
		return;
	}
	size_t n = strlen(line);
	for (size_t at = 0; at < n || at == 0; at += 130) {	/* d2sdrm_log: ~150 bytes a line */
		drm_log(-1, "mtltest: %.130s", line + at);
		if (n == 0) {
			break;
		}
	}
}

/* said BEFORE the call it names: the last of these before a CRASH line is the culprit */
#define STEP(...) do { char what_[300]; snprintf(what_, sizeof(what_), __VA_ARGS__); \
	say("step %d: %s", ++step_no, what_); } while (0)

static uint64_t
now_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

/*
 * The once-per-boot gate. Returns 1 to run (the marker now holds this boot's UUID), 0 to skip;
 * `why` says which and why. Runs before any library is loaded, so it cannot log itself.
 */
static int
boot_gate(char *why, size_t size)
{
	char uuid[64] = "", old[64] = "";
	size_t len = sizeof(uuid) - 1;

	if (sysctlbyname("kern.bootsessionuuid", uuid, &len, NULL, 0) != 0 || uuid[0] == '\0') {
		snprintf(why, size, "skipped: no kern.bootsessionuuid (errno %d), cannot tell boots apart", errno);
		return 0;
	}
	int fd = open(MTLTEST_MARKER, O_RDONLY);
	if (fd >= 0) {
		ssize_t n = read(fd, old, sizeof(old) - 1);
		close(fd);
		old[n > 0 ? n : 0] = '\0';
		if (strcmp(old, uuid) == 0) {
			snprintf(why, size, "skipped: already ran in this boot (%s holds %s); a crash "
			    "cannot loop", MTLTEST_MARKER, uuid);
			return 0;
		}
	} else if (errno != ENOENT) {
		snprintf(why, size, "skipped: %s unreadable (errno %d)", MTLTEST_MARKER, errno);
		return 0;
	}
	(void)unlink(MTLTEST_MARKER);	/* a file of an earlier boot, perhaps of another owner */
	fd = open(MTLTEST_MARKER, O_WRONLY | O_CREAT | O_EXCL, 0644);
	if (fd < 0) {
		snprintf(why, size, "skipped: cannot create %s (errno %d)", MTLTEST_MARKER, errno);
		return 0;
	}
	ssize_t w = write(fd, uuid, strlen(uuid));
	int synced = fsync(fd);
	close(fd);
	if (w != (ssize_t)strlen(uuid) || synced != 0) {
		snprintf(why, size, "skipped: cannot write %s (errno %d)", MTLTEST_MARKER, errno);
		return 0;
	}
	snprintf(why, size, "first run in boot %s: marker %s written, a restart of %s will skip",
	    uuid, MTLTEST_MARKER, getprogname());
	return 1;
}

static IOSurfaceRef
make_surface(int w, int h)
{
	int bpe = 4, fmt = 0x42475241;	/* 'BGRA' */
	NSDictionary *props = @{
		(id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h),
		(id)kIOSurfaceBytesPerElement: @(bpe), (id)kIOSurfacePixelFormat: @(fmt),
	};
	return IOSurfaceCreate((CFDictionaryRef)props);
}

/* pixels within 1 of the expected BGRA bytes */
static int
check(IOSurfaceRef surf, int w, int h, const double c[4], uint32_t *first)
{
	const uint8_t want[4] = { (uint8_t)(c[2] * 255 + 0.5), (uint8_t)(c[1] * 255 + 0.5),
		                  (uint8_t)(c[0] * 255 + 0.5), (uint8_t)(c[3] * 255 + 0.5) };
	IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
	const uint8_t *base = IOSurfaceGetBaseAddress(surf);
	size_t bpr = IOSurfaceGetBytesPerRow(surf);
	int good = 0;
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			const uint8_t *p = base + (size_t)y * bpr + (size_t)x * 4;
			int ok = 1;
			for (int k = 0; k < 4; k++) {
				ok &= abs((int)p[k] - (int)want[k]) <= 1;
			}
			good += ok;
		}
	}
	memcpy(first, base, 4);
	IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
	return good;
}

/* commit and wait, bounded: 1 completed in time, 0 not (the buffer is then left alone) */
static int
commit_and_wait(id<MTLCommandBuffer> cb, const char *what)
{
	dispatch_semaphore_t done = dispatch_semaphore_create(0);

	STEP("%s: addCompletedHandler:", what);
	[cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
		(void)b;
		dispatch_semaphore_signal(done);
	}];
	STEP("%s: commit", what);
	[cb commit];
	STEP("%s: wait for completion (at most %d s)", what, MTLTEST_WAIT_S);
	if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
	    (int64_t)MTLTEST_WAIT_S * NSEC_PER_SEC)) != 0) {
		say("MTLTEST FAIL: %s: not completed in %d s (status %ld); left in flight",
		    what, MTLTEST_WAIT_S, (long)[cb status]);
		return 0;
	}
	return 1;
}

static int
clear_pass(id<MTLCommandQueue> queue, id<MTLTexture> tex, IOSurfaceRef surf, int w, int h,
    const double c[4], const char *what)
{
	/* poison the surface first, so a pass that does nothing cannot pass */
	STEP("%s: poison the IOSurface with 0x5a", what);
	IOSurfaceLock(surf, 0, NULL);
	memset(IOSurfaceGetBaseAddress(surf), 0x5a, IOSurfaceGetAllocSize(surf));
	IOSurfaceUnlock(surf, 0, NULL);

	STEP("%s: MTLRenderPassDescriptor (clear %.2f,%.2f,%.2f,%.2f, store)", what, c[0], c[1], c[2], c[3]);
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = tex;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(c[0], c[1], c[2], c[3]);

	uint64_t t0 = now_us();
	STEP("%s: [queue commandBuffer]", what);
	id<MTLCommandBuffer> cb = [queue commandBuffer];
	if (cb == nil) {
		say("MTLTEST FAIL: %s: commandBuffer returned nil", what);
		return 0;
	}
	STEP("%s: renderCommandEncoderWithDescriptor: on %s", what, class_getName(object_getClass(cb)));
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
	if (enc == nil) {
		say("MTLTEST FAIL: %s: renderCommandEncoderWithDescriptor returned nil", what);
		return 0;
	}
	STEP("%s: endEncoding on %s", what, class_getName(object_getClass(enc)));
	[enc endEncoding];
	if (!commit_and_wait(cb, what)) {
		return 0;
	}
	uint64_t t1 = now_us();
	NSError *err = [cb error];
	uint32_t first = 0;
	STEP("%s: read the pixels back on the CPU", what);
	int good = check(surf, w, h, c, &first);
	say("%s: clear %.2f,%.2f,%.2f,%.2f: status %ld%s%s in %llu us, %d/%d pixels right, first %#x",
	    what, c[0], c[1], c[2], c[3], (long)[cb status], err ? " error " : "",
	    err ? [[err localizedDescription] UTF8String] : "", (unsigned long long)(t1 - t0), good,
	    w * h, first);
	return [cb status] == MTLCommandBufferStatusCompleted && good == w * h;
}

/* a blit fill of a shared buffer: Mesa's buffer path without any shader of Apple's */
static int
fill_pass(id<MTLDevice> dev, id<MTLCommandQueue> queue)
{
	const NSUInteger len = 4096;
	STEP("fill: newBufferWithLength:%lu options:Shared", (unsigned long)len);
	id<MTLBuffer> buf = [dev newBufferWithLength:len options:MTLResourceStorageModeShared];
	if (buf == nil || [buf contents] == NULL) {
		say("fill: newBufferWithLength gave %s", buf == nil ? "nil" : "no contents");
		[buf release];
		return 0;
	}
	memset([buf contents], 0, len);
	STEP("fill: [queue commandBuffer]");
	id<MTLCommandBuffer> cb = [queue commandBuffer];
	if (cb == nil) {
		say("fill: commandBuffer returned nil");
		[buf release];
		return 0;
	}
	STEP("fill: blitCommandEncoder");
	id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
	if (blit == nil) {
		say("fill: blitCommandEncoder returned nil");
		[buf release];
		return 0;
	}
	STEP("fill: fillBuffer:range:value:0xa5 and endEncoding");
	[blit fillBuffer:buf range:NSMakeRange(0, len) value:0xa5];
	[blit endEncoding];
	if (!commit_and_wait(cb, "fill")) {
		return 0;	/* buf stays: the GPU may still write it */
	}
	const uint8_t *p = [buf contents];
	NSUInteger good = 0;
	for (NSUInteger i = 0; i < len; i++) {
		good += p[i] == 0xa5;
	}
	say("fill: status %ld, %lu/%lu bytes right", (long)[cb status], (unsigned long)good,
	    (unsigned long)len);
	[buf release];
	return good == len;
}

/* MTLAddDevice's preparation of a device (20H392 0x181a1b368), replayed by hand without
 * registering it: both protocol assertions (reported, not fatal here), -initLimits,
 * -initFeatureQueries. Each is looked up at run time. 0 = a step this Metal lacks. */
static int __attribute__((unused))
prepare_like_mtladddevice(id dev)
{
	static const char *const sels[] = { "initLimits", "initFeatureQueries" };
	Protocol *pd = objc_getProtocol("MTLDevice"), *ps = objc_getProtocol("MTLDeviceSPI");

	STEP("conformsToProtocol: MTLDevice and MTLDeviceSPI (MTLAddDevice asserts both)");
	say("conforms: MTLDevice %s, MTLDeviceSPI %s", pd == NULL ? "(no protocol)" :
	    [dev conformsToProtocol:pd] ? "yes" : "NO", ps == NULL ? "(no protocol)" :
	    [dev conformsToProtocol:ps] ? "yes" : "NO");
	for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
		SEL s = sel_getUid(sels[i]);
		if (![dev respondsToSelector:s]) {
			say("MTLTEST FAIL: the device does not answer -%s on this Metal", sels[i]);
			return 0;
		}
		STEP("-%s (what MTLAddDevice sends)", sels[i]);
		((void (*)(id, SEL))objc_msgSend)(dev, s);
	}
	return 1;
}

static void
say_families(id<MTLDevice> dev)
{
	static const struct { long v; const char *name; } fam[] = {
		{ 1001, "Apple1" }, { 1002, "Apple2" }, { 1003, "Apple3" }, { 1004, "Apple4" },
		{ 1005, "Apple5" }, { 1006, "Apple6" }, { 1007, "Apple7" }, { 1008, "Apple8" },
		{ 3001, "Common1" }, { 3002, "Common2" }, { 3003, "Common3" },
	};
	char list[200] = "";
	size_t used = 0;

	STEP("supportsFamily: Apple1..8, Common1..3 (the call that crashed boot v12mtl)");
	for (size_t i = 0; i < sizeof(fam) / sizeof(fam[0]); i++) {
		if ([dev supportsFamily:(MTLGPUFamily)fam[i].v]) {
			used += (size_t)snprintf(list + used, sizeof(list) - used, " %s", fam[i].name);
		}
	}
	say("families:%s", used ? list : " none");
}

static void run_device(id<MTLDevice> dev);

#if MTLTEST_DISCOVERY
/* the d2smetal=N boot-arg (0 when absent) */
static unsigned
boot_level(void)
{
	char args[1024] = "";
	size_t size = sizeof(args) - 1;
	const char *at = NULL;

	if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0) {
		for (at = strstr(args, "d2smetal="); at != NULL && at != args && at[-1] != ' ';
		    at = strstr(at + 1, "d2smetal=")) {
		}
	}
	return at ? (unsigned)strtoul(at + strlen("d2smetal="), NULL, 10) : 0;
}

/* one CFString property of the service, as this process is shown it */
static void
reg_string(io_service_t svc, const char *key, char *out, size_t size)
{
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFTypeRef v = k ? IORegistryEntryCreateCFProperty(svc, k, NULL, 0) : NULL;

	snprintf(out, size, "(none)");
	if (v != NULL && CFGetTypeID(v) == CFStringGetTypeID()) {
		CFStringGetCString((CFStringRef)v, out, (CFIndex)size, kCFStringEncodingUTF8);
	} else if (v != NULL) {
		snprintf(out, size, "(not a CFString: Metal would ignore it)");
	}
	if (v != NULL) {
		CFRelease(v);
	}
	if (k != NULL) {
		CFRelease(k);
	}
}

/*
 * Metal stage 2: the device as any process gets it. Metal's discovery, 20H392
 * _MTLRegisterDevices 0x181b144c8 and getMetalPluginClassForService 0x181a3c7c8.
 */
static void
run_discovery(const char *gate)
{
	void *air = dlopen(MTLTEST_AIR_PATH, RTLD_NOW);
	if (air == NULL) {
		printf("mtltest: no %s: %s\n", MTLTEST_AIR_PATH, dlerror());
		return;
	}
	*(void **)&drm_open = dlsym(air, "d2sdrm_open");
	*(void **)&drm_log = dlsym(air, "d2sdrm_log");
	if (drm_open == NULL || drm_log == NULL || drm_open() < 0) {
		printf("mtltest: no D2SGPU (d2sdrm_open failed): nothing to report to\n");
		return;
	}
	unsigned level = boot_level();
	say("start (discovery) in %s[%d]: d2smetal=%u; %s", getprogname(), getpid(), level, gate);
	if (level == 0) {
		say("MTLTEST FAIL: discovery build, but no d2smetal=N in the boot-args: Metal not asked");
		return;
	}

	/* 1. what Metal will read (MTLRegisterDevices step 1 and 2), as this process sees it */
	STEP("IOServiceGetMatchingService IOAcceleratorES");
	io_service_t acc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("IOAcceleratorES"));
	if (acc == MACH_PORT_NULL) {
		say("MTLTEST FAIL: no IOAcceleratorES service (kernel without 0164?)");
		return;
	}
	char name[128], cls[128], regname[128] = "?";
	uint64_t regid = 0;
	IORegistryEntryGetName(acc, regname);
	IORegistryEntryGetRegistryEntryID(acc, &regid);
	STEP("read MetalPluginName and MetalPluginClassName");
	reg_string(acc, "MetalPluginName", name, sizeof(name));
	reg_string(acc, "MetalPluginClassName", cls, sizeof(cls));
	IOObjectRelease(acc);
	say("registry: IOAcceleratorES \"%s\" id %#llx: MetalPluginName %s, MetalPluginClassName %s",
	    regname, (unsigned long long)regid, name, cls);
	say("bundle: %s: Info.plist %s, RedwoodMetal %s", MTLTEST_BUNDLE,
	    access(MTLTEST_BUNDLE "/Info.plist", R_OK) == 0 ? "there" : "MISSING",
	    access(MTLTEST_BUNDLE "/RedwoodMetal", R_OK) == 0 ? "there" : "MISSING");
	if (strcmp(name, "(none)") == 0) {
		say("MTLTEST FAIL: the names are hidden from %s (kernel log: \"D2S METAL: %s reads\"; "
		    "boot-arg d2smtlp?)", getprogname(), getprogname());
		return;
	}

	/* 2. Metal's own discovery, the way every app asks */
	STEP("MTLCreateSystemDefaultDevice() (MTLRegisterDevices: NSBundle, classNamed:, "
	    "initWithAcceleratorPort:, MTLAddDevice)");
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	if (dev == nil) {
		say("MTLTEST FAIL: MTLCreateSystemDefaultDevice() returned nil (bundle not loaded or "
		    "class refused; look for rwm: lines above)");
		return;
	}
	NSString *from = [[NSBundle bundleForClass:[(id)dev class]] bundlePath];
	say("device: %s \"%s\" from %s, registryID %#llx%s", class_getName(object_getClass(dev)),
	    [[dev name] UTF8String], from ? [from UTF8String] : "?",
	    (unsigned long long)[dev registryID], [dev registryID] == regid ? " (= the accelerator)" : "");
	if (strcmp(class_getName(object_getClass(dev)), "RedwoodMetalDevice") != 0) {
		say("MTLTEST FAIL: the default device is not RedwoodMetalDevice");
		return;
	}
	/* public on iOS 18 only; 20H392's Metal does not export it, so it is looked up, not linked */
	NSArray *(*copy_all)(void) = (NSArray *(*)(void))dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
	if (copy_all != NULL) {
		STEP("MTLCopyAllDevices()");
		NSArray *all = copy_all();
		say("MTLCopyAllDevices: %lu device(s), first %s%s", (unsigned long)[all count],
		    [all count] ? class_getName(object_getClass([all objectAtIndex:0])) : "-",
		    [all count] && [all objectAtIndex:0] == (id)dev ? " (the default one)" : "");
		[all release];
	} else {
		say("MTLCopyAllDevices: not exported by this Metal (an iOS 18 API), not asked");
	}

	run_device(dev);
	/* the device stays: it is Metal's now */
}
#endif /* MTLTEST_DISCOVERY */

#if !MTLTEST_DISCOVERY
static void
run(const char *gate)
{
	/* 1. the compiler library: also our way to the kernel log */
	void *air = dlopen(MTLTEST_AIR_PATH, RTLD_NOW);
	if (air == NULL) {
		printf("mtltest: no %s: %s\n", MTLTEST_AIR_PATH, dlerror());
		return;
	}
	*(void **)&drm_open = dlsym(air, "d2sdrm_open");
	*(void **)&drm_log = dlsym(air, "d2sdrm_log");
	if (drm_open == NULL || drm_log == NULL || drm_open() < 0) {
		printf("mtltest: no D2SGPU (d2sdrm_open failed): nothing to report to\n");
		return;
	}
	say("start in %s[%d]: %s loaded; %s", getprogname(), getpid(), MTLTEST_AIR_PATH, gate);

	/* 2. the driver, and Metal's own steps 4 and 5 */
	STEP("dlopen %s", MTLTEST_DRIVER_PATH);
	void *drv = dlopen(MTLTEST_DRIVER_PATH, RTLD_NOW);
	if (drv == NULL) {
		say("MTLTEST FAIL: dlopen driver: %s", dlerror());
		return;
	}
	STEP("objc_getClass RedwoodMetalDevice and _MTLDevice");
	Class cls = objc_getClass("RedwoodMetalDevice");
	Class base = objc_getClass("_MTLDevice");
	if (cls == Nil || base == Nil || ![cls isSubclassOfClass:base]) {
		say("MTLTEST FAIL: RedwoodMetalDevice %s, _MTLDevice %s, subclass %s",
		    cls ? "found" : "MISSING", base ? "found" : "MISSING",
		    cls && base && [cls isSubclassOfClass:base] ? "yes" : "NO");
		return;
	}
	STEP("IOServiceGetMatchingService D2SGPU");
	io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("D2SGPU"));
	STEP("[[RedwoodMetalDevice alloc] initWithAcceleratorPort:%#x]", svc);
	id<MTLDevice> dev = ((id (*)(id, SEL, io_service_t))objc_msgSend)(
	    [cls alloc], sel_getUid("initWithAcceleratorPort:"), svc);
	if (svc != MACH_PORT_NULL) {
		IOObjectRelease(svc);
	}
	if (dev == nil) {
		say("MTLTEST FAIL: initWithAcceleratorPort: returned nil");
		return;
	}
	STEP("[dev name]");
	say("device: %s \"%s\"", class_getName(object_getClass(dev)), [[dev name] UTF8String]);

#if MTLTEST_ADD_DEVICE
	STEP("MTLAddDevice (registers the device: CoreAnimation in this process may see it)");
	void (*add_device)(id) = (void (*)(id))dlsym(RTLD_DEFAULT, "MTLAddDevice");
	if (add_device != NULL && MTLCreateSystemDefaultDevice() == nil) {
		add_device(dev);
	}
	STEP("MTLCreateSystemDefaultDevice");
	id<MTLDevice> sys = MTLCreateSystemDefaultDevice();
	say("MTLAddDevice %s; MTLCreateSystemDefaultDevice() = %s%s", add_device ? "called" : "MISSING",
	    sys ? class_getName(object_getClass(sys)) : "nil", sys == dev ? " (ours)" : "");
#else
	if (!prepare_like_mtladddevice(dev)) {
		return;
	}
#endif
	run_device(dev);
}
#endif /* !MTLTEST_DISCOVERY */

/* steps 3 and 4 on a prepared device: families, an IOSurface texture, two clears, a fill */
static void
run_device(id<MTLDevice> dev)
{
	say_families(dev);

	/* 3. a texture over an IOSurface, the way CoreAnimation hands Metal a drawable */
	const int w = 64, h = 64;
	STEP("IOSurfaceCreate %dx%d BGRA", w, h);
	IOSurfaceRef surf = make_surface(w, h);
	if (surf == NULL) {
		say("MTLTEST FAIL: IOSurfaceCreate");
		return;
	}
	STEP("newTextureWithDescriptor:iosurface:%u plane:0", IOSurfaceGetID(surf));
	MTLTextureDescriptor *td = [MTLTextureDescriptor
	    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModeShared;
	id<MTLTexture> tex = [dev newTextureWithDescriptor:td iosurface:surf plane:0];
	say("IOSurface %u (%zu bytes a row): texture %s", IOSurfaceGetID(surf),
	    IOSurfaceGetBytesPerRow(surf), tex ? class_getName(object_getClass(tex)) : "nil");
	if (tex == nil) {
		say("MTLTEST FAIL: newTextureWithDescriptor:iosurface:plane:");
		CFRelease(surf);
		return;
	}

	/* 4. two clears, so a stale right answer cannot pass */
	STEP("newCommandQueue");
	id<MTLCommandQueue> queue = [dev newCommandQueue];
	if (queue == nil) {
		say("MTLTEST FAIL: newCommandQueue returned nil");
		[tex release];
		CFRelease(surf);
		return;
	}
	say("queue: %s", class_getName(object_getClass(queue)));
	const double a[4] = { 1.0, 0.0, 0.0, 1.0 };	/* red */
	const double b[4] = { 0.0, 0.5, 1.0, 1.0 };	/* sky */
	int ok_a = clear_pass(queue, tex, surf, w, h, a, "clear 1");
	int ok_b = ok_a ? clear_pass(queue, tex, surf, w, h, b, "clear 2") : 0;
	int ok_f = ok_a ? fill_pass(dev, queue) : 0;
	say("MTLTEST %s (clear 1 %s, clear 2 %s, blit fill %s)", ok_a && ok_b ? "OK" : "FAIL: clears",
	    ok_a ? "ok" : "FAIL", ok_b ? "ok" : ok_a ? "FAIL" : "not run",
	    ok_f ? "ok" : ok_a ? "fail (not required)" : "not run");
	if (!ok_a) {
		return;	/* a buffer may still be in flight: leave everything alone */
	}

	[queue release];
	[tex release];
	CFRelease(surf);
	/* the device stays: RedwoodMetal's teardown is not exercised by this test */
}

static void *
test_thread(void *arg)
{
	char gate[300];

	(void)arg;
	sleep(8);
	int go = boot_gate(gate, sizeof(gate));
	@autoreleasepool {
		@try {
			if (go) {
#if MTLTEST_DISCOVERY
				run_discovery(gate);
#else
				run(gate);
#endif
			} else {
				/* only to say so: the library and the log, nothing of Metal */
				void *air = dlopen(MTLTEST_AIR_PATH, RTLD_NOW);
				if (air != NULL) {
					*(void **)&drm_open = dlsym(air, "d2sdrm_open");
					*(void **)&drm_log = dlsym(air, "d2sdrm_log");
					if (drm_open == NULL || drm_log == NULL || drm_open() < 0) {
						drm_log = NULL;
					}
				}
				say("%s[%d]: %s", getprogname(), getpid(), gate);
			}
		} @catch (NSException *e) {
			say("MTLTEST FAIL: exception %s: %s", [[e name] UTF8String], [[e reason] UTF8String]);
		}
	}
	return NULL;
}

__attribute__((constructor)) static void
mtltest_load(void)
{
	const char *name = getprogname();
	if (name == NULL || strcmp(name, MTLTEST_HOST) != 0) {
		return;
	}
#if !MTLTEST_ALLOW_UI
	/* never in the processes the screen depends on (boot v12mtl) */
	if (strcmp(name, "backboardd") == 0 || strcmp(name, "SpringBoard") == 0) {
		printf("mtltest: not in %s (build with -DMTLTEST_ALLOW_UI=1 for that)\n", name);
		return;
	}
#endif
	pthread_t t;
	if (pthread_create(&t, NULL, test_thread, NULL) == 0) {
		pthread_detach(t);
	}
}
