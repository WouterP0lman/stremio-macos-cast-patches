#!/bin/bash
# A second Stremio streaming server next to the real one, for testing patches
# without touching the app you are watching with.
#
#   bash test/sandbox.sh start           copy the app's server.js, apply the patch script to the copy, start it
#   bash test/sandbox.sh start --as-is   start the app's server.js exactly as it is now (the "before" picture)
#   bash test/sandbox.sh start FILE      start FILE instead
#   bash test/sandbox.sh stop
#   bash test/sandbox.sh status
#
# The copy runs on port 11471 with its own settings, cache and cast formats, so
# nothing it learns ends up in the real app. The environment a test needs is
# printed on start and kept in $SB/env:
#   STREMIO_URL       where the server answers
#   STREMIO_PID       its process, so the fake TV announces itself to this server only
#   STREMIO_APP_PATH  its settings folder (cast-formats.json lives there)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(dirname "$HERE")
APPDIR=/Applications/Stremio.app/Contents/MacOS
NODE=$APPDIR/node
SB=${STREMIO_SANDBOX:-${TMPDIR:-/tmp}/stremio-sandbox}
PORT=${STREMIO_SANDBOX_PORT:-11471}

running() { [ -f "$SB/pid" ] && kill -0 "$(cat "$SB/pid")" 2>/dev/null; }

stop() {
  if running; then
    pid=$(cat "$SB/pid")
    # ffmpeg is started detached, so it would outlive the server; stop its children first
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$pid" 2>/dev/null || true
    echo "sandbox stopped"
  else
    echo "sandbox not running"
  fi
  rm -f "$SB/pid"
}

case "${1:-status}" in
  stop) stop ;;
  status)
    if running; then echo "running, pid $(cat "$SB/pid")"; cat "$SB/env"; else echo "not running"; fi ;;
  start)
    stop >/dev/null
    mkdir -p "$SB/appdata"
    src=$APPDIR/server.js; patch=1
    [ "${2:-}" = "--as-is" ] && patch=
    [ -n "${2:-}" ] && [ "${2:-}" != "--as-is" ] && src=$2
    cp "$src" "$SB/server.js"
    ln -sf "$NODE" "$SB/node"   # so the patch script checks syntax with the node Stremio ships
    if [ -n "$patch" ]; then
      STREMIO_SERVER_JS="$SB/server.js" bash "$REPO/stremio-upnp-patch.sh" | grep -v '^patch .*: present' || true
    fi
    # the real app holds 11470; give the copy a fixed port of its own
    python3 - "$SB/server.js" "$PORT" <<'PY'
import sys
p, port = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
old = "enginefs._server = http.createServer(app)), port = 11470;"
if s.count(old) != 1: raise SystemExit("sandbox: port anchor not found")
open(p, "w", encoding="utf-8").write(s.replace(old, "enginefs._server = http.createServer(app)), port = %s;" % port))
PY
    cp "$REPO/webui/cast-remote.js" "$SB/cast-remote.js"
    : > "$SB/server.log"
    # exec, so the pid is node's own and no shell in between keeps our output open
    ( cd "$SB" && APP_PATH="$SB/appdata" NO_HTTPS_SERVER=1 exec nohup "$NODE" "$SB/server.js" >>"$SB/server.log" 2>&1 </dev/null ) &
    echo $! > "$SB/pid"
    for _ in $(seq 1 60); do
      curl -s -m 1 "http://127.0.0.1:$PORT/settings" >/dev/null 2>&1 && break
      running || { echo "sandbox died on start:"; tail -20 "$SB/server.log"; exit 1; }
      sleep 0.5
    done
    curl -s -m 2 "http://127.0.0.1:$PORT/settings" >/dev/null || { echo "sandbox did not answer on $PORT"; exit 1; }
    cat > "$SB/env" <<EOF
export STREMIO_URL=http://127.0.0.1:$PORT
export STREMIO_PID=$(cat "$SB/pid")
export STREMIO_APP_PATH=$SB/appdata
export STREMIO_SANDBOX_LOG=$SB/server.log
EOF
    echo "sandbox running on http://127.0.0.1:$PORT (pid $(cat "$SB/pid")), log $SB/server.log"
    echo "use it with:  source $SB/env"
    ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
