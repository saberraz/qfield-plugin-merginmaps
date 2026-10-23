#!/usr/bin/env bash
# Puts mergin/dummy-points back to its seeded state (v1), as tests/qfield/sync_e2e expects.
# Needs PYTHON with GDAL bindings + mergin-client.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PYTHON:?python with GDAL and mergin-client}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
"$PYTHON" -I -c "
from mergin import MerginClient
MerginClient('http://127.0.0.1:5000', login='officeuser', password='Office-Pass-123').delete_project_now('mergin/dummy-points')
" 2>&1 | grep -v "Exception ignored\|Traceback\|File \"\|ImportError" || true
mkdir "$work/stage"
"$PYTHON" -I "$here/make_dummy_projects.py" "$work/stage" >/dev/null
rm -rf "$work/stage/dummy-edge-cases"
"$PYTHON" -I "$here/seed_projects.py" "$work/stage" 2>&1 | grep -v "Exception ignored\|Traceback\|File \"\|ImportError" || true
