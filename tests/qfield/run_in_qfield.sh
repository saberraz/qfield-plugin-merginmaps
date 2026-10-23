#!/usr/bin/env bash
# Runs real QField (extracted AppImage) headless on <project dir>/<name>.qgs with project plugin <name>.qml.
# Optional 4th, 5th... args: app plugin dirs to install and enable (folder name = uuid).
# Isolated HOME so the user's QField config is untouched. Usage: run_in_qfield.sh <project.qgs> <timeout s> <log>
# QFIELD_POSITIONING_DEVICE=<device id> (e.g. tcp:127.0.0.1:11123) selects and activates a positioning device.
set -uo pipefail
S="${S:?set S to the work dir containing qfield-app/ and qfhome/}"
proj="$(realpath "$1")"; plugin="${proj%.qgs}.qml"; key="${plugin//\//_}"
H=$S/qfhome; rm -rf $H; mkdir -p $H/.config/OPENGIS.ch
cat > $H/.config/OPENGIS.ch/QField.conf <<CONF
[General]
enableInfoCollection=false
${QFIELD_POSITIONING_DEVICE:+positioningDevice=$QFIELD_POSITIONING_DEVICE
positioningDeviceName=Simulated receiver
positioningActivated=true}

[QField]
defaultProject=$proj
loadProjectOnLaunch=true
showWelcomeScreen=false
showMapCanvasGuide=false
FirstRunDone=true

[qfield]
plugins\\$key\\permissionGranted=true
CONF
for plugin_dir in "${@:4}"; do
  uuid="$(basename "$plugin_dir")"; dest="$H/Documents/QField Documents/QField/plugins/$uuid"
  mkdir -p "$(dirname "$dest")" && cp -r "$plugin_dir" "$dest"
  akey="${dest//\//_}/main.qml"; akey="${akey//\//_}"; akey="${akey// /%20}"  # QSettings INI escapes spaces in keys
  printf '%s\n' "plugins\\${akey}\\uuid=$uuid" "plugins\\${akey}\\userEnabled=true" "plugins\\${akey}\\permissionGranted=true" >> $H/.config/OPENGIS.ch/QField.conf
done
HOME=$H XDG_CONFIG_HOME=$H/.config XDG_DATA_HOME=$H/.local/share XDG_CACHE_HOME=$H/.cache \
DISPLAY=:99 QT_QPA_PLATFORM=xcb QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_RULES="default.warning=true;js.warning=true;qml.warning=true;qt.qml.usedbeforedeclared=false" \
timeout "$2" $S/qfield-app/squashfs-root/AppRun > "$3" 2>&1
echo "qfield exit: $?"
