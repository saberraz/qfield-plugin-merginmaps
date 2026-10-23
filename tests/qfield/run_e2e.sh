#!/usr/bin/env bash
# Builds the plugin, installs it as an app plugin into an isolated QField profile, and runs a test project
# whose project plugin drives it. Needs: the local Mergin server (tests/server/start_local_mergin.sh),
# S=<work dir with qfield-app/ (extracted QField AppImage)>, and an X display on :99 (Xwayland :99).
# Usage: run_e2e.sh <test name, e.g. auth_e2e>
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; root="$here/../.."
name="$1"; work="$S/e2e/$name"
rm -rf "$work"; mkdir -p "$work/plugin/mergin" "$work/project"
cp -r "$root/plugin/." "$work/plugin/mergin/"
cp -r "$here/$name/." "$work/project/"; rm -rf "$work/project/driver"; mkdir -p "$work/screenshots" "$work/project/signals"
# install_e2e: INSTALL_URL=<zip URL> overrides the release URL in the project plugin
if [ -n "${INSTALL_URL:-}" ] && [ -f "$work/project/$name.qml" ]; then
  sed -i "s#https://github.com/saberraz/qfield-plugin-merginmaps/releases/latest/download/qfield-plugin-merginmaps.zip#$INSTALL_URL#" "$work/project/$name.qml"
fi
# Optional screencast: RECORD=<file.mp4> RECORD_SIZE=<WxH> records the top-left of display :99 while QField runs.
if [ -n "${RECORD:-}" ]; then
  ffmpeg -loglevel error -y -f x11grab -draw_mouse 0 -framerate 25 -video_size "${RECORD_SIZE:-540x960}" -i :99.0+0,0 \
    -c:v libopenh264 -b:v 3M -pix_fmt yuv420p "$RECORD" &   # libopenh264: Fedora ffmpeg has no libx264
  rec=$!
fi
extra=()
if [ -d "$here/$name/driver" ]; then extra+=("$here/$name/driver"); fi   # optional test-driver app plugin
# NO_PLUGIN=1: start without the plugin installed (install_e2e installs it from the release URL)
plugins=(); [ -n "${NO_PLUGIN:-}" ] || plugins+=("$work/plugin/mergin")
"$here/run_in_qfield.sh" "$work/project/$name.qgs" "${E2E_TIMEOUT:-120}" "$work/qfield.log" "${plugins[@]+"${plugins[@]}"}" "${extra[@]+"${extra[@]}"}" &
qf=$!
# The test logs "E2E SHOT <name>"; capture the X display (:99) when that appears.
# It logs "E2E SERVER <action>" to have tests/qfield/<name>/server_actions.py act as another user on the server;
# completion is signalled by creating project/signals/<action>.done, which the test polls.
taken=""; served=""
while kill -0 "$qf" 2>/dev/null; do
  for shot in $(grep -ao "E2E SHOT [A-Za-z0-9_]*" "$work/qfield.log" 2>/dev/null | awk '{print $3}'); do
    case " $taken " in *" $shot "*) ;; *) sleep 0.5; import -display :99 -window root "$work/screenshots/$shot.png"; taken="$taken $shot";; esac
  done
  for action in $(grep -ao "E2E SERVER [A-Za-z0-9_]*" "$work/qfield.log" 2>/dev/null | awk '{print $3}'); do
    case " $served " in *" $action "*) ;; *)
      served="$served $action"
      "$PYTHON" -I "$here/$name/server_actions.py" "$action" "$work" >> "$work/server_actions.log" 2>&1 || echo "server action $action failed" >> "$work/server_actions.log"
      touch "$work/project/signals/$action.done";;
    esac
  done
  sleep 0.3
done
wait "$qf" || true
if [ -n "${rec:-}" ]; then kill -INT "$rec"; wait "$rec" || true; echo "recorded $RECORD"; fi
if [ -f "$here/$name/server_actions.py" ]; then
  # the check's exit code is what matters (grep -v exits 1 when there is nothing to print)
  set +e
  "$PYTHON" -I "$here/$name/server_actions.py" check "$work" > "$work/check.raw" 2>&1
  check_status=$?
  set -e
  grep -v "Exception ignored\|Traceback\|File \"\|ImportError" "$work/check.raw" | tee "$work/check.log" || true
  exit $check_status
fi
grep -a "E2E \|\[Mergin\]\|Plugin Manager" "$work/qfield.log" || true
ls "$work/screenshots"
