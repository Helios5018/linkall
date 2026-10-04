#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/scratch/ReplyFixture.app"
mkdir -p "$APP/Contents/MacOS"
swiftc scripts/ReplyFixture/main.swift -o "$APP/Contents/MacOS/ReplyFixture"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.linkall.reply-fixture','CFBundleName':'Reply Fixture','CFBundleExecutable':'ReplyFixture','CFBundlePackageType':'APPL','CFBundleVersion':'1'}))
PY
codesign --force --sign - "$APP"
echo "$APP"
