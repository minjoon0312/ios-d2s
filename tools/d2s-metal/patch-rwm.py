#!/usr/bin/env python3
"""d2s edits on a copy of y2sios's RedwoodMetal sources (userland/src of
stormtroopxyz/y2sios at the commit tools/d2s-metal/build.sh pins).

  patch-rwm.py DIR

DIR holds copies of redwoodmetal.m, redwooddrawable.m and m2m.h. Every edit is
inside #ifdef D2S_METAL (build.sh passes -DD2S_METAL=1), so the y2sios
behaviour is still there to read:

  - the compiler library is /usr/lib/libredwoodair.dylib (no /redwood here)
  - redwooddrawable.m's own kernel connection (RedwoodGPU/RedwoodMali,
    kRedwoodSurface 0x7e) is answered by tools/d2s-metal/rwd_d2s.c: a token
    for the connection, the IOSurface API for "describe"
  - m2m.h's log records go to the kernel log (d2sdrm_log) when /dev/m2m is
    absent, which it always is on the d2s
  - RedwoodMetalDevice answers -supportsFamily: safely on a device Metal has
    not added yet (the boot-v12mtl crash, see FAM_* below)

Each replacement must match exactly once. Idempotent.
"""
import sys
from pathlib import Path

AIR_OLD = '"/redwood/lib/libredwoodair.dylib"'
AIR_NEW = 'D2S_AIR_PATH'
AIR_DEF = ('#ifdef D2S_METAL\n#define D2S_AIR_PATH "/usr/lib/libredwoodair.dylib"\n#else\n'
           '#define D2S_AIR_PATH "/redwood/lib/libredwoodair.dylib"\n#endif\n')

PROTOS = ('#ifdef D2S_METAL\n'
          'int d2s_rwd_gpu_open(io_connect_t *connection, char *why, size_t why_size);\n'
          'int d2s_rwd_surface_call(struct rwd_surface *surface, const char *what, char *why,\n'
          '                         size_t why_size);\n'
          '#endif\n')

# logs/boot-v12mtl (2026-11-11): backboardd SIGSEGV at -[_MTLDevice supportsFamily:]+4
# (0x181a1e9b8 unslid, 20H392), far 0, called by rw_mps_facts() inside
# -[RedwoodMetalCommandBuffer initWithRedwoodQueue:] (the first command buffer of a process
# that has MPS). Apple's body is `ldr x9, [x0, #0x110]; ldp x8, x9, [x9]`: the family vector
# that only -[_MTLDevice initGPUFamilySupport] allocates, and that only initFeatureQueries
# calls, and that only MTLAddDevice calls. mtltest makes the device by hand (no MTLAddDevice),
# so the pointer was NULL. Fix: the device fills the vector itself, through Apple's own
# initGPUFamilySupport (idempotent on 16.7.16: it reuses the vector and resets its end),
# looked up at run time, before any -supportsFamily: reaches Apple's body; and it answers NO,
# said once, if this Metal has no such method.
FAM_IVAR_OLD = '\tchar _targetName[96];               /* the bytes _target.name points at, inside the object */\n'
FAM_IVAR_NEW = FAM_IVAR_OLD + '#ifdef D2S_METAL\n\tint _d2sFamiliesReady;              /* Apple\'s family vector (+0x110) is allocated */\n#endif\n'
FAM_METH_OLD = '- (struct rwa_device *)mesaDevice\n{\n\treturn _mesa;\n}\n'
FAM_METH_NEW = FAM_METH_OLD + r'''
#ifdef D2S_METAL
/* d2s: see tools/d2s-metal/patch-rwm.py (FAM_*) and research/METAL_PORT.md section 9.
 * _MTLDevice's own implementation of a selector, looked up by name at run time, so nothing
 * here depends on what the SDK this was linked against says _MTLDevice has. */
static IMP
d2s_mtldevice_imp(const char *name)
{
	Class base = objc_getClass("_MTLDevice");
	Method m = base != Nil ? class_getInstanceMethod(base, sel_getUid(name)) : NULL;

	return m != NULL ? method_getImplementation(m) : NULL;
}

/* Apple's -supportsFamily: reads a vector that only -initGPUFamilySupport allocates, and only
 * MTLAddDevice (through -initFeatureQueries) calls that. A device made by hand, or asked
 * before it is added, would load from address 0, so the vector is made here, once, by
 * Apple's own code. 16.7.16 (0x181a1ea28): it allocates when +0x110 is NULL, else reuses the
 * vector and resets its end, so MTLAddDevice running it again later is harmless. */
- (BOOL)d2sEnsureFamilies
{
	if (__atomic_load_n(&_d2sFamiliesReady, __ATOMIC_ACQUIRE)) {
		return YES;
	}
	@synchronized (self) {
		if (!_d2sFamiliesReady) {
			IMP init = d2s_mtldevice_imp("initGPUFamilySupport");

			if (init != NULL) {
				m2m_log('I', "DEV", "families: Metal's -initGPUFamilySupport run by the device "
				         "itself (not added to Metal yet), so -supportsFamily: has its vector\n");
				((void (*)(id, SEL))init)(self, sel_getUid("initGPUFamilySupport"));
				__atomic_store_n(&_d2sFamiliesReady, 1, __ATOMIC_RELEASE);
			}
		}
	}
	return _d2sFamiliesReady != 0;
}

/* MTLAddDevice's own path: Apple's body, then the vector is known to be there. */
- (void)initFeatureQueries
{
	IMP base = d2s_mtldevice_imp("initFeatureQueries");

	if (base != NULL) {
		((void (*)(id, SEL))base)(self, _cmd);
		if (d2s_mtldevice_imp("initGPUFamilySupport") != NULL) {
			__atomic_store_n(&_d2sFamiliesReady, 1, __ATOMIC_RELEASE);
		}
	}
}

- (BOOL)supportsFamily:(MTLGPUFamily)family
{
	IMP base = d2s_mtldevice_imp("supportsFamily:");

	if (base == NULL || ![self d2sEnsureFamilies]) {
		RW_ONCE('W', "DEV", "families: this Metal has no %s, so -supportsFamily: answers NO "
			"(Apple's body would read an unallocated vector)\n",
			base == NULL ? "-supportsFamily:" : "-initGPUFamilySupport");
		return NO;
	}
	return ((BOOL (*)(id, SEL, MTLGPUFamily))base)(self, _cmd, family);
}
#endif
'''

