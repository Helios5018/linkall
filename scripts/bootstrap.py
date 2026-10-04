#!/usr/bin/env python3
"""Fetch immutable Rime dependencies; no Homebrew runtime dependencies or AI models."""
import hashlib
import json
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / 'scripts/dependencies.json').read_text())
TEMP = ROOT / 'scratch/deps'
VENDOR = ROOT / 'Vendor'
for path in [TEMP, VENDOR / 'include', VENDOR / 'lib', VENDOR / 'Rime', VENDOR / 'Licenses']:
    path.mkdir(parents=True, exist_ok=True)

archive = TEMP / 'rime.tar.bz2'
if not archive.exists():
    urllib.request.urlretrieve(PINS['librime']['url'], archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != PINS['librime']['sha256']:
    raise SystemExit('librime checksum mismatch')
with tarfile.open(archive) as tar:
    for member in tar.getmembers():
        destination = (TEMP / member.name).resolve()
        if TEMP.resolve() not in destination.parents:
            raise SystemExit('Unsafe archive path')
        if member.issym() and Path(member.linkname).is_absolute():
            raise SystemExit('Unsafe archive link')
    tar.extractall(TEMP)
for header in (TEMP / 'dist/include').glob('rime_api*.h'):
    shutil.copy2(header, VENDOR / 'include')
shutil.copy2(TEMP / 'dist/lib/librime.1.17.0.dylib', VENDOR / 'lib/librime.1.dylib')
link = VENDOR / 'lib/librime.dylib'
if not link.exists():
    link.symlink_to('librime.1.dylib')

for name, revision in PINS['schemas'].items():
    checkout = TEMP / name
    if not checkout.exists():
        subprocess.run(['git', 'clone', '--quiet', f'https://github.com/rime/rime-{name}.git', str(checkout)], check=True)
    subprocess.run(['git', '-C', str(checkout), 'checkout', '--quiet', revision], check=True)
    for filename in ['LICENSE', 'AUTHORS']:
        if (checkout / filename).exists():
            shutil.copy2(checkout / filename, VENDOR / 'Licenses' / f'{name}-{filename}')

files = {
    'prelude': ['default.yaml', 'punctuation.yaml', 'key_bindings.yaml', 'symbols.yaml'],
    'double-pinyin': ['double_pinyin_flypy.schema.yaml'],
    'pinyin-simp': ['pinyin_simp.schema.yaml', 'pinyin_simp.dict.yaml'],
    'stroke': ['stroke.schema.yaml', 'stroke.dict.yaml'],
    'wubi': ['wubi86.schema.yaml', 'wubi86.dict.yaml'],
}
for name, names in files.items():
    for filename in names:
        shutil.copy2(TEMP / name / filename, VENDOR / 'Rime' / filename)

# Import pinned tables, keeping upstream attribution in each file.
# App-owned names avoid replacing a user's existing dictionaries or customizations.
ice = PINS['dictionaries']['rime-ice']
ice_dir = VENDOR / 'Rime/linkinput_ice'
ice_dir.mkdir(parents=True, exist_ok=True)
ice_base = f"https://raw.githubusercontent.com/{ice['repository']}/{ice['commit']}"
for name in ice['tables']:
    urllib.request.urlretrieve(f'{ice_base}/cn_dicts/{name}.dict.yaml', ice_dir / f'{name}.dict.yaml')
urllib.request.urlretrieve(f'{ice_base}/LICENSE', VENDOR / 'Licenses/rime-ice-LICENSE')
urllib.request.urlretrieve(f'{ice_base}/README.md', VENDOR / 'Licenses/rime-ice-README.md')
(VENDOR / 'Rime/linkinput_ice.dict.yaml').write_text(
    '# LinkInput dictionary assembly; upstream tables are unmodified.\n'
    f'# Source: https://github.com/{ice["repository"]}/tree/{ice["commit"]}\n'
    '---\nname: linkinput_ice\n'
    f'version: "{ice["commit"]}"\n'
    'sort: by_weight\nimport_tables:\n' +
    ''.join(f'  - linkinput_ice/{name}\n' for name in ice['tables']) + '...\n')

english_dir = VENDOR / 'Rime/linkinput_en'
english_dir.mkdir(parents=True, exist_ok=True)
for name in ice['english_tables']:
    urllib.request.urlretrieve(f'{ice_base}/en_dicts/{name}.dict.yaml', english_dir / f'{name}.dict.yaml')
(VENDOR / 'Rime/linkinput_english.dict.yaml').write_text(
    '# LinkInput assembly of unmodified rime-ice English tables.\n'
    f'# Source: https://github.com/{ice["repository"]}/tree/{ice["commit"]}\n'
    '---\nname: linkinput_english\n'
    f'version: "{ice["commit"]}"\n'
    'sort: by_weight\nimport_tables:\n' +
    ''.join(f'  - linkinput_en/{name}\n' for name in ice['english_tables']) + '...\n')
shutil.copy2(ROOT / 'scripts/linkinput_english.schema.yaml', VENDOR / 'Rime/linkinput_english.schema.yaml')

# Preserve upstream keyboard algebra and the existing learned-word database.
flypy = VENDOR / 'Rime/double_pinyin_flypy.schema.yaml'
text = flypy.read_text().replace('dictionary: luna_pinyin', 'dictionary: pinyin_simp').replace('    - simplifier\n', '')
# Initials abbreviation: full-pinyin initials (wsm) before the flypy transform, flypy initials (wum) after it.
text = text.replace('    - erase/^xx$/\n', '    - erase/^xx$/\n    - abbrev/^([a-z]).+$/$1/\n').replace('    #- abbrev/^(.).+$/$1/', '    - abbrev/^(.).+$/$1/')
flypy.write_text(text)
for name in ['double_pinyin_flypy', 'pinyin_simp']:
    schema = VENDOR / 'Rime' / f'{name}.schema.yaml'
    text = schema.read_text().replace(
        '  dictionary: pinyin_simp\n',
        '  dictionary: linkinput_ice\n  user_dict: pinyin_simp\n', 1)
    schema.write_text(text)
(VENDOR / 'Rime/default.custom.yaml').write_text('''patch:
  schema_list:
    - schema: double_pinyin_flypy
    - schema: pinyin_simp
    - schema: wubi86
    - schema: linkinput_english
  menu/page_size: 5
  ascii_composer/switch_key/Shift_L: commit_code
  ascii_composer/switch_key/Shift_R: commit_code
''')
urllib.request.urlretrieve('https://raw.githubusercontent.com/rime/librime/33e78140250125871856cdc5b42ddc6a5fcd3cd4/LICENSE', VENDOR / 'Licenses/librime-LICENSE')
native = json.loads((ROOT / 'scripts/native-dependencies.json').read_text())
for name, dep in native.items():
    url = f"https://raw.githubusercontent.com/{dep['repository']}/{dep['commit']}/{dep['license_file']}"
    urllib.request.urlretrieve(url, VENDOR / 'Licenses' / f'{name}-LICENSE')
for name, url in {
    'darts-clone': 'https://raw.githubusercontent.com/rime/librime/33e78140250125871856cdc5b42ddc6a5fcd3cd4/include/COPYING.darts-clone',
    'rapidjson': 'https://raw.githubusercontent.com/Tencent/rapidjson/v1.1.0/license.txt',
    'boost': 'https://raw.githubusercontent.com/boostorg/boost/boost-1.87.0/LICENSE_1_0.txt',
}.items():
    urllib.request.urlretrieve(url, VENDOR / 'Licenses' / f'{name}-LICENSE')
print('Pinned Rime runtime and schemas ready:', VENDOR)
