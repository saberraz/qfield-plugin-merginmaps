#!/usr/bin/env bash
# Records the two-way sync screencast: QField (part 1) + the Mergin Maps dashboard's edit log (part 2).
#   S=<work dir with extracted QField AppImage> PYTHON=<python with GDAL, mergin-client, websocket-client> \
#     tests/qfield/record_sync_screencast.sh [output.mp4]
# Needs a 1280x960 X display on :99:  Xwayland :99 -geometry 1280x960 -decorate -noreset &
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; root="$here/../.."
out="${1:-$root/docs/media/qfield-mergin-maps-sync-demo.mp4}"
work="$S/screencast"; rm -rf "$work"; mkdir -p "$work"
: "${PYTHON:?python with GDAL, mergin-client and websocket-client}"

# fresh server with the web dashboard and the four test projects
WEB=1 MERGIN_TEST_DIR="${MERGIN_TEST_DIR:-$S/mergin-test-server}" "$root/tests/server/start_local_mergin.sh"
TMPDIR="$work" "$root/tests/server/prepare_test_projects.sh" >/dev/null

# part 1: QField (540x960, top-left of :99)
RECORD="$work/part1.mp4" RECORD_SIZE=540x960 E2E_TIMEOUT=300 "$here/run_e2e.sh" sync_demo >/dev/null

# part 2: the Mergin Maps dashboard (1280x960)
ffmpeg -loglevel error -y -f x11grab -draw_mouse 0 -framerate 25 -video_size 1280x960 -i :99.0+0,0 \
  -c:v libopenh264 -b:v 4M -pix_fmt yuv420p "$work/part2.mp4" &
rec=$!
DISPLAY=:99 "$PYTHON" -I "$here/web/dashboard_demo.py" mergin/dummy-points
kill -INT "$rec"; wait "$rec" || true

# compose: QField part centred on a Mergin "forest" canvas with titles, then the dashboard part
bold="$(fc-match -f '%{file}' 'sans:bold')"; regular="$(fc-match -f '%{file}' 'sans')"
ffmpeg -loglevel error -y -i "$work/part1.mp4" -i "$work/part2.mp4" -filter_complex "\
[0:v]trim=start=${PART1_SKIP:-3},setpts=PTS-STARTPTS,pad=1280:960:370:0:color=0x004C45,\
drawtext=fontfile=$bold:text='QField':fontcolor=white:fontsize=40:x=(370-tw)/2:y=400,\
drawtext=fontfile=$regular:text='4.3.6 on Linux':fontcolor=0x73D19C:fontsize=22:x=(370-tw)/2:y=455,\
drawtext=fontfile=$bold:text='Mergin Maps':fontcolor=white:fontsize=40:x=910+(370-tw)/2:y=400,\
drawtext=fontfile=$regular:text='QField plugin':fontcolor=0x73D19C:fontsize=22:x=910+(370-tw)/2:y=455,\
fps=25,format=yuv420p[a];\
[1:v]trim=start=${PART2_SKIP:-1.5},setpts=PTS-STARTPTS,fps=25,format=yuv420p[b];\
[a][b]concat=n=2:v=1:a=0[out]" -map "[out]" -c:v libopenh264 -b:v 4M -movflags +faststart "$out"
echo "screencast: $out"
