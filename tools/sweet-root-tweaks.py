#!/usr/bin/env python3
"""Apply the SWEET bring-up changes to an iOS root made by tools/mkiosroot.sh.

  sudo sweet-root-tweaks.py MOUNTED_ROOT

MOUNTED_ROOT is the HFS+ image mounted read-write (Linux: run
`fsck.hfsplus -fy` on the image, then `mount -t hfsplus -o loop,force`).
Run as root (it writes root/mobile owned files). Idempotent. This is what
turned the plain mkiosroot.sh output into the images that reach the home
screen (image versions v8-v14 in NOTES.md):

  launchd.plist   _PanicOnCrash -> _PanicOnCrasX (a crashing daemon must not
                  panic the system); CommCenter jobs removed (no baseband: it
                  crash-loops and Setup blocks on its CoreTelephony XPC)
  containers      /private/var/containers/{Bundle,Data/System,Shared/SystemGroup,Temp}
                  (on iOS they live on the data volume)
  migration       LastSystemVersion so DataMigration does not run for an hour
                  on every boot
  audio           VirtualAudio HAL plug-in disabled (mediaserverd crash)
  MediaToolbox    StartRecorderServer=false (camera filter prewarm calls a
                  NULL OpenGL function without a GPU -> mediaserverd crash loop)
  SpringBoard     BKNoWatchdogs (one slow CPU path, no scene-create watchdog
                  kills), no cloud-configuration UI
  Setup           skipped: SetupDone, SetupFinishedAllSteps, SetupVersion 11,
                  mini-buddy flags off
  activation      mobileactivationd data ark seeded; the actual Activated state
                  comes from its Hactivation branch, selected by the /chosen
                  security-status properties in tools/mkadt.py
"""
import glob, os, plistlib, shutil, sys

BUILD, VERSION = '20H392', '16.7.16'
MOBILE = 501


def load(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)


def save(path, data, uid, gid, mode, fmt=plistlib.FMT_BINARY):
    with open(path, 'wb') as f:
        plistlib.dump(data, f, fmt=fmt)
    os.chown(path, uid, gid)
    os.chmod(path, mode)


def merge_pref(root, name, values):
    """Merge keys into /var/mobile/Library/Preferences/NAME.plist (mobile, 0600)."""
    path = os.path.join(root, 'private/var/mobile/Library/Preferences', name + '.plist')
    data = load(path) if os.path.exists(path) else {}
    data.update(values)
    save(path, data, MOBILE, MOBILE, 0o600)
    print('pref', name, sorted(values))


# --- speed profile (research/RESPONSIVE_9825.md section 4) ------------------------------------
SPEED = int(os.environ.get('SWEET_SPEED', '1'))  # 0 as before, 1 speed profile, 2 + experiments

