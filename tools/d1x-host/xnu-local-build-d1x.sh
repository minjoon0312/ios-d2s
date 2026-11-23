#!/bin/bash
# Build the d1x (A5XELTE machine config) XNU kernel on this Mac, the way
# ios-d2s/.github/workflows/xnu.yml does on GitHub (whose macOS runners keep
# cancelling or never picking up the job).
# Derived from coreycusick/ios-guacamole tools/xnu-local-build.sh.
#
#   tools/xnu-local-build-d1x.sh --full   first time, or after an already
#                                         applied patch changed: from scratch
#   tools/xnu-local-build-d1x.sh          apply the xnu/patches/*.patch not
#                                         applied yet, then make (incremental)
#
# Kernel: $XNU_LOCAL/dxb/build/xnu.obj/DEVELOPMENT_ARM64_A5XELTE/kernel.development.a5xelte
#   XNU_LOCAL defaults to <ios-note10>/build/xnu-local
#   D2S_REPO  defaults to <ios-note10>/ios-d2s (source tree with xnu/patches)
#
# Differences from CI:
# - Xcode: whatever xcode-select points at (Xcode 27.2 here; CI uses the
#   runner's Xcode 15/16). Newer iig emits IORPC.kernelContent, which
#   xnu-8796 lacks. Our tree already carries 0083-xcode27-iig-kernel-content;
#   guacamole's xnu/local/0001-iorpc-kernelcontent.patch (kept in
#   tools/xnu-local-patches/) is copied as 9999-local-* so it is tried last
#   and normally shows up as "Skipping" (already applied by 0083).
# - KDK 13.5 (22G74) comes from dortania/KdkSupportPkg like build.sh fetches
#   it, but is unpacked under $XNU_LOCAL (KDKROOT) instead of installed with
#   sudo; xcodes is a stub in $XNU_LOCAL/bin, as in CI.
# - No make -k unless you export MAKEFLAGS=-k yourself.
# Needs brew's gum, cmake, ninja (+ jq).
set -euo pipefail

TOOLS=$(cd "$(dirname "$0")" && pwd)
TOP=$(dirname "$TOOLS")
REPO=${D2S_REPO:-$TOP/ios-d2s}
L=${XNU_LOCAL:-$TOP/build/xnu-local}
LOCAL_PATCHES=$TOOLS/xnu-local-patches
GUAC_RAW=https://raw.githubusercontent.com/coreycusick/ios-guacamole/HEAD/xnu/local/0001-iorpc-kernelcontent.patch

