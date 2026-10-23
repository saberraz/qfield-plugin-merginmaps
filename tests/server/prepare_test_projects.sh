#!/usr/bin/env bash
# Seeds the local test server with four projects (owned by officeuser, visible to fielduser):
#   real:  bee-farming (QField's bees sample: GeoPackage + 9 photos + offline raster basemap)
#          wastewater-network (QField's wastewater sample: 3 linked GeoPackages)
#   dummy: dummy-points, dummy-edge-cases (see make_dummy_projects.py)
# Needs PYTHON with GDAL bindings + mergin-client (python3 -m venv --system-site-packages v; v/bin/pip install mergin-client).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PYTHON:?python with GDAL and mergin-client}"
work="${1:-${TMPDIR:-/tmp}/mergin-test-projects}"
rm -rf "$work"; mkdir -p "$work/downloads" "$work/stage"
for p in bees wastewater; do
  curl -sSfL -o "$work/downloads/$p.zip" "https://qfield.org/sample-projects/$p.zip"
done
(cd "$work/stage" && mkdir bee-farming wastewater-network \
  && unzip -q "$work/downloads/bees.zip" -d bee-farming && unzip -q "$work/downloads/wastewater.zip" -d wastewater-network)
# the server rejects files without an extension ("Unsupported file type")
mv "$work/stage/bee-farming/DCIM/LICENSE" "$work/stage/bee-farming/DCIM/LICENSE.txt"
"$PYTHON" -I "$here/make_dummy_projects.py" "$work/stage" >/dev/null
"$PYTHON" -I "$here/seed_projects.py" "$work/stage" 2>&1 | grep -v "Exception ignored\|Traceback\|File \"\|ImportError" || true