# launchd skips a job whose Disabled is true (Apple's own cache has 36, syslogd and sntpd among
# them). These crash-loop, wait on hardware this port lacks, or only write diagnostics.
SPEED_DISABLE = (
    'com.apple.ReportCrash', 'com.apple.crash_mover', 'com.apple.DumpPanic',
    'com.apple.OTACrashCopier', 'com.apple.DumpBasebandCrash', 'com.apple.spindump',
    'com.apple.tailspind', 'com.apple.hangtracerd', 'com.apple.hangreporter',
    'com.apple.systemstats.microstackshot_periodic', 'com.apple.osanalytics.osanalyticshelper',
    'com.apple.perfdiagsselfenabled',
    'com.apple.bluetoothd', 'com.apple.bluetoothuserd', 'com.apple.cloudpaird',
    'com.apple.locationd', 'com.apple.gpsd', 'com.apple.WirelessRadioManager',
    'com.apple.CommCenterMobileHelper', 'com.apple.CommCenterRootHelper', 'com.apple.abm-helper',
    'com.apple.voicemail.vmd', 'com.apple.biometrickitd.pearl', 'com.apple.nfcd',
    'com.apple.thermalmonitord',
    'com.apple.fairplayd.H2', 'com.apple.nanotimekitcompaniond', 'com.apple.nanoprefsyncd.2',
    'com.apple.homed', 'com.apple.routined', 'com.apple.duetexpertd', 'com.apple.dmd',
    'com.apple.syncdefaultsd', 'com.apple.avconferenced',
    'com.apple.mobile.softwareupdated', 'com.apple.softwareupdateservicesd', 'com.apple.backupd',
    'com.apple.bird', 'com.apple.photoanalysisd', 'com.apple.mediaanalysisd',
    'com.apple.checkerboard', 'com.apple.factory.NFQRCoded',
)
# Started at boot today, needed only when asked: keep the Mach services, drop self-start keys.
SPEED_ON_DEMAND = (
    'com.apple.assistantd', 'com.apple.healthd', 'com.apple.remindd', 'com.apple.peopled',
    'com.apple.sleepd', 'com.apple.familynotification', 'com.apple.askpermissiond',
    'com.apple.accessoryupdaterd', 'com.apple.safetyalertsd', 'com.apple.wcd',
    'com.apple.magicswitchd.companion', 'com.apple.navd', 'com.apple.identityservicesd',
    'com.apple.imagent', 'com.apple.sharingd', 'com.apple.mediaremoted',
    'com.apple.peakpowermanagerd', 'com.apple.MobileInternetSharing', 'com.apple.aggregated',
    'com.apple.amsaccountsd', 'com.apple.seld', 'com.apple.atc',
)
# Never touched (y2sios lost the home screen without nsurlsessiond; the rest are what launchd,
# backboardd, SpringBoard and our AKS/activation/IOWatchdog stand-ins rely on).
SPEED_KEEP = {
    'com.apple.nsurlsessiond', 'com.apple.cloudd', 'com.apple.analyticsd', 'com.apple.dasd',
    'com.apple.mediaserverd', 'com.apple.lsd', 'com.apple.wifid', 'com.apple.watchdogd',
    'com.apple.mobile.keybagd', 'com.apple.mobile.lockdown', 'com.apple.mobileactivationd',
    'com.apple.backboardd', 'com.apple.SpringBoard', 'com.apple.runningboardd',
    'com.apple.configd', 'com.apple.logd',
}
AUTOSTART = ('RunAtLoad', 'KeepAlive', 'StartInterval', 'StartCalendarInterval', 'WatchPaths',
             'QueueDirectories', 'StartOnMount', 'LaunchEvents')
BACKGROUND_EVENTS = ('com.apple.xpc.activity', 'com.apple.bg.system.task')


def speed_jobs(jobs):
    """Disable, make on-demand, and drop scheduled background triggers (SWEET_SPEED >= 1)."""
    disabled, demand, events = [], [], 0
    for job in jobs.values():
        label = job.get('Label')
        if label in SPEED_KEEP:
            continue
        if label in SPEED_DISABLE:
            if not job.get('Disabled'):
                job['Disabled'] = True
                disabled.append(label)
            continue
        if label in SPEED_ON_DEMAND:
            if [k for k in AUTOSTART if job.pop(k, None) is not None]:
                demand.append(label if job.get('MachServices') else label + ' (no service: never starts)')
            continue
        le = job.get('LaunchEvents')
        if le:
            for ev in BACKGROUND_EVENTS:
                if le.pop(ev, None) is not None:
                    events += 1
            if not le:
                del job['LaunchEvents']
    print(f'speed: {len(disabled)} disabled, {len(demand)} on demand, '
          f'{events} background-task triggers removed')
    for label in disabled + demand:
        print('   ', label)


