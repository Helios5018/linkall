#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! test -d build/Yiliu.app || ! test -d build/LinkAll.app; then scripts/build.sh; fi
exec python3 scripts/manage-install.py install
