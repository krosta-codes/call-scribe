#!/bin/zsh
# Pulls the latest version and rebuilds (build.sh restarts the app).
# Called by the menu item "Update to vX.Y.Z…" or by hand. Log: ~/Library/Logs/CallScribe-update.log when run from the app.
set -e
cd "$(dirname "$0")"
trap 'osascript -e "display notification \"Update failed, details in ~/Library/Logs/CallScribe-update.log\" with title \"CallScribe\""' ERR
echo "== update $(date '+%F %T') from $(cat VERSION)"
git fetch --tags --quiet
git pull --ff-only --quiet
echo "now $(cat VERSION), building"
./build.sh
