#!/bin/bash
# Metal milestone 1 for the d2s (Galaxy Note 10 5G, Mali-G76): y2sios's Metal driver
# (RedwoodMetal + libredwoodair, stormtroopxyz/y2sios, MIT) over our d2sdrm/D2SGPU path,
# for iOS 16 arm64, ad-hoc signed. Output in tools/d2s-metal/out:
#
#   libredwoodair.dylib    Mesa 25.0.7 Gallium panfrost + softpipe + y2sios's AIR->NIR
#                          frontend (air_metal.c behind air_metal.h's rwa_* API) + d2sdrm.
#                          Install name /usr/lib/libredwoodair.dylib.
#   RedwoodMetal           the MTLDevice driver (y2sios redwoodmetal.m + redwooddrawable.m),
#                          an MH_BUNDLE; dlopens /usr/lib/libredwoodair.dylib
#   Info.plist             the bundle's plist (y2sios metal_plugin.plist)
#   mtltest.dylib          the phone test (tools/d2s-metal/mtltest.m), for d2senv injection
#   mtltest-disc.dylib     the same test through Metal's own discovery (stage 2, d2smetal=1)
#   air_metal_test         y2sios's command-line test of libredwoodair (optional)
#
# Needs: Xcode (iphoneos SDK), python3, curl, git, ninja or the venv's. No LLVM: Mesa 25.0.7's
# panfrost has no OpenCL C shaders (unlike 26.x, see tools/d2s-gl/build.sh), so no host tools.
#
#   Y2SIOS=/path/to/y2sios   use that checkout (default: clone the pinned commit into work/)
#   WORK=/path               work directory (default tools/d2s-metal/work, ~1.5 GB)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=${WORK:-$HERE/work}
OUT=$HERE/out
MESA_VERSION=25.0.7
MESA_SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
Y2SIOS_COMMIT=68fe2e922a52917ed851c1499e394fe5436365b5
UAPI_TAG=mesa-26.2.6	# the panfrost UAPI header d2sdrm.c is written against
mkdir -p "$W" "$OUT"

echo "=== sources"
if [ -z "${Y2SIOS:-}" ]; then
	Y2SIOS=$W/y2sios
	if [ ! -d "$Y2SIOS/.git" ]; then
		git init -q "$Y2SIOS"
		git -C "$Y2SIOS" remote add origin https://github.com/stormtroopxyz/y2sios
		git -C "$Y2SIOS" fetch -q --depth 1 origin $Y2SIOS_COMMIT
		git -C "$Y2SIOS" checkout -q FETCH_HEAD
	fi
fi
got=$(git -C "$Y2SIOS" rev-parse HEAD)
[ "$got" = "$Y2SIOS_COMMIT" ] || echo "warning: y2sios at $got, pinned $Y2SIOS_COMMIT"
YM=$Y2SIOS/kernel/tools/mesa
YU=$Y2SIOS/userland/src

mkdir -p "$W/uapi26/drm-uapi"
for h in panfrost_drm.h drm.h drm_mode.h; do
	[ -s "$W/uapi26/drm-uapi/$h" ] || curl -sL --fail -o "$W/uapi26/drm-uapi/$h" \
		"https://gitlab.freedesktop.org/mesa/mesa/-/raw/$UAPI_TAG/include/drm-uapi/$h"
done

if [ ! -x "$W/venv/bin/meson" ]; then
	python3 -m venv "$W/venv"
	"$W/venv/bin/pip" -q install mako pyyaml packaging meson==1.6.1 ninja
fi
export PATH=$W/venv/bin:$PATH

