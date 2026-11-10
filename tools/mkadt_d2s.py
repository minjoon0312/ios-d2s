#!/usr/bin/env python3
"""Build the Galaxy Note 10+ (SM-N975F, d2s, Exynos 9825) ADT."""
import argparse
import os
from pathlib import Path

import adt
import mkadt

DRAM_BASE = 0x900000000
DRAM_SIZE = 0x20000000  # 512 MiB initial bring-up bank (clean high DRAM above 0x880000000 sec_rdx_bootdev)
FB_PHYS, FB_W, FB_H = 0xca000000, 1080, 2280  # d1x (Note 10 5G)
TIMEBASE = 26000000


def set_prop(node, name, value):
    for i, (key, flags, _) in enumerate(node.props):
        if key == name:
            node.props[i] = (key, flags, value)
            return
    node.props.append((name, 0, value))


def child(node, name):
    for candidate in node.children:
        if candidate.prop('name') == mkadt.cstr(name):
            return candidate
    raise ValueError(f'missing donor ADT node {name}')


def cpu_node(logical):
    # logical 0-3: Cortex-A55 (LITTLE) -> MPIDR 0x0000 - 0x0003
    # logical 4-5: Cortex-A75 (MID)    -> MPIDR 0x0004 - 0x0005
    # logical 6-7: Mongoose M4 (BIG)   -> MPIDR 0x0100 - 0x0101
    if logical < 4:
        compat = 'arm,cortex-a55'
        mpidr = logical
        cluster = 0
        freq = 1950000000
    elif logical < 6:
        compat = 'arm,cortex-a75'
        mpidr = logical
        cluster = 1
        freq = 2400000000
    else:
        compat = 'samsung,mongoose-m4'
        mpidr = 0x100 + (logical - 6)
        cluster = 2
        freq = 2730000000

    return [
        ('device_type', mkadt.cstr('cpu')),
        ('compatible', mkadt.cstr(compat) + mkadt.cstr('arm,cortex-a53') + mkadt.cstr('ARM,v8')),
        ('reg', mkadt.u32(mpidr)),
        ('cpu-id', mkadt.u32(logical)),
        ('cluster-id', mkadt.u32(cluster)),
        ('cluster-type', mkadt.u32(0)),
        ('die-cluster-id', mkadt.u32(cluster)),
        ('cluster-core-id', mkadt.u32(logical if logical < 4 else (logical - 4 if logical < 6 else logical - 6))),
        ('l2-cache-id', mkadt.u32(cluster)),
        ('l3-cache-id', mkadt.u32(0)),
        ('state', mkadt.cstr('running' if logical == 0 else 'stopped')),
        ('timebase-frequency', mkadt.u32(TIMEBASE)),
        ('clock-frequency', mkadt.u32(freq)),
        ('bus-frequency', mkadt.u32(100000000)),
        ('memory-frequency', mkadt.u32(2092000000)),
        ('peripheral-frequency', mkadt.u32(TIMEBASE)),
        ('fixed-frequency', mkadt.u32(TIMEBASE)),
    ]


def build(canvas=(FB_W, FB_H)):
    root = mkadt.build(seed=os.urandom(64), qemu=True)

    set_prop(root, 'compatible', mkadt.cstr('samsung,d2s') +
             mkadt.cstr('samsung,dreamlte') +
             mkadt.cstr('samsung,a5xelte') +
             mkadt.cstr('samsung,exynos9825') +
             mkadt.cstr('AppleARM'))

    chosen = child(root, 'chosen')
    set_prop(chosen, 'dram-base', mkadt.u64(DRAM_BASE))
    set_prop(chosen, 'dram-size', mkadt.u64(DRAM_SIZE))
    set_prop(chosen, 'firmware-version', mkadt.cstr('d2s-entry'))
    set_prop(chosen, 'system-firmware-version', mkadt.cstr('d2s-entry'))

    cpus = child(root, 'cpus')
    cpu0 = child(cpus, 'cpu0')
    for key, value in cpu_node(0):
        if key != 'cpu-id':
            set_prop(cpu0, key, value)

    # Single-core initial bring-up (cpu0 = Cortex-A55 MPIDR 0x0)
    cpus.children = [cpu0]

    arm_io = child(root, 'arm-io')
    set_prop(arm_io, 'device_type', mkadt.cstr('d2s-io'))
    set_prop(arm_io, 'compatible', mkadt.cstr('samsung,exynos9825-io') + mkadt.cstr('arm-io'))
    set_prop(arm_io, 'ranges', mkadt.u64(0, 0x10000000, 0xf0000000))
    arm_io.children = [n for n in arm_io.children if n.prop('name') == mkadt.cstr('wdt')]

    # GICv2 on Exynos 9825: GICD 0x10101000, GICC 0x10102000
    # Relative to arm-io base 0x10000000 -> 0x0101000 and 0x0102000
    arm_io.children.append(mkadt.node('gic', [
        ('compatible', mkadt.cstr('arm,cortex-a15-gic')),
        ('interrupt-controller', mkadt.cstr('master')),
        ('virtual-timer-intid', mkadt.u32(30)),
        ('reg', mkadt.u64(0x0101000, 0x1000, 0x0102000, 0x1000)),
    ]))

    arm_io.children.append(mkadt.node('disp0', [
        ('device_type', mkadt.cstr('display-subsystem')),
        ('compatible', mkadt.cstr('samsung,d2s-display') +
         mkadt.cstr('samsung,dreamlte-display') +
         mkadt.cstr('samsung,a5xelte-display')),
        ('canvas-width', mkadt.u32(canvas[0])),
        ('canvas-height', mkadt.u32(canvas[1])),
    ]))

    root.children = [n for n in root.children if n.prop('name') not in
                     (mkadt.cstr('sweet-fbcon'), mkadt.cstr('sweet-ufs'))]

    root.children.append(mkadt.node('a5xelte-fbcon', [
        ('reg', mkadt.u64(FB_PHYS, FB_W * FB_H * 4)),
        ('width', mkadt.u32(FB_W)),
        ('height', mkadt.u32(FB_H)),
        ('stride', mkadt.u32(FB_W * 4)),
    ]))

    # Exynos 9825 MicroSD controller: dwmmc2@13D00000
    root.children.append(mkadt.node('a5xelte-emmc', [
        ('reg', mkadt.u64(0x13d00000, 0x2000)),
    ]))

    # Exynos 9825 UFS 3.0 controller: 13D60000 (bsd/dev/sweet_ufs.c, EXYNOS_UFS)
    root.children.append(mkadt.node('dreamlte-ufs', [
        ('reg', mkadt.u64(0x13d60000, 0x200, 0x13d61100, 0x200)),
    ]))

    return root


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--canvas', default=f'{FB_W}x{FB_H}',
                        help='display size presented to iOS, WxH')
    args = parser.parse_args()
    blob = adt.serialize(build(tuple(int(v) for v in args.canvas.split('x'))))
    args.output.write_bytes(blob)
    print(f'[+] {args.output}: {len(blob)} bytes üretildi.')
