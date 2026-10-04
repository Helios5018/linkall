#!/usr/bin/env python3
"""Run product API client with existing authorized credentials; never print/store a token."""
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
    raise SystemExit('No configured credential')
env = dict(os.environ, YILIU_TEST_TOKEN=token)
result = subprocess.run([str(root / '.build/debug/YiliuProbe'), *sys.argv[1:]], env=env, cwd=root)
raise SystemExit(result.returncode)
