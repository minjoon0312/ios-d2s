#!/bin/bash
# Build the d1x XNU boot image.  Usage: make_boot_d1x.sh <kernel Mach-O> <out.img>
#   CPUS=N        cores (N>1 builds the 8-core ADT, order A55,A75,M4; 0140)
#   EXTRA="k=v .." extra boot-args; a key already in the base line is REPLACED (XNU takes the first match)
#   CONSOLE=off   hide the kernel text (a5fb_noconsole=1)
#   FILES=/abs/path.bin   D2SFiles blob (tools/mkfiles.py) installed into the iOS root at boot (0133)
#   D2S_DRAM_SIZE=0x...   RAM for XNU (default 512 MiB; more needs vm_compression_limit and still panics)
set -euo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$BASE/ios-d2s"
K="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; OUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
CMD="debug=0xc serial=3 cpus=1 keepsyms=1 -noprogress rd=ufsroot0 ufsroot=userdata unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_hz=10 a5keys=1 s8touch=1 sweetbattery=0 cs_enforcement_disable=1 amfi_get_out_of_my_way=1"
CPUS="${CPUS:-1}"
CMD="${CMD/cpus=1/cpus=$CPUS}"
for kv in ${EXTRA:-}; do
  k="${kv%%=*}"
  if [[ " $CMD " == *" $k="* ]]; then CMD=$(echo " $CMD " | sed -E "s# $k=[^ ]*# $kv#" | sed -E 's/^ //; s/ $//'); else CMD="$CMD $kv"; fi
done
[ "${CONSOLE:-on}" = off ] && CMD="$CMD a5fb_noconsole=1"
cd "$REPO"
ARGS=()
if [ "$CPUS" -gt 1 ]; then
  python3 tools/mkadt_d2s.py d2s.adt --canvas 1125x2436
  python3 tools/d2s_adt_add_cpus.py d2s.adt d2s_smp.adt
  ARGS+=(--adt d2s_smp.adt)
fi
[ -n "${FILES:-}" ] && ARGS+=(--files "$FILES")
python3 tools/d2s_make_boot.py ${ARGS[@]+"${ARGS[@]}"} --stock "$BASE/build/d1x_boot_header.img" --kernel "$K" --cmdline "$CMD" --out "$OUT"
SZ=$(stat -f %z "$OUT"); [ "$SZ" -le 57671680 ] || { echo "ERROR: $SZ bytes > BOOT partition 57671680"; exit 1; }
echo "cmdline: $CMD"
shasum -a 256 "$OUT"
