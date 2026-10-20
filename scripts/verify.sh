#!/usr/bin/env bash
set -euo pipefail
KIT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$KIT_DIR"
for script in dev.sh setup.sh lib/ui.sh scripts/*.sh tests/*.sh; do
  bash -n "$script"
done
bash tests/smoke.sh
python3 tests/ui_smoke.py
python3 -m unittest discover -s tests -p 'test_*.py'
bash scripts/package.sh
python3 tests/verify_package.py dist/remote-dev.tar.gz