EDITS = [
    ('redwoodmetal.m', FAM_IVAR_OLD, FAM_IVAR_NEW),
    ('redwoodmetal.m', FAM_METH_OLD, FAM_METH_NEW),
    ('redwoodmetal.m', AIR_OLD, AIR_NEW),
    ('redwoodmetal.m', '#include "redwood_drawable.h"\n', '#include "redwood_drawable.h"\n' + AIR_DEF),
    ('redwooddrawable.m', AIR_OLD, AIR_NEW),
    ('redwooddrawable.m', '#include "redwood_drawable.h"\n',
     '#include "redwood_drawable.h"\n' + AIR_DEF + PROTOS),
    ('redwooddrawable.m',
     'int\nrwd_gpu_open(io_connect_t *connection, char *why, size_t why_size)\n{\n',
     'int\nrwd_gpu_open(io_connect_t *connection, char *why, size_t why_size)\n{\n'
     '#ifdef D2S_METAL\n\treturn d2s_rwd_gpu_open(connection, why, why_size);\n#endif\n'),
    ('redwooddrawable.m',
     'void\nrwd_gpu_close(io_connect_t connection)\n{\n',
     'void\nrwd_gpu_close(io_connect_t connection)\n{\n'
     '#ifdef D2S_METAL\n\t(void)connection;\n\treturn;\n#endif\n'),
    ('redwooddrawable.m',
     'static int\nrwd_surface_call(io_connect_t connection, struct rwd_surface *surface, const char *what,\n'
     '\t\t char *why, size_t why_size)\n{\n',
     'static int\nrwd_surface_call(io_connect_t connection, struct rwd_surface *surface, const char *what,\n'
     '\t\t char *why, size_t why_size)\n{\n'
     '#ifdef D2S_METAL\n\t(void)connection;\n'
     '\treturn d2s_rwd_surface_call(surface, what, why, why_size);\n#endif\n'),
    ('redwooddrawable.m',
     'int\nrwd_surface_give_back(io_connect_t connection, uint32_t handle, char *why, size_t why_size)\n{\n',
     'int\nrwd_surface_give_back(io_connect_t connection, uint32_t handle, char *why, size_t why_size)\n{\n'
     '#ifdef D2S_METAL\n\t(void)connection;\n\t(void)handle;\n\t(void)why;\n\t(void)why_size;\n'
     '\treturn 0;\t/* nothing is ever taken from the kernel here (rwd_d2s.c) */\n#endif\n'),
    ('m2m.h',
     '\t} else {\n\t\tprintf("m2m-nodev: %s\\n", rec);\n\t\tfflush(stdout);\n\t}\n',
     '\t} else {\n#ifdef D2S_METAL\n\t\td2s_m2m_sink(rec);\n#else\n'
     '\t\tprintf("m2m-nodev: %s\\n", rec);\n\t\tfflush(stdout);\n#endif\n\t}\n'),
    ('m2m.h',
     'static int m2m_fd = -1;\n',
     '#ifdef D2S_METAL\nvoid d2s_m2m_sink(const char *rec);\t/* tools/d2s-metal/rwd_d2s.c */\n#endif\n'
     'static int m2m_fd = -1;\n'),
]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = Path(sys.argv[1])
    for rel, old, new in EDITS:
        p = root / rel
        s = p.read_text()
        if new in s:
            print(f'{rel}: already applied')
            continue
        n = s.count(old)
        if n != 1:
            sys.exit(f'{rel}: expected 1 match, found {n}: {old[:60]!r}')
        p.write_text(s.replace(old, new))
        print(f'{rel}: patched')


if __name__ == '__main__':
    main()
