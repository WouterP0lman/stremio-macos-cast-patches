#!/bin/bash
# One command to get casting working, and to keep it working.
#
#   bash install.sh              build from Stremio's own server.js, test, install, offer the update watcher
#   bash install.sh --no-watch   the same without the watcher question
#   bash install.sh --status     say what is installed now, change nothing
#   bash install.sh --uninstall  put Stremio's own server.js back and remove the watcher
#
# How it builds:
#   1. reads the Stremio version from the app and fetches that version's official
#      DMG once (curl with resume), checks Stremio's signature, and keeps its
#      untouched server.js in ~/Library/Caches/stremio-cast-patches/clean-<version>
#   2. applies the patches to a copy of that clean file, never to the file in use
#   3. starts the copy as a test server on port 11471 and only goes on when it answers
#   4. swaps it in, signs the app again and restarts Stremio
# The last line of the installed server.js records which clean file and which
# patches it was built from, so it can always be undone without a backup, and a
# second run with nothing new leaves Stremio alone.
#
# For tests: STREMIO_APP points at another Stremio.app, STREMIO_NO_LAUNCH=1 neither
# quits nor opens Stremio, STREMIO_CAST_CACHE moves the cache.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
APP=${STREMIO_APP:-/Applications/Stremio.app}
MAC=$APP/Contents/MacOS; S=$MAC/server.js; NODE=$MAC/node
CACHE=${STREMIO_CAST_CACHE:-$HOME/Library/Caches/stremio-cast-patches}
NO_LAUNCH=${STREMIO_NO_LAUNCH:-}
TEAM=BH62GT22G7   # Stremio's Apple developer team, as signed on the official DMG
MARK='// stremio-cast-patches manifest '
AGENT="$HOME/Library/LaunchAgents/nl.polman.stremio-repatch.plist"
WATCH=1; MODE=install
for a in "$@"; do
  case "$a" in
    --no-watch) WATCH=0 ;;
    --uninstall) MODE=uninstall ;;
    --status) MODE=status ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

die() { echo "  $*"; exit 1; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
version() { /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null; }
manifest() { tail -1 "$1" 2>/dev/null | sed -n "s#^$MARK##p"; }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null; }
# what the patches are made of; a change here means the installed build is out of date
recipe() { cat "$DIR/stremio-upnp-patch.sh" "$DIR/webui/cast-mediasession.js" "$DIR/webui/cast-nextup.js" "$DIR/webui/cast-remote.js" | shasum -a 256 | cut -d' ' -f1; }
remote() { cat "$DIR/webui/cast-mediasession.js" "$DIR/webui/cast-nextup.js" "$DIR/webui/cast-remote.js"; }

# The untouched server.js of version $1, from the official DMG. Prints its path.
clean_base() {
  local ver=$1 out=$CACHE/clean-$1 dmg=$CACHE/Stremio_arm64-$1.dmg
  local url=https://dl.strem.io/stremio-shell-macos/v$1/Stremio_arm64.dmg
  [ -f "$out/server.js" ] && { echo "$out/server.js"; return 0; }
  mkdir -p "$CACHE"
  if [ ! -f "$dmg" ]; then
    echo "  fetching Stremio $ver from dl.strem.io (about 110 MB)" >&2
    local want; want=$(curl -sIL -m 30 "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n}')
    [ -n "$want" ] || { echo "  dl.strem.io does not know version $ver" >&2; return 1; }
    for _ in 1 2 3 4 5; do
      curl -fL --retry 5 --retry-delay 3 -C - -o "$dmg.part" "$url" >&2 && break
      sleep 3
    done
    [ "$(stat -f %z "$dmg.part" 2>/dev/null)" = "$want" ] || { echo "  download incomplete ($(stat -f %z "$dmg.part" 2>/dev/null) of $want bytes), run again to resume" >&2; return 1; }
    mv "$dmg.part" "$dmg"
  fi
  local mp; mp=$(mktemp -d)
  hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mp" "$dmg" >/dev/null || { rmdir "$mp"; echo "  cannot open $dmg" >&2; return 1; }
  local ok=1
  codesign --verify --deep --strict "$mp/Stremio.app" 2>/dev/null || ok=0
  codesign -dv "$mp/Stremio.app" 2>&1 | grep -q "^TeamIdentifier=$TEAM$" || ok=0
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$mp/Stremio.app/Contents/Info.plist" 2>/dev/null)" = "$ver" ] || ok=0
  if [ $ok = 1 ]; then mkdir -p "$out" && cp "$mp/Stremio.app/Contents/MacOS/server.js" "$out/server.js"; fi
  hdiutil detach "$mp" >/dev/null 2>&1; rmdir "$mp" 2>/dev/null
  [ $ok = 1 ] || { echo "  the DMG for $ver is not signed by Stremio, not using it" >&2; rm -f "$dmg"; return 1; }
  echo "$out/server.js"
}

