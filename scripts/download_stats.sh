#!/usr/bin/env bash
# Plugin download counts from GitHub's API (not shown on the website; anyone could query the API, though).
# "stable" = qfield-plugin-merginmaps.zip, the README link and QR code: real installs and updates.
# "versioned" = qfield-plugin-merginmaps-v<version>.zip: pinned installs, plus one per CI run (install_e2e).
# Counts are downloads, not people: an update or reinstall counts again. Needs the gh CLI.
set -euo pipefail
repo="${1:-saberraz/qfield-plugin-merginmaps}"
gh api "repos/$repo/releases" --paginate -q '.[] | .tag_name as $t | .published_at[:10] as $d | .assets[]
  | [$t, $d, (if (.name | test("-v[0-9]")) then "versioned" else "stable" end), .download_count] | @tsv' |
  awk -F'\t' 'BEGIN { printf "%-10s %-11s %-10s %s\n", "release", "published", "file", "downloads" }
              { printf "%-10s %-11s %-10s %d\n", $1, $2, $3, $4; if ($3 == "stable") s += $4; else v += $4 }
              END { printf "\ntotal: %d stable (README/QR installs and updates), %d versioned\n", s, v }'
echo "note: the first 9 stable downloads of v0.6.0 were the maintainer's own install tests (before 2026-10-23 CI change)"
