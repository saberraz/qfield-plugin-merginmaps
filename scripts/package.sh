#!/usr/bin/env bash
# Builds dist/qfield-plugin-merginmaps-v<version>.zip with the plugin files at the zip root, the layout QField expects
# for "Install plugin from URL". QField names the plugin folder after the zip minus "-v<version>".
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(sed -n 's/^version=//p' "$root/plugin/metadata.txt")"
out="$root/dist/qfield-plugin-merginmaps-v$version.zip"

mkdir -p "$root/dist"
rm -f "$out"
(cd "$root/plugin" && zip -qr "$out" . -x '*.swp' '*~')
echo "$out"
