#!/usr/bin/env python3
from pathlib import Path
import zipfile
import plistlib

root=Path(__file__).resolve().parents[1]
app=root/'dist/Anchor Overlay.app'
with (app/'Contents/Info.plist').open('rb') as stream:
    version=plistlib.load(stream)['CFBundleShortVersionString']
output=root/'dist'/f'Anchor-Overlay-{version}.zip'
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob('*')):
        if path.is_file():archive.write(path,Path('Anchor Overlay.app')/path.relative_to(app))
    for file in ['README.md','README.zh-CN.md','LICENSE','Package.swift']:
        archive.write(root/file,Path('源码与说明')/file)
    for folder in ['Sources','Tests','scripts']:
        for path in sorted((root/folder).rglob('*')):
            if path.is_file() and path.suffix not in ('.log','.pyc'):
                archive.write(path,Path('源码与说明')/path.relative_to(root))
    notes=root/'qa'/f'RELEASE-{".".join(version.split(".")[:2])}.md'
    if notes.exists():archive.write(notes,Path('源码与说明/qa')/notes.name)
print(f'{output}: {output.stat().st_size:,} bytes')