# clean, built (by this script), old (patched by an earlier version), unknown
state() {
  local base=$1
  [ -n "$(manifest "$S")" ] && { echo built; return; }
  [ -n "$base" ] && [ "$(sha "$S")" = "$(sha "$base")" ] && { echo clean; return; }
  grep -q 'statusOnly33\|var fixXml = function\|\[patch\] ' "$S" && { echo old; return; }
  echo unknown
}

stop_app() {
  [ -n "$NO_LAUNCH" ] && return
  osascript -e 'tell application "Stremio" to quit' 2>/dev/null || true; sleep 2
  pkill -f "Stremio.app/Contents/MacOS" 2>/dev/null || true
}

# sign what changed, then the bundle; Stremio's own signature does not survive an edit
sign_app() {
  command -v codesign >/dev/null || return 0
  for f in "$S" "$MAC/cast-remote.js"; do [ -f "$f" ] && codesign --force --sign - "$f" 2>/dev/null; done
  codesign --force --sign - --preserve-metadata=entitlements,flags,identifier "$APP" 2>/dev/null
  codesign --verify --deep --strict "$APP" 2>/dev/null && echo "  signature OK" || die "signature check failed on $APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
}

start_app() {
  [ -n "$NO_LAUNCH" ] && return
  c="$HOME/Library/Caches/com.westbridge.stremio5-mac/WebKit/NetworkCache"
  [ -d "$c" ] && rm -rf "$c"   # a page cached from before would never load the remote
  for _ in 1 2; do
    open -a "$APP"
    for _ in $(seq 1 30); do curl -s -m 2 -o /dev/null http://127.0.0.1:11470/settings && { echo "  Stremio is running"; return; }; sleep 1; done
  done
  echo "  Stremio did not start, open it yourself"
}

[ -f "$S" ] || die "no Stremio found at $APP (set STREMIO_APP)"
VER=$(version); [ -n "$VER" ] || die "cannot read the Stremio version from $APP"

if [ "$MODE" = status ]; then
  base=$CACHE/clean-$VER/server.js; [ -f "$base" ] || base=""
  st=$(state "$base"); m=$(manifest "$S")
  echo "Stremio $VER: $st"
  if [ "$st" = built ]; then
    echo "  built from Stremio $(field "$m" base) on $(field "$m" built)"
    [ "$(field "$m" base)" = "$VER" ] || echo "  Stremio was updated since, run install.sh again"
    [ "$(field "$m" recipe)" = "$(recipe)" ] && echo "  patches up to date" || echo "  newer patches available, run install.sh again"
  fi
  exit 0
fi

if [ "$MODE" = uninstall ]; then
  echo "Putting Stremio's own server.js back"
  if [ -f "$AGENT" ] && [ -z "$NO_LAUNCH" ]; then
    launchctl bootout "gui/$(id -u)/nl.polman.stremio-repatch" 2>/dev/null || true
    rm -f "$AGENT"; echo "  watcher removed"
  fi
  base=$(clean_base "$VER") || die "no clean server.js for Stremio $VER, nothing changed"
  if [ "$(sha "$S")" = "$(sha "$base")" ] && [ ! -f "$MAC/cast-remote.js" ]; then echo "  already clean"; exit 0; fi
  stop_app
  cp "$base" "$MAC/.server.js.new" && mv -f "$MAC/.server.js.new" "$S" || die "could not write $S"
  rm -f "$MAC/cast-remote.js"
  echo "  server.js is Stremio $VER's own again"
  sign_app; start_app
  exit 0
