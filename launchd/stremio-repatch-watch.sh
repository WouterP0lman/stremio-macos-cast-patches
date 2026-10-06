#!/bin/bash
# Started by launchd (nl.polman.stremio-repatch) when the Stremio bundle changes, plus hourly as a fallback.
# Builds again only when Stremio itself was updated (the installed server.js is no
# longer a build of this repo for this version). It never restarts Stremio during a
# cast: while one runs it waits for the next hourly round. A failure is reported once
# per Stremio version per day.
DIR=$(cd "$(dirname "$0")/.." && pwd)
APP=/Applications/Stremio.app
S=$APP/Contents/MacOS/server.js
LOG=$DIR/backups/repatch.log
LOCK=/tmp/stremio-repatch.lock
[ -f "$S" ] || exit 0
mkdir -p "$DIR/backups"; mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
# wait until the file has been stable for 20 s (the updater may still be writing)
for _ in 1 2 3 4 5 6; do a=$(stat -f %z "$S"); sleep 20; b=$(stat -f %z "$S"); [ "$a" = "$b" ] && break; done
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null)
ST=$(bash "$DIR/install.sh" --status 2>/dev/null)
echo "$ST" | grep -q ": built" && ! echo "$ST" | grep -q "updated since" && exit 0
# a cast or stream in progress: ffmpeg runs under Stremio's server; try again later
pgrep -f "Stremio.app/Contents/MacOS/ffmpeg" >/dev/null && { echo "$(date '+%F %T') Stremio $VER needs a build, waiting: something is playing" >> "$LOG"; exit 0; }
echo "$(date '+%F %T') Stremio $VER is not built with the patches, building" >> "$LOG"
if bash "$DIR/install.sh" --no-watch >> "$LOG" 2>&1; then
  echo "$(date '+%F %T') ok" >> "$LOG"
  osascript -e "display notification \"Stremio $VER was updated. Casting patches built again, Stremio restarted.\" with title \"Stremio patch\"" 2>/dev/null
else
  echo "$(date '+%F %T') FAILED, see above" >> "$LOG"
  STAMP=$DIR/backups/.failed-$VER-$(date +%F)
  if [ ! -e "$STAMP" ]; then
    : > "$STAMP"
    osascript -e "display notification \"Stremio $VER: building the casting patches failed. Stremio itself still works. See backups/repatch.log.\" with title \"Stremio patch\" sound name \"Basso\"" 2>/dev/null
  fi
fi
