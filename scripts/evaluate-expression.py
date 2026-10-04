#!/usr/bin/env python3
"""Frozen synthetic engineering corpus; does not claim blind evaluation or production quality."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
skill = Path.home() / '.agents/skills/use-llm'
sys.path.insert(0, str(skill / '_lib'))
from load_config import resolve_proxy_token

token = resolve_proxy_token(skill)
if not token:
    raise SystemExit('No configured test credential')
corpus_path = root / 'tests/expression-cases.json'
cases = json.loads(corpus_path.read_text())
results = []
for case in cases:
    env = dict(os.environ, YILIU_TEST_TOKEN=token, YILIU_TEST_BACKGROUND=case['background'])
    response = subprocess.run([str(root / '.build/debug/YiliuProbe'), case['input']], env=env,
                              cwd=root, capture_output=True, text=True, timeout=20)
    if response.returncode == 0:
        result = json.loads(response.stdout)
    else:
        result = {'error': response.stdout.strip(), 'exit_code': response.returncode}
    results.append(dict(case, result=result))
    print(case['id'], 'response' if response.returncode == 0 else 'failed', flush=True)
report = {'scope': 'Synthetic engineering examples, single unblinded review; not a PRD statistical quality gate',
          'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'corpus_sha256': hashlib.sha256(corpus_path.read_bytes()).hexdigest(),
          'client_sha256': hashlib.sha256((root / 'src/LinkInput/Core/AIClient.swift').read_bytes()).hexdigest(),
          'guard_sha256': hashlib.sha256((root / 'src/LinkInput/Core/DraftSession.swift').read_bytes()).hexdigest(),
          'cases': results}
output = root / 'scratch/expression-baseline.json'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(output)