def launchd(root):
    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(path)
    plist = load(path)
    jobs = plist['LaunchDaemons']
    renamed = 0
    for job in jobs.values():
        if '_PanicOnCrash' in job:
            job['_PanicOnCrasX'] = job.pop('_PanicOnCrash')
            renamed += 1
    removed = [k for k, j in jobs.items() if j.get('Label') == 'com.apple.CommCenter']
    for k in removed:
        del jobs[k]
    if SPEED >= 1:
        speed_jobs(jobs)
    save(path, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print(f'launchd.plist: {renamed} _PanicOnCrash renamed, {len(removed)} CommCenter jobs removed')


def containers(root):
    base = os.path.join(root, 'private/var/containers')
    for sub, uid in (('Bundle', 33), ('Data/System', 0), ('Shared/SystemGroup', 0), ('Temp', 0)):
        d = os.path.join(base, sub)
        if not os.path.isdir(d):
            os.makedirs(d)
            os.chown(d, uid, uid)
            os.chmod(d, 0o755)
            print('mkdir', d)


def find_container(root, kind, identifier):
    for meta in glob.glob(os.path.join(root, 'private/var/containers', kind, '*',
                                       '.com.apple.mobile_container_manager.metadata.plist')):
        if load(meta).get('MCMMetadataIdentifier') == identifier:
            return os.path.dirname(meta)
    return None


def activation(root):
    c = find_container(root, 'Data/System', 'com.apple.mobileactivationd')
    if c is None:
        print('warning: no mobileactivationd system container in the image; skipped data ark')
        return
    d = os.path.join(c, 'Library/internal')
    os.makedirs(d, exist_ok=True)
    os.chown(d, MOBILE, MOBILE)
    os.chmod(d, 0o755)
    save(os.path.join(d, 'data_ark.plist'), {
        '-ActivationState': 'Activated', '-BrickState': False,
        '-BuildVersion': BUILD, '-ProductVersion': VERSION,
        '-DataMigrationCompleted': True, '-PreSydroDataMigrationCompleted': True,
    }, MOBILE, MOBILE, 0o600)
    print('data ark', d)


def audio(root):
    src = os.path.join(root, 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin')
    dst_dir = os.path.join(root, 'Library/Audio/Plug-Ins/HAL.disabled')
    if os.path.exists(src):
        os.makedirs(dst_dir, exist_ok=True)
        shutil.move(src, dst_dir)
        print('VirtualAudio.plugin disabled')
    # No Bluetooth here; on the S7 port (wardevsa/ios-a5xelte herolte) this
    # plug-in alone kept idle CPU above 300 % of 800 % (research/COMMUNITY.md).
    for bt in glob.glob(os.path.join(root, '*/Library/Audio/Plug-Ins/HAL/BTAudioHALPlugin.driver')) + \
            glob.glob(os.path.join(root, 'Library/Audio/Plug-Ins/HAL/BTAudioHALPlugin.driver')):
        dst = os.path.join(os.path.dirname(os.path.dirname(bt)), 'HAL.disabled')
        os.makedirs(dst, exist_ok=True)
        if not os.path.exists(os.path.join(dst, os.path.basename(bt))):
            shutil.move(bt, dst)
            print('BTAudioHALPlugin disabled', os.path.relpath(bt, root))
    for conf in glob.glob(os.path.join(root, 'System/Library/Frameworks/MediaToolbox.framework/*/SubServerConfiguration.plist')):
        st = os.stat(conf)
        data = load(conf)
        data['StartRecorderServer'] = False
        save(conf, data, st.st_uid, st.st_gid, st.st_mode & 0o7777, plistlib.FMT_XML)
        print('StartRecorderServer off', os.path.relpath(conf, root))


def main():
    if len(sys.argv) != 2 or not os.path.isdir(os.path.join(sys.argv[1], 'System/Library/xpc')):
        sys.exit(__doc__)
    root = sys.argv[1]
    launchd(root)
    containers(root)
    activation(root)
    audio(root)
    merge_pref(root, 'com.apple.migration', {
        'LastSystemVersion': BUILD,
        'DMUserDataDisposition': {'SyntheticDidUpgrade': False, 'buildVersion': BUILD}})
    springboard = {
        'BKNoWatchdogs': True,
        'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
        'MCForceShowCloudConfigurationUI': False}
    if SPEED >= 1:
        springboard['FBLaunchWatchdogScale'] = 20            # as hakios: slow launches not killed
        merge_pref(root, 'com.apple.frontboard', {'FBLaunchWatchdogScale': 20})
        merge_pref(root, 'com.apple.Accessibility', {
            'EnhancedBackgroundContrastEnabled': True,      # Reduce Transparency: no live blurs
            'ReduceMotionEnabled': True})                   # cross-fades, no parallax/zoom
        merge_pref(root, 'com.apple.assistant.support', {'Assistant Enabled': False})
    if SPEED >= 2:                                          # unverified, measure each
        springboard['SBDontLockEver'] = True
        merge_pref(root, 'com.apple.UIKit', {'UIAnimationDragCoefficient': 0.5})
    merge_pref(root, 'com.apple.springboard', springboard)
    merge_pref(root, 'com.apple.purplebuddy', {
        'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11,
        'daemonizeNeedsToRun': False})
    merge_pref(root, 'com.apple.purplebuddy.notbackedup', {
        k: False for k in ('ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy',
                           'ShouldRunKeychainSyncMiniBuddy', 'ShouldRunMesaMiniBuddy',
                           'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy',
                           'SilentICDPUpgrade')})
    merge_pref(root, 'com.apple.managedconfiguration.notbackedup', {
        'LockdownActivationIndicatesCloudConfigurationAvailable': False})


if __name__ == '__main__':
    main()
