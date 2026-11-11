#!/usr/bin/env python3
"""Add the Note 10+ secondary CPUs to a d2s ADT.

    python3 tools/d2s_adt_add_cpus.py d2s.adt d2s_smp.adt

XNU numbers CPUs in ADT order and cpus=N keeps the first N, so the order
here decides which cores a given cpus= starts. DT order, so the XNU logical
number is the Linux one:

    cpu0  A55 0x000  (boot core, already in the ADT)
    cpu1  A55 0x001  \\
    cpu2  A55 0x002   | cpus=4: the A55 cluster only
    cpu3  A55 0x003  /
    cpu4  A75 0x004  \\ cpus=6: + the A75s (same DSU)
    cpu5  A75 0x005  /
    cpu6  M4  0x100  \\ cpus=8: + the Mongoose M4 cluster
    cpu7  M4  0x101  /

reg stays the DT reg, the PSCI CPU_ON target. The A55/A75 read MPIDR_EL1
0x81000n00, not n, so cpus>1 needs the kernel with 0140-d1x-smp-cpuid
(reset_vector finds a core's cpu data by this reg, passed by the low
trampoline). Without 0140, A55 #1 (MPIDR low bits 0x100) takes M4 #0's cpu
data and A55 #2..A75 #5 hang.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import adt     # noqa: E402
import mkadt   # noqa: E402
import mkadt_d2s  # noqa: E402

# (MPIDR, mkadt_d2s.cpu_node logical index that describes that core)
ORDER = [(0x001, 1), (0x002, 2), (0x003, 3), (0x004, 4), (0x005, 5), (0x100, 6), (0x101, 7)]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    root = adt.parse(Path(sys.argv[1]).read_bytes())
    if isinstance(root, tuple):
        root = root[0]
    cpus = mkadt_d2s.child(root, 'cpus')
    cpu0 = mkadt_d2s.child(cpus, 'cpu0')
    if cpu0.prop('reg') != mkadt.u32(0):
        sys.exit('cpu0 is not MPIDR 0x0')
    cpus.children = [cpu0]
    for n, (mpidr, logical) in enumerate(ORDER, start=1):
        props = [(k, v) if k != 'cpu-id' else (k, mkadt.u32(n)) for k, v in mkadt_d2s.cpu_node(logical)]
        if dict(props)['reg'] != mkadt.u32(mpidr):
            sys.exit(f'cpu_node({logical}) is not MPIDR {mpidr:#x}')
        cpus.children.append(mkadt.node(f'cpu{n}', props))
    out = adt.serialize(root)
    Path(sys.argv[2]).write_bytes(out)
    print(f'{sys.argv[2]}: {len(out)} bytes, {len(cpus.children)} CPUs')


if __name__ == '__main__':
    main()
