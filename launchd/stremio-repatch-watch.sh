#!/bin/bash
# Started by launchd (nl.polman.stremio-repatch) when the Stremio bundle changes, plus hourly as a fallback.
# Re-applies the patches only when they are missing (after a Stremio auto-update). Idempotent, with a lock.
DIR=$(cd "$(dirname "$0")/.." && pwd)
S=/Applications/Stremio.app/Contents/MacOS/server.js
LOG=$DIR/backups/repatch.log
LOCK=/tmp/stremio-repatch.lock
[ -f "$S" ] || exit 0
mkdir -p "$DIR/backups"; mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
# wait until the file has been stable for 20 s (the updater may still be writing)
for _ in 1 2 3 4 5 6; do a=$(stat -f %z "$S"); sleep 20; b=$(stat -f %z "$S"); [ "$a" = "$b" ] && break; done
DRY=1 bash "$DIR/stremio-upnp-patch.sh" 2>&1 | grep -q "applied" || exit 0
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Stremio.app/Contents/Info.plist 2>/dev/null)
echo "$(date '+%F %T') patches missing (Stremio $VER), re-applying" >> "$LOG"
if bash "$DIR/stremio-upnp-patch.sh" >> "$LOG" 2>&1; then
  echo "$(date '+%F %T') ok" >> "$LOG"
  osascript -e "display notification \"Stremio $VER was updated. Casting patches re-applied, Stremio restarted.\" with title \"Stremio patch\"" 2>/dev/null
else
  echo "$(date '+%F %T') FAILED, see above" >> "$LOG"
  osascript -e "display notification \"Stremio $VER: re-applying the casting patches failed. See backups/repatch.log.\" with title \"Stremio patch\" sound name \"Basso\"" 2>/dev/null
fi
