#!/usr/bin/env python3
"""Stage iOS 16.7.16 (20H392) HFSX RootFS for Galaxy Note 10+ (d2s / Exynos 9825).

Must be run with sudo to preserve iOS UID/GID contracts:
  sudo python3 stage_d2s_iosroot.py
"""
import os
import sys
import plistlib
import subprocess
import shutil
from pathlib import Path

if os.geteuid() != 0:
    sys.exit("Hata: Bu script iOS dosya sahipliklerini (root, mobile, _logd) korumak için 'sudo' ile çalıştırılmalıdır:\n  sudo python3 " + sys.argv[0])

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent.parent.parent
IPSW_DIR = Path(os.environ.get("IOS_IPSW_DIR", REPO_DIR / "other_folders" / "ipsw_extracted"))
OUT_DIR = Path(os.environ.get("IOS_OUT_DIR", REPO_DIR / "other_folders"))
SPARSE_IMG = OUT_DIR / "ios16-root.sparseimage"

OS_DMG = IPSW_DIR / "087-86698-044.dmg"
SYSOS_DMG = IPSW_DIR / "087-86593-047.dmg"
APPOS_DMG = IPSW_DIR / "087-86715-047.dmg"

for path in (OS_DMG, SYSOS_DMG, APPOS_DMG):
    if not path.is_file():
        sys.exit(f"Hata: Eksik DMG dosyası: {path}")

mounted_devices = []

