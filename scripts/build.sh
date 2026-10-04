#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! test -f Vendor/lib/librime.1.dylib || ! test -f Vendor/Rime/linkinput_ice.dict.yaml || ! test -f Vendor/Rime/linkinput_english.dict.yaml; then
    python3 scripts/bootstrap.py
fi
cp scripts/linkinput_english.schema.yaml Vendor/Rime/
swift build -c release
APP="$PWD/build/Yiliu.app"
SHELL_APP="$PWD/build/LinkAll.app"
python3 - "$APP" "$SHELL_APP" <<'PYCLEAN'
import shutil,sys
from pathlib import Path
for name in sys.argv[1:]:
    path = Path(name)
    if path.exists(): shutil.rmtree(path)
PYCLEAN
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/Yiliu "$APP/Contents/MacOS/Yiliu"
mkdir -p "$SHELL_APP/Contents/MacOS" "$SHELL_APP/Contents/Resources"
cp .build/release/LinkAll "$SHELL_APP/Contents/MacOS/LinkInputCompanion"
cp scripts/LinkAll-Info.plist "$SHELL_APP/Contents/Info.plist"
cp docs/隐私与数据流.md "$SHELL_APP/Contents/Resources/Privacy.md"
cp Vendor/lib/librime.1.dylib "$APP/Contents/Frameworks/"
cp -R Vendor/Rime "$APP/Contents/Resources/"
cp -R Vendor/Licenses "$APP/Contents/Resources/"
cp -R src/LinkInput/Core/Prompts "$APP/Contents/Resources/"
cp -R src/LinkInput/App/Sounds "$APP/Contents/Resources/"
# Optional private endpoint defaults; public builds leave the API empty for users to fill in.
if test -f scripts/api-defaults.local.json; then cp scripts/api-defaults.local.json "$APP/Contents/Resources/api-defaults.json"; fi
cp docs/隐私与数据流.md "$APP/Contents/Resources/Privacy.md"
cp docs/依赖与授权.md "$APP/Contents/Resources/Dependencies.md"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp -R scripts/Localizations/ "$APP/Contents/Resources/"
python3 - "$APP/Contents/Info.plist" "$SHELL_APP/Contents/Info.plist" <<'PY'
import hashlib, plistlib, sys
from pathlib import Path
h = hashlib.sha256()
paths = sorted(p for p in Path('src').rglob('*') if p.is_file()) + [Path(name) for name in ['Package.swift', 'scripts/dependencies.json', 'scripts/icon.swift', 'scripts/Info.plist', 'scripts/LinkAll-Info.plist']]
for p in paths:
    h.update(str(p).encode()); h.update(p.read_bytes())
for name in sys.argv[1:]:
    info = Path(name); data = plistlib.loads(info.read_bytes())
    data['YiliuBuildID'] = h.hexdigest()[:16]
    data['LinkAllBuildID'] = h.hexdigest()[:16]
    data['YiliuSupportsQuitCLI'] = True
    info.write_bytes(plistlib.dumps(data, sort_keys=False))
PY
mkdir -p scratch
swiftc src/Shared/UI/BrandIcon.swift scripts/icon.swift -o scratch/linkall-icon-builder
scratch/linkall-icon-builder build/BrandIcons src/Shared/UI/BrandAssets
rm scratch/linkall-icon-builder
cp -R src/Shared/UI/BrandAssets "$SHELL_APP/Contents/Resources/"
cp -R src/Shared/UI/BrandAssets "$APP/Contents/Resources/"
cp build/BrandIcons/LinkAll.icns "$SHELL_APP/Contents/Resources/"
cp build/BrandIcons/LinkInput.icns "$APP/Contents/Resources/"
cp build/BrandIcons/LinkInputTemplate.tiff "$APP/Contents/Resources/LinkInputMenu.tiff"
install_name_tool -delete_rpath "$PWD/Vendor/lib" "$APP/Contents/MacOS/Yiliu"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Yiliu"
# Keychain partitions ad-hoc code by cdhash, so every ad-hoc rebuild asks for the login password before the
# API token can be read. An Apple Development certificate puts the app in a stable teamid partition instead.
# Override with YILIU_SIGN_IDENTITY (SHA-1 or name); release builds must use a Developer ID signature.
TEAM_ID="${YILIU_TEAM_ID:-TB8QP35F7V}"
IDENTITY="${YILIU_SIGN_IDENTITY:-}"
if test -z "$IDENTITY"; then
    for hash in $(security find-identity -v -p codesigning | awk '/"Apple Development: /{print $2}'); do
        if security find-certificate -a -Z -p | awk -v h="$hash" '/^SHA-1 hash:/{on=($3==h)} on&&/BEGIN/{p=1} p&&on{print} /END CERT/{p=0}' \
            | openssl x509 -noout -subject 2>/dev/null | grep -q "OU *= *$TEAM_ID"; then
            IDENTITY="$hash"; break
        fi
    done
fi
if test -n "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/librime.1.dylib"
    codesign --force --sign "$IDENTITY" "$SHELL_APP"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "未找到团队 $TEAM_ID 的 Apple Development 证书，构建已停止，以保护现有钥匙串授权。" >&2
    exit 1
fi
codesign --verify --deep --strict "$APP"
codesign --verify --deep --strict "$SHELL_APP"
echo "$SHELL_APP"
echo "$APP"