# keep the Mac awake for the ~35 min build
if [ -z "${XNU_LOCAL_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null; then
	export XNU_LOCAL_CAFFEINATED=1
	exec caffeinate -i "$0" "$@"
fi

WF=$REPO/.github/workflows/xnu.yml
DXB_REPO=$(sed -n 's/^  DXB_REPO: //p' "$WF")
DXB_SHA=$(sed -n 's/^  DXB_SHA: //p' "$WF")
[ -n "$DXB_REPO" ] && [ -n "$DXB_SHA" ] || { echo "DXB_REPO/DXB_SHA not found in $WF" >&2; exit 1; }
KDK_NAME="Kernel Debug Kit 13.5 build 22G74"
KDK=$L/KDK_13.5_22G74.kdk
APPLIED=$L/applied-patches.txt
MC=A5XELTE
mc=$(echo "$MC" | tr '[:upper:]' '[:lower:]')
KOUT=$L/dxb/build/xnu.obj/DEVELOPMENT_ARM64_$MC/kernel.development.$mc
export PATH=$L/bin:$PATH MACOS_VERSION=13.5 KERNEL_CONFIG=DEVELOPMENT MACHINE_CONFIG=$MC KDKROOT=$KDK

T0=$(date +%s)
echo "== xnu-local-build-d1x $(date '+%F %T')  repo=$REPO @ $(git -C "$REPO" rev-parse --short HEAD) ($(git -C "$REPO" rev-parse --abbrev-ref HEAD))"
echo "== dxb $DXB_SHA  Xcode: $(xcodebuild -version | tr '\n' ' ')"

mkdir -p "$L/bin"
printf '#!/bin/sh\nexit 0\n' > "$L/bin/xcodes"
chmod +x "$L/bin/xcodes"
for t in jq gum cmake ninja; do
	command -v "$t" >/dev/null || { echo "missing $t (brew install $t)" >&2; exit 1; }
done

mkdir -p "$LOCAL_PATCHES"
if ! compgen -G "$LOCAL_PATCHES/*.patch" >/dev/null; then
	curl -fsSL -o "$LOCAL_PATCHES/0001-iorpc-kernelcontent.patch" "$GUAC_RAW"
fi

if [ ! -d "$KDK/System" ]; then
	echo "== fetching $KDK_NAME"
	meta=$(curl -fsSL https://raw.githubusercontent.com/dortania/KdkSupportPkg/gh-pages/manifest.json |
	    jq -c --arg n "$KDK_NAME" '.[] | select(.name==$n) | {url, sha256sum}')
	url=$(echo "$meta" | jq -r .url)
	sum=$(echo "$meta" | jq -r .sha256sum)
	mkdir -p "$L/kdk-tmp"
	dmg=$L/kdk-tmp/KDK.dmg
	if [ ! -f "$dmg" ] || [ "$(shasum -a 256 "$dmg" | cut -d' ' -f1)" != "$sum" ]; then
		curl -L --fail --retry 3 -C - -o "$dmg" "$url" || curl -L --fail --retry 3 -o "$dmg" "$url"
	fi
	[ "$(shasum -a 256 "$dmg" | cut -d' ' -f1)" = "$sum" ] || { echo "KDK sha256 mismatch" >&2; exit 1; }
	rm -rf "$L/kdk-tmp/mnt" "$L/kdk-tmp/pkg"
	hdiutil attach -readonly -nobrowse -mountpoint "$L/kdk-tmp/mnt" "$dmg" >/dev/null
	pkgutil --expand-full "$L/kdk-tmp/mnt/KernelDebugKit.pkg" "$L/kdk-tmp/pkg" >/dev/null
	hdiutil detach "$L/kdk-tmp/mnt" -quiet
	mv "$L/kdk-tmp/pkg/KDK.pkg/Payload" "$KDK"
	rm -rf "$L/kdk-tmp"
	echo "== KDK unpacked at $KDK"
fi

record() {
	{ (cd "$REPO" && shasum -a 256 xnu/patches/*.patch); shasum -a 256 "$LOCAL_PATCHES"/*.patch; } > "$APPLIED"
}

if [ "${1:-}" = "--full" ] || [ ! -f "$APPLIED" ]; then
	rm -rf "$L/dxb"
	git init -q "$L/dxb"
	git -C "$L/dxb" fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
	git -C "$L/dxb" checkout -q FETCH_HEAD
	cp "$REPO"/xnu/patches/*.patch "$REPO"/xnu/patches/*.sh "$L/dxb/patches/"
	# local patches after ours: build.sh applies patches/*.patch in name order
	for p in "$LOCAL_PATCHES"/*.patch; do
		cp "$p" "$L/dxb/patches/9999-local-$(basename "$p")"
	done
	# same as xnu.yml for A5XELTE: plain arm64 libfirehose_kernel, ARMv8.0
	# code (no LSE atomics) for Cortex-A53/A55
	sed -i '' "s/ARCHS=\"x86_64 arm64e\" VALID_ARCHS=\"x86_64 arm64e\"/ARCHS=arm64 VALID_ARCHS=arm64 OTHER_CFLAGS='-mkernel -nostdinc -Wno-packed -mcpu=cortex-a53 -march=armv8-a+crypto'/" "$L/dxb/build.sh"
	n=$(grep -c "VALID_ARCHS=arm64 OTHER_CFLAGS='-mkernel -nostdinc -Wno-packed -mcpu=cortex-a53" "$L/dxb/build.sh" || true)
	echo "== ARCHS sed hits: $n"
	[ "$n" -ge 1 ] || { echo "A5XELTE ARCHS sed did not match build.sh" >&2; exit 1; }
	(cd "$L/dxb" && bash build.sh)
	record
else
	X=$L/dxb/xnu
	while read -r sum file; do
		now=$(cd "$REPO" && shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1 || true)
		if [ "$now" != "$sum" ]; then
			echo "$file changed (or is gone) since it was applied: run $0 --full"
			exit 1
		fi
	done < "$APPLIED"
	for p in "$REPO"/xnu/patches/*.patch; do
		rel=xnu/patches/$(basename "$p")
		if ! grep -q " $rel\$" "$APPLIED"; then
			echo "Applying patch (incremental): $rel"
			git -C "$X" apply "$p"
		fi
	done
	sed '$d' "$L/dxb/build.sh" > "$L/dxb/build-functions.sh"
	(cd "$L/dxb" && source ./build-functions.sh && BUILDKC=0 BUILDLIB=0 &&
	    setup_xcode_toolchain && choose_xnu && venv && rm -f "$KOUT" &&
	    build_xnu)
	record
fi
ls -l "$KOUT"
shasum -a 256 "$KOUT"
T1=$(date +%s)
echo "== done $(date '+%F %T'), $(( (T1 - T0) / 60 )) min $(( (T1 - T0) % 60 )) s"