def cleanup():
    for dev in reversed(mounted_devices):
        print(f"Ayrılıyor: {dev}")
        subprocess.run(["hdiutil", "detach", dev, "-force"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

import atexit
atexit.register(cleanup)

def attach_dmg(dmg_path, readonly=True, mountpoint=None, owners=False):
    cmd = ["hdiutil", "attach", "-noverify", "-plist"]
    if readonly:
        cmd.extend(["-readonly", "-nobrowse"])
    if mountpoint:
        cmd.extend(["-mountpoint", str(mountpoint)])
    if owners:
        cmd.extend(["-owners", "on"])
    cmd.append(str(dmg_path))
    
    out = subprocess.check_output(cmd)
    data = plistlib.loads(out)
    
    top_dev = None
    mnt = None
    for entity in data.get("system-entities", []):
        if top_dev is None and "dev-entry" in entity:
            top_dev = entity["dev-entry"]
        if "mount-point" in entity:
            mnt = Path(entity["mount-point"])
            top_dev = entity["dev-entry"]
            
    if not mnt or not top_dev:
        raise RuntimeError(f"Bağlama başarısız oldu: {dmg_path}")
        
    mounted_devices.append(top_dev)
    return mnt

print("=== 1. DMG İmajları Bağlanıyor ===")
os_mnt = attach_dmg(OS_DMG)
print(f"  OS bağlandı: {os_mnt}")
sys_mnt = attach_dmg(SYSOS_DMG)
print(f"  SystemOS bağlandı: {sys_mnt}")
app_mnt = attach_dmg(APPOS_DMG)
print(f"  AppOS bağlandı: {app_mnt}")

print("=== 2. HFSX Sparse Image Oluşturuluyor ===")
if SPARSE_IMG.exists():
    SPARSE_IMG.unlink()

subprocess.check_call([
    "hdiutil", "create", "-size", "12g", "-type", "SPARSE", "-layout", "NONE",
    "-fs", "Case-sensitive Journaled HFS+", "-volname", "iOSRoot",
    str(OUT_DIR / "ios16-root")
])

target_mnt = Path("/Volumes/iOSRoot")
if target_mnt.exists():
    # If already mounted or leftover directory
    subprocess.run(["hdiutil", "detach", str(target_mnt), "-force"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

root_mnt = attach_dmg(SPARSE_IMG, readonly=False, mountpoint=target_mnt, owners=True)
print(f"  Hedef HFSX bağlandı: {root_mnt} (owners aktif)")

print("=== 3. OS Dosyaları Kopyalanıyor (rsync) ===")
# Exclude non-essential heavy assets outside launchd -> SpringBoard path
omit = [] if os.environ.get('IOS_FULL') == '1' else [
    '--exclude=/Applications/***',
    '--exclude=/System/Library/LinguisticData/***',
    '--exclude=/System/Library/PreinstalledAssetsV2/***',
    '--exclude=/System/Library/Health/***',
    '--exclude=/System/Library/NanoTimeKit/***',
    '--exclude=/System/Library/Assistant/***',
    '--exclude=/System/Library/OnBoardingBundles/***',
    '--exclude=/System/Library/Audio/***',
]
subprocess.check_call([
    "rsync", "-aH", "--numeric-ids", "--extended-attributes",
    *omit, f"{os_mnt}/", f"{root_mnt}/"
])

print("=== 4. SystemOS ve AppOS Cryptex'leri Kopyalanıyor ===")
(root_mnt / "private/preboot/Cryptexes/OS").mkdir(parents=True, exist_ok=True)
(root_mnt / "private/preboot/Cryptexes/App").mkdir(parents=True, exist_ok=True)

subprocess.check_call([
    "rsync", "-aH", "--numeric-ids", "--extended-attributes",
    f"{sys_mnt}/", f"{root_mnt}/private/preboot/Cryptexes/OS/"
])
subprocess.check_call([
    "rsync", "-aH", "--numeric-ids", "--extended-attributes",
    f"{app_mnt}/", f"{root_mnt}/private/preboot/Cryptexes/App/"
])

print("=== 5. dyld_shared_cache ve Cryptex Bağlantıları Oluşturuluyor ===")
cache_dst = root_mnt / "System/Library/Caches/com.apple.dyld"
cache_dst.mkdir(parents=True, exist_ok=True)
cache_src = root_mnt / "private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld"

for f in cache_src.iterdir():
    if f.is_file():
        target = cache_dst / f.name
        if not target.exists():
            os.link(f, target)

# dyld fallback linkleri
for cryptex in ("OS", "App"):
    src_base = root_mnt / f"private/preboot/Cryptexes/{cryptex}"
    for dirpath, dirnames, filenames in os.walk(src_base):
        for name in filenames:
            src_file = Path(dirpath) / name
            rel = src_file.relative_to(src_base)
            if str(rel).startswith("System/Library/Caches/com.apple.dyld"):
                continue
            dst_file = root_mnt / rel
            if dst_file.exists() or dst_file.is_symlink():
                continue
            dst_file.parent.mkdir(parents=True, exist_ok=True)
            if src_file.is_symlink():
                os.symlink(os.readlink(src_file), dst_file)
            else:
                os.link(src_file, dst_file)

print("=== 6. logd Veritabanı ve AppleKeyStore Hazırlanıyor ===")
db = root_mnt / "private/var/db"
for sub in ("diagnostics", "uuidtext", "diagnostics/timesync"):
    d = db / sub
    d.mkdir(parents=True, exist_ok=True)
    os.chown(d, 272, 272)
    os.chmod(d, 0o751 if sub == "diagnostics" else 0o755)
    marker = d / ".migrated"
    marker.touch(exist_ok=True)
    os.chown(marker, 272, 272)
    os.chmod(marker, 0o644)

keybags = root_mnt / "private/var/keybags"
keybags.mkdir(parents=True, exist_ok=True)
os.chown(keybags, 0, 0)
os.chmod(keybags, 0o700)

kb_file = keybags / "systembag.kb"
kb_file.write_bytes(b"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>
""")
os.chown(kb_file, 0, 0)
os.chmod(kb_file, 0o600)

print("=== 7. sweet-root-tweaks Uygulanıyor (Setup/SpringBoard ayarları) ===")
subprocess.check_call([
    sys.executable, str(SCRIPT_DIR / "sweet-root-tweaks.py"), str(root_mnt)
])

print("=== 8. Doğrulama Kontrolleri ===")
assert (root_mnt / "sbin/launchd").is_file(), "launchd eksik!"
assert (root_mnt / "System/Library/CoreServices/SpringBoard.app/SpringBoard").is_file(), "SpringBoard eksik!"
assert (root_mnt / "System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64").is_file(), "dyld_shared_cache eksik!"

subprocess.run(["df", "-h", str(root_mnt)])
print("\n=== BAŞARIYLA TAMAMLANDI: ios16-root.sparseimage hazır! ===")

