#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DRIVER="$PWD/scratch/YiliuHIDDriver.app"
mkdir -p "$DRIVER/Contents/MacOS"
swiftc scripts/HIDDriver/main.swift -o "$DRIVER/Contents/MacOS/YiliuHIDDriver"
python3 - "$DRIVER/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':'work.yiliu.hid-test-driver','CFBundleName':'Yiliu HID Test Driver','CFBundleExecutable':'YiliuHIDDriver','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSUIElement':True}))
PY
codesign --force --sign - "$DRIVER"
echo "$DRIVER"
