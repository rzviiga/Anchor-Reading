#!/usr/bin/env python3
"""Direct Swift build, also works when the local SwiftPM manifest SDK is mismatched."""
from pathlib import Path
import plistlib
import json
import platform
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
build = root / '.build' / 'native'
build.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(['xcrun','--show-sdk-path'], text=True).strip()
installed_15 = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk')
if installed_15.exists(): sdk = str(installed_15)
base = ['xcrun','swiftc','-O','-swift-version','5','-target',platform.machine()+'-apple-macosx14.0',
        '-sdk',sdk,'-module-cache-path',str(root/'.build/module-cache-15')]
# Some partially upgraded CLT installations contain duplicate SwiftBridging maps.
# A compiler-only VFS overlay hides the obsolete duplicate. System files are untouched.
headers=Path('/Library/Developer/CommandLineTools/usr/include/swift')
old=headers/'module.modulemap'; new=headers/'bridging.modulemap'
if old.exists() and new.exists() and 'module SwiftBridging' in old.read_text() and 'module SwiftBridging' in new.read_text():
    empty=build/'empty.modulemap';empty.write_text('// Duplicate legacy module map omitted for this build.\n')
    overlay=build/'toolchain-overlay.json'
    overlay.write_text(json.dumps({'version':0,'roots':[{'type':'file','name':str(old),'external-contents':str(empty)}]}))
    base += ['-vfsoverlay',str(overlay),'-Xcc','-ivfsoverlay','-Xcc',str(overlay)]
def run(args):
    result=subprocess.run(args,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    with (root/'qa/build.log').open('a') as log:log.write(result.stdout)
    if result.returncode:
        print('\n'.join(result.stdout.splitlines()[:65]),file=sys.stderr)
        raise SystemExit(result.returncode)
    if result.stdout:print(result.stdout)
run(base+['-parse-as-library','-emit-library','-static','-emit-module','-module-name','AnchorOverlayCore',
          '-emit-module-path',str(build/'AnchorOverlayCore.swiftmodule')]+[str(p) for p in sorted((root/'Sources/AnchorOverlayCore').glob('*.swift'))]+
    ['-o',str(build/'libAnchorOverlayCore.a')])
for module in ['AnchorOverlay','OverlayBench','OverlayChecks','OverlayRegression']:
    options=['-parse-as-library'] if module=='AnchorOverlay' else []
    run(base+options+['-I',str(build),'-L',str(build),'-lAnchorOverlayCore']+
        [str(p) for p in sorted((root/'Sources'/module).glob('*.swift'))]+['-o',str(build/module)])
app=root/'dist/Anchor Overlay.app'
macos=app/'Contents/MacOS';macos.mkdir(parents=True,exist_ok=True)
resources=app/'Contents/Resources';resources.mkdir(parents=True,exist_ok=True)
shutil.copy2(build/'AnchorOverlay',macos/'AnchorOverlay')
info={'CFBundleDevelopmentRegion':'zh_CN','CFBundleDisplayName':'Anchor Overlay','CFBundleExecutable':'AnchorOverlay',
      'CFBundleIdentifier':'local.anchorenglish.overlay','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'Anchor Overlay',
      'CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.6.0','CFBundleVersion':'6','LSMinimumSystemVersion':'14.0',
      'LSUIElement':True,'NSHighResolutionCapable':True,'NSScreenCaptureUsageDescription':'在本机识别屏幕英文并叠加词首强调。不录音、不上传、不保存截图。',
      'NSHumanReadableCopyright':'Anchor Overlay prototype, 2026'}
with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump(info,f)
run(['codesign','--force','--sign','-','--identifier','local.anchorenglish.overlay',str(app)])
run(['codesign','--verify','--strict',str(app)])
print('Built and ad-hoc signed:',app)