fi

echo "Stremio casting patches, for Stremio $VER"
echo
echo "1/4  clean base"
base=$(clean_base "$VER") || die "no clean server.js for Stremio $VER, nothing changed"
echo "  $base"
st=$(state "$base"); m=$(manifest "$S")
case "$st" in
  built)
    if [ "$(field "$m" base_sha256)" = "$(sha "$base")" ] && [ "$(field "$m" recipe)" = "$(recipe)" ] \
       && [ "$(remote | shasum -a 256 | cut -d' ' -f1)" = "$(sha "$MAC/cast-remote.js")" ]; then
      echo "  already installed from this base with these patches, nothing to do"; exit 0
    fi ;;
  unknown)
    [ -n "${STREMIO_FORCE:-}" ] || die "server.js is neither Stremio's own nor built by these patches; STREMIO_FORCE=1 replaces it anyway" ;;
esac
echo "  installed now: $st"

echo
echo "2/4  building"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$base" "$T/server.js"; ln -s "$NODE" "$T/node"
STREMIO_SERVER_JS="$T/server.js" bash "$DIR/stremio-upnp-patch.sh" > "$T/build.log" 2>&1 || { tail -5 "$T/build.log"; die "the patches do not fit Stremio $VER, nothing changed"; }
printf '\n%s{"base":"%s","base_sha256":"%s","recipe":"%s","built":"%s"}\n' "$MARK" "$VER" "$(sha "$base")" "$(recipe)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$T/server.js"
"$NODE" --check "$T/server.js" || die "syntax error in the build, nothing changed"
remote > "$T/cast-remote.js"
echo "  built and syntax checked"

echo
echo "3/4  test server"
if STREMIO_SANDBOX_APPDIR="$MAC" STREMIO_SANDBOX="$T/sandbox" bash "$DIR/test/sandbox.sh" start "$T/server.js" > "$T/sandbox.log" 2>&1 \
   && curl -s -m 5 http://127.0.0.1:11471/casting | grep -q '^\['; then
  echo "  the build starts and answers"
  STREMIO_SANDBOX="$T/sandbox" bash "$DIR/test/sandbox.sh" stop >/dev/null 2>&1
else
  tail -5 "$T/sandbox.log"; STREMIO_SANDBOX="$T/sandbox" bash "$DIR/test/sandbox.sh" stop >/dev/null 2>&1
  die "the build does not start, nothing changed"
fi

echo
echo "4/4  installing"
stop_app
cp "$T/server.js" "$MAC/.server.js.new" && mv -f "$MAC/.server.js.new" "$S" || die "could not write $S"
cp "$T/cast-remote.js" "$MAC/.cast-remote.js.new" && mv -f "$MAC/.cast-remote.js.new" "$MAC/cast-remote.js"
echo "  server.js and cast remote in place"
sign_app; start_app

if [ -z "$NO_LAUNCH" ]; then
  echo
  bash "$DIR/test/verify.sh" >/dev/null 2>&1 && echo "verification passed" || echo "some verification checks did not pass: bash test/verify.sh"
fi

echo
if [ "$WATCH" = "1" ] && [ -z "$NO_LAUNCH" ]; then
  if [ -f "$AGENT" ]; then
    echo "update watcher: installed"
  else
    echo "A Stremio update replaces server.js and removes the patches. A small"
    echo "background job can notice that and build again. Install it with:"
    echo "  sed \"s#__REPO__#$DIR#g\" \"$DIR/launchd/nl.polman.stremio-repatch.plist\" > \"$AGENT\""
    echo "  launchctl bootstrap gui/\$(id -u) \"$AGENT\""
  fi
fi
echo "Done. Undo with: bash install.sh --uninstall"
