#!/usr/bin/env python3
"""Validate project Markdown links and live rule/source pointers; gitignored local-only docs may be absent."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

root = Path(__file__).resolve().parent.parent
files = [root / 'README.md', root / 'AGENTS.md', *sorted((root / 'docs').rglob('*.md')), *sorted((root / 'src').rglob('README.md'))]
errors = []

def missing(target):
    return not target.exists() and subprocess.run(['git', 'check-ignore', '-q', str(target)], cwd=root).returncode != 0

for path in files:
    text = path.read_text()
    for link in re.findall(r'\]\(([^)]+)\)', text):
        link = link.split(' "', 1)[0].strip('<>')
        if '://' in link or link.startswith(('#', 'mailto:')):
            continue
        target = unquote(link.split('#', 1)[0])
        if target and missing(path.parent / target):
            errors.append(f'{path.relative_to(root)}: broken link {target}')
    for target in re.findall(r'`((?:src|scripts|tests|docs)/[^`]+)`', text):
        if any(c in target for c in ['*', '<', '>', ' ']):
            continue
        if missing(root / target):
            errors.append(f'{path.relative_to(root)}: missing project path {target}')
for required in ['LinkAll架构.md', '隐私与数据流.md', '依赖与授权.md', 'Agent回复建议.md']:
    if not (root / 'docs' / required).is_file():
        errors.append(f'docs/{required}: missing current document')
if errors:
    print('\n'.join(errors)); sys.exit(1)
print(f'Validated {len(files)} Markdown files: local links and live project paths are valid.')
