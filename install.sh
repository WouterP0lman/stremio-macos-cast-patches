#!/bin/bash
# One command to get casting working, and to keep it working.
#
#   bash install.sh              patch, verify, and offer the update watcher
#   bash install.sh --no-watch   patch and verify only
#   bash install.sh --uninstall  restore the last backup and remove the watcher
#
# What it does:
#   1. finds Stremio's server.js (macOS, Windows, Linux, or $STREMIO_SERVER_JS)
#   2. applies the casting patches, backing up first
#   3. runs the verification suite
#   4. offers to install a watcher, because a Stremio update replaces server.js
#      and silently removes every patch
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
WATCH=1; UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --no-watch) WATCH=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done
AGENT="$HOME/Library/LaunchAgents/nl.polman.stremio-repatch.plist"

if [ "$UNINSTALL" = "1" ]; then
  echo "Removing the watcher and restoring the last backup."
  if [ -f "$AGENT" ]; then
    launchctl bootout "gui/$(id -u)/nl.polman.stremio-repatch" 2>/dev/null || true
    rm -f "$AGENT"; echo "  watcher removed"
  fi
  LAST=$(ls -t "$DIR"/backups/*/server.js.orig 2>/dev/null | head -1)
  if [ -n "$LAST" ]; then
    S=${STREMIO_SERVER_JS:-/Applications/Stremio.app/Contents/MacOS/server.js}
    cp "$LAST" "$S" && echo "  restored $S from $(basename "$(dirname "$LAST")")"
    command -v codesign >/dev/null && [ -d /Applications/Stremio.app ] && \
      codesign --force --sign - --preserve-metadata=entitlements,flags,identifier /Applications/Stremio.app 2>/dev/null
    echo "  restart Stremio to pick it up"
  else
    echo "  no backup found, nothing restored"
  fi
  exit 0
fi

echo "Stremio casting patches"
echo
echo "1/3  patching"
bash "$DIR/stremio-upnp-patch.sh" || { echo "patching failed, nothing was left half-applied"; exit 1; }

echo
echo "2/3  verifying"
bash "$DIR/test/verify.sh" || echo "  (some checks did not pass, see above)"

echo
echo "3/3  surviving Stremio updates"
if [ "$WATCH" = "0" ]; then
  echo "  skipped. A Stremio update will remove the patches; re-run this script afterwards."
elif [ "$(uname)" != "Darwin" ]; then
  echo "  the watcher is macOS only. On this platform, re-run this script after a Stremio update."
elif [ -f "$AGENT" ]; then
  echo "  already installed"
else
  echo "  A Stremio update replaces server.js and removes every patch silently."
  echo "  A small background job can notice that and re-apply them (it also posts a"
  echo "  notification, and only acts when something is actually missing)."
  echo
  echo "  Install it with:"
  echo "    sed \"s#__REPO__#$DIR#g\" \"$DIR/launchd/nl.polman.stremio-repatch.plist\" > \"$AGENT\""
  echo "    launchctl bootstrap gui/\$(id -u) \"$AGENT\""
  echo
  echo "  Remove it later with:  bash install.sh --uninstall"
fi
echo
echo "Done. Cast from Stremio: it should start where you were, with subtitles."
