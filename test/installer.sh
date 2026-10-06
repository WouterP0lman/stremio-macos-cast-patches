#!/bin/bash
# The installer, on a copy of Stremio.app from the official 5.1.28 DMG. The app in
# /Applications is never touched. Prints the number of failing checks (0 = green):
#   fresh     a clean app gets a build with a manifest, the remote, a valid signature
#   again     a second run with nothing new changes nothing
#   status    --status recognises the build and says it is current
#   update    after a simulated Stremio update (5.1.27 files) it builds from that base
#   unknown   a server.js changed by someone else is left alone
#   undo      --uninstall puts back Stremio's own server.js, byte for byte
#   real      the installed Stremio is the same before and after
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(dirname "$HERE")
CACHE=${STREMIO_CAST_CACHE:-$HOME/Library/Caches/stremio-cast-patches}
REAL=/Applications/Stremio.app/Contents/MacOS/server.js
real0=$(shasum -a 256 "$REAL" | cut -d' ' -f1)
fail=0; ok() { echo "ok   $1" >&2; }; bad() { echo "FAIL $1" >&2; fail=$((fail+1)); }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# a pristine 5.1.28 bundle, taken from the DMG once
SRC=$CACHE/testapp-5.1.28/Stremio.app
if [ ! -d "$SRC" ]; then
  mp=$(mktemp -d); hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mp" "$CACHE/Stremio_arm64-5.1.28.dmg" >/dev/null || { echo 7; exit 1; }
  mkdir -p "$(dirname "$SRC")"; ditto "$mp/Stremio.app" "$SRC"; hdiutil detach "$mp" >/dev/null; rmdir "$mp"
fi
W=$(mktemp -d); APP=$W/Stremio.app; ditto "$SRC" "$APP"
MAC=$APP/Contents/MacOS
run() { STREMIO_APP="$APP" STREMIO_NO_LAUNCH=1 STREMIO_CAST_CACHE="$CACHE" bash "$REPO/install.sh" --no-watch "$@"; }
last() { tail -1 "$MAC/server.js"; }

# fresh
out=$(run 2>&1); rc=$?
if [ $rc -eq 0 ] && last | grep -q '"base":"5.1.28"' && [ -s "$MAC/cast-remote.js" ] \
   && codesign --verify --deep --strict "$APP" 2>/dev/null && grep -q timer36 "$MAC/server.js"; then ok "fresh install builds 5.1.28 with manifest and signature"
else bad "fresh install (rc $rc): $(echo "$out" | tail -3 | tr '\n' ' ')"; fi

# again
m0=$(stat -f %m "$MAC/server.js"); sleep 1
out=$(run 2>&1)
[ "$(stat -f %m "$MAC/server.js")" = "$m0" ] && echo "$out" | grep -q 'nothing to do' && ok "second run changes nothing" || bad "second run touched the app"

# status
out=$(run --status 2>&1)
echo "$out" | grep -q 'Stremio 5.1.28: built' && echo "$out" | grep -q 'patches up to date' && ok "status sees the current build" || bad "status: $out"

# update: Stremio 5.1.27 lands on top
cp "$CACHE/clean-5.1.27/server.js" "$MAC/server.js"; rm -f "$MAC/cast-remote.js"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 5.1.27' "$APP/Contents/Info.plist"
out=$(run 2>&1); rc=$?
[ $rc -eq 0 ] && last | grep -q '"base":"5.1.27"' && echo "$out" | grep -q 'installed now: clean' && ok "after an update it builds from the new base" || bad "update (rc $rc): $(echo "$out" | tail -3 | tr '\n' ' ')"

# unknown
cp "$CACHE/clean-5.1.27/server.js" "$MAC/server.js"; echo "// changed by hand" >> "$MAC/server.js"; u0=$(sha "$MAC/server.js")
out=$(run 2>&1); rc=$?
[ $rc -ne 0 ] && [ "$(sha "$MAC/server.js")" = "$u0" ] && ok "a server.js changed by someone else is left alone" || bad "unknown file was replaced (rc $rc)"

# undo
run 2>/dev/null >/dev/null; STREMIO_FORCE=1 run >/dev/null 2>&1
out=$(run --uninstall 2>&1)
[ "$(sha "$MAC/server.js")" = "$(sha "$CACHE/clean-5.1.27/server.js")" ] && [ ! -e "$MAC/cast-remote.js" ] \
  && codesign --verify --deep --strict "$APP" 2>/dev/null && ok "uninstall restores Stremio's own server.js" || bad "uninstall: $(echo "$out" | tail -2 | tr '\n' ' ')"

# real
[ "$(sha "$REAL")" = "$real0" ] && ok "the installed Stremio was not touched" || bad "the installed Stremio changed"

rm -rf "$W"
echo "$fail"; [ "$fail" -eq 0 ]
