#!/usr/bin/env python3
"""d2s edits on top of y2sios's Mesa 25.0.7 patches (checked against mesa-25.0.7).

  patch-mesa25.py MESA_DIR D2SDRM_OBJ

tools/d2s-metal/build.sh first applies every stormtroopxyz/y2sios
kernel/tools/mesa/*.patch (exactly as y2sios's tools/mk-mesa.sh does), copies
y2sios's AIR frontend to src/compiler/air and puts our redwood_d2s.c at
src/redwood-drm/redwood_drm.c. This script then:

  - links D2SDRM_OBJ (tools/d2s-gl/d2sdrm.c, built on its own) and the
    frameworks it needs into libredwoodair, so the library carries our
    libdrm/panfrost UAPI stand-in over D2SGPU instead of RedwoodMali
  - gives libredwoodair the install name /usr/lib/libredwoodair.dylib (our
    iOS root has no /redwood)

Each replacement must match exactly once, so a change in y2sios's patches
fails here instead of building something different. Idempotent.
"""
import sys
from pathlib import Path


def edits(obj):
    return [
        ('src/gallium/drivers/panfrost/meson.build',
         "redwoodair_link_args = []\n",
         "redwoodair_link_args = ['%s', '-framework', 'IOKit', '-framework', 'IOSurface',\n"
         "                        '-framework', 'CoreFoundation']  # d2s: d2sdrm over D2SGPU\n" % obj),
        ('src/gallium/drivers/panfrost/meson.build',
         "'-Wl,-install_name,/redwood/lib/libredwoodair.dylib'",
         "'-Wl,-install_name,/usr/lib/libredwoodair.dylib'"),
        # panfrost_drm_screen_create() dups the descriptor (os_dupfd_cloexec) before Mesa
        # uses it. y2sios's stand-in ignores descriptor numbers; d2sdrm accepts only the
        # one d2sdrm_open() returned, so open the screen on that one directly, as
        # tools/d2s-gl/pantest.c does.
        ('src/compiler/air/air_metal.c',
         '#include "panfrost/drm/panfrost_drm_public.h"\n',
         '#include "panfrost/drm/panfrost_drm_public.h"\n'
         '#include "panfrost/pan_public.h"   /* d2s: panfrost_create_screen */\n'),
        ('src/compiler/air/air_metal.c',
         '      device->screen = panfrost_drm_screen_create(fd, &config);\n',
         '      device->screen = panfrost_create_screen(fd, &config, NULL);   /* d2s: no dup */\n'),
    ]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    root, obj = Path(sys.argv[1]), sys.argv[2]
    for rel, old, new in edits(obj):
        p = root / rel
        s = p.read_text()
        if new in s:
            print(f'{rel}: already applied')
            continue
        n = s.count(old)
        if n != 1:
            sys.exit(f'{rel}: expected 1 match, found {n}')
        p.write_text(s.replace(old, new))
        print(f'{rel}: patched')


if __name__ == '__main__':
    main()
