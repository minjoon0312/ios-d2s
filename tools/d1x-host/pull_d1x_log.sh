#!/bin/bash
# Pull the iOS kernel's logs while the phone is in TWRP: the persistent console ring in the last
# 4 MiB + 1 block of USERDATA (sweet_ufs.c) and /sys/fs/pstore. Usage: tools/pull_d1x_log.sh [outdir]
set -euo pipefail
S="${ADB_SERIAL:?set ADB_SERIAL to the phone adb serial}"
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/logs/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"; A="adb -s $S"
$A wait-for-recovery 2>/dev/null || $A wait-for-device
DEV=$($A shell 'ls /dev/block/by-name/userdata 2>/dev/null || ls /dev/block/platform/*/by-name/userdata' | tr -d '\r' | head -1)
SZ=$($A shell "blockdev --getsize64 $DEV" | tr -d '\r'); START=$(( SZ / 4096 - 1025 ))
$A exec-out "dd if=$DEV bs=4096 skip=$START count=1025 2>/dev/null" > "$OUT/sweetlog.raw"
python3 - "$OUT/sweetlog.raw" "$OUT/sweetlog.txt" <<'PY'
import struct, sys
raw = open(sys.argv[1], 'rb').read()
magic, ver, size, total, seq = struct.unpack_from('<8sIIQQ', raw, 0)
if magic != b'SWEETLOG':
    print('no SWEETLOG header (log never flushed this boot)'); sys.exit(0)
ring = raw[4096:4096 + size]
text = ring[:total] if total <= size else ring[total % size:] + ring[:total % size]
open(sys.argv[2], 'wb').write(text.replace(b'\0', b''))
print(f'sweetlog: {total} bytes, flush #{seq}')
PY
for f in $($A shell 'ls /sys/fs/pstore 2>/dev/null' | tr -d '\r'); do $A exec-out "cat /sys/fs/pstore/$f" > "$OUT/pstore-$f.txt"; done
echo "saved in $OUT"