# The tree is the release archive + y2sios's patches + ours; when any of them changes the tree is
# unpacked again (as y2sios's mk-mesa.sh does).
SUM=$(cat "$YM"/*.patch "$YM"/air/* "$HERE/redwood_d2s.c" "$HERE/patch-mesa25.py" | shasum -a 256 | cut -d' ' -f1)
M=$W/mesa-$MESA_VERSION
if [ ! -d "$M" ] || [ "$(cat "$M/.d2s-patches" 2>/dev/null)" != "$SUM" ]; then
	T=$W/mesa-$MESA_VERSION.tar.xz
	[ -f "$T" ] || curl -sL --fail -o "$T" https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz
	echo "$MESA_SHA256  $T" | shasum -a 256 -c --quiet
	rm -rf "$M" "$W/ios"
	tar xJf "$T" -C "$W"
	for p in "$YM"/*.patch; do patch -s --no-backup-if-mismatch -d "$M" -p1 < "$p"; done
	cp -r "$YM/air" "$M/src/compiler/air"
	mkdir -p "$M/src/redwood-drm"
	cp "$YM/redwood-drm/xf86drm.h" "$M/src/redwood-drm/"
	cp "$HERE/redwood_d2s.c" "$M/src/redwood-drm/redwood_drm.c"
	python3 "$HERE/patch-mesa25.py" "$M" "$W/d2sdrm.o"
	echo "$SUM" > "$M/.d2s-patches"
fi

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
CXX=$(xcrun --sdk iphoneos -f clang++)
TGT=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0)

echo "=== d2sdrm.o (tools/d2s-gl/d2sdrm.c, three functions renamed for redwood_d2s.c)"
"$CC" "${TGT[@]}" -O2 -Wall -I"$W/uapi26" -I"$REPO/tools/d2s-gl/libdrm" -I"$REPO/tools/d2s-gpu" \
	-I"$REPO/tools/d2s-gl" -DdrmIoctl=d2s_drmIoctl -DdrmPrimeFDToHandle=d2s_drmPrimeFDToHandle \
	-DdrmCloseBufferHandle=d2s_drmCloseBufferHandle -c "$REPO/tools/d2s-gl/d2sdrm.c" -o "$W/d2sdrm.o"

echo "=== Mesa $MESA_VERSION (softpipe,panfrost) for iOS"
FLAGS="'-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=16.0'"
cat > "$W/ios-cross.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
objc = '$CC'
ar = '$(xcrun --sdk iphoneos -f ar)'
ranlib = '$(xcrun --sdk iphoneos -f ranlib)'
strip = '$(xcrun --sdk iphoneos -f strip)'
pkg-config = 'false'

[built-in options]
c_args = [$FLAGS]
cpp_args = [$FLAGS, '-fuse-cxa-atexit']
objc_args = [$FLAGS]
c_link_args = [$FLAGS]
cpp_link_args = [$FLAGS]

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
# y2sios's mk-mesa.sh options, with panfrost and without the OSMesa library (not needed for Metal)
[ -f "$W/ios/build.ninja" ] || meson setup "$W/ios" "$M" --cross-file "$W/ios-cross.txt" \
	--wrap-mode=nofallback --prefix=/usr --libdir=lib --buildtype=release -Db_ndebug=true \
	-Dplatforms= -Dgallium-drivers=softpipe,panfrost -Dvulkan-drivers= -Dglx=disabled -Degl=disabled \
	-Dgbm=disabled -Dosmesa=false -Dllvm=disabled -Dshared-glapi=enabled -Dgles1=disabled \
	-Dgles2=enabled -Dopengl=true -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled \
	-Dshader-cache=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dglvnd=disabled \
	-Dvideo-codecs= -Dtools= -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled \
	-Dlmsensors=disabled -Dbuild-tests=false > "$W/meson-setup.log"
PD=src/gallium/drivers/panfrost
ninja -C "$W/ios" $PD/libredwoodair.dylib $PD/air_metal_test > "$W/ninja.log"
strip -x -o "$OUT/libredwoodair.dylib" "$W/ios/$PD/libredwoodair.dylib"
install_name_tool -id /usr/lib/libredwoodair.dylib "$OUT/libredwoodair.dylib" 2>/dev/null
cp "$W/ios/$PD/air_metal_test" "$OUT/air_metal_test"
install_name_tool -change @rpath/libredwoodair.dylib /usr/lib/libredwoodair.dylib "$OUT/air_metal_test" 2>/dev/null || true
echo "libredwoodair: $(nm -gU "$OUT/libredwoodair.dylib" | grep -c ' _rwa_') rwa_* functions," \
	"$(nm -gU "$OUT/libredwoodair.dylib" | grep -c ' _d2sdrm_') d2sdrm_* functions"

echo "=== RedwoodMetal (y2sios userland/src, patched by patch-rwm.py)"
R=$W/rwm
rm -rf "$R"; mkdir -p "$R"
cp "$YU"/redwoodmetal.m "$YU"/redwooddrawable.m "$YU"/redwood_drawable.h "$YU"/m2m.h \
	"$YU"/metal_plugin.plist "$R/"
# headers redwoodmetal.m may include beyond those (copied when present)
for h in $(grep -ho '#include "[a-z_0-9]*\.h"' "$YU"/redwoodmetal.m "$YU"/redwooddrawable.m | sed 's/.*"\(.*\)"/\1/' | sort -u); do
	[ -f "$R/$h" ] || cp "$YU/$h" "$R/"
done
python3 "$HERE/patch-rwm.py" "$R"
OBJC=("$CC" "${TGT[@]}" -O1 -fno-objc-arc -DD2S_METAL=1 -I"$R" -I"$HERE" -Wno-deprecated-declarations)
"${OBJC[@]}" -bundle -framework Foundation -framework IOKit -framework Metal -framework IOSurface \
	-framework CoreFoundation -lobjc -o "$W/RedwoodMetal" "$R/redwoodmetal.m" "$R/redwooddrawable.m" \
	"$HERE/rwd_d2s.c"
# two forms of the same binary, each signed on its own (ad hoc):
#   d2s-RedwoodMetal        a plain file, what mtltest dlopens (milestone 1, no discovery)
#   RedwoodMetal.bundle/    the flat iOS bundle Metal's discovery opens at
#                           /System/Library/Extensions/RedwoodMetal.bundle (milestone 2)
rm -rf "$OUT/RedwoodMetal" "$OUT/Info.plist" "$OUT/_CodeSignature" "$OUT/RedwoodMetal.bundle"
cp "$W/RedwoodMetal" "$OUT/d2s-RedwoodMetal"
mkdir -p "$OUT/RedwoodMetal.bundle"
cp "$W/RedwoodMetal" "$OUT/RedwoodMetal.bundle/RedwoodMetal"
cp "$R/metal_plugin.plist" "$OUT/RedwoodMetal.bundle/Info.plist"
codesign -f -s - "$OUT/RedwoodMetal.bundle" 2>&1 | grep -v "replacing existing signature" || true

for f in libredwoodair.dylib d2s-RedwoodMetal air_metal_test; do
	codesign -f -s - "$OUT/$f" 2>&1 | grep -v "replacing existing signature" || true
done

# The driver is installed under a name with its own hash (mkfiles.py {hash8}), so a new driver
# never lands on a path an old mtltest names; mtltest is compiled with that exact path.
# Its host process is MTLTEST_HOST (default timed, a non-UI daemon; see mtltest.m).
DRV_HASH8=$(shasum -a 256 "$OUT/d2s-RedwoodMetal" | cut -c1-8)
MTLTEST_HOST=${MTLTEST_HOST:-timed}
echo "=== mtltest.dylib (driver /usr/lib/d2s-RedwoodMetal-$DRV_HASH8, host $MTLTEST_HOST)"
"${OBJC[@]}" -dynamiclib -install_name /usr/lib/mtltest.dylib -framework Foundation -framework Metal \
	-framework IOSurface -framework IOKit -framework CoreFoundation -lobjc -Wl,-no_warn_inits \
	-DMTLTEST_DRIVER_PATH="\"/usr/lib/d2s-RedwoodMetal-$DRV_HASH8\"" \
	-DMTLTEST_HOST="\"$MTLTEST_HOST\"" -o "$OUT/mtltest.dylib" "$HERE/mtltest.m"
codesign -f -s - "$OUT/mtltest.dylib" 2>&1 | grep -v "replacing existing signature" || true
# Metal stage 2 (xnu 0164, boot-arg d2smetal): the same test, but the device comes from
# MTLCreateSystemDefaultDevice() through the kernel's IOAcceleratorES and the installed
# /System/Library/Extensions/RedwoodMetal.bundle; no driver is dlopen'ed by hand.
echo "=== mtltest-disc.dylib (Metal discovery, host $MTLTEST_HOST)"
"${OBJC[@]}" -dynamiclib -install_name /usr/lib/mtltest.dylib -framework Foundation -framework Metal \
	-framework IOSurface -framework IOKit -framework CoreFoundation -lobjc -Wl,-no_warn_inits \
	-DMTLTEST_DISCOVERY=1 -DMTLTEST_HOST="\"$MTLTEST_HOST\"" -o "$OUT/mtltest-disc.dylib" "$HERE/mtltest.m"
codesign -f -s - "$OUT/mtltest-disc.dylib" 2>&1 | grep -v "replacing existing signature" || true
ls -la "$OUT" "$OUT/RedwoodMetal.bundle"
file "$OUT"/* "$OUT/RedwoodMetal.bundle/RedwoodMetal"
shasum -a 256 "$OUT"/*.dylib "$OUT/d2s-RedwoodMetal" "$OUT/RedwoodMetal.bundle/RedwoodMetal"
