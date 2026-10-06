#!/bin/bash
# Casting to a Chromecast, checked against a demo Chromecast on this Mac.
#
#   bash test/cc-e2e.sh
#
# Starts the sandbox server (port 11471) with a demo Chromecast that only the
# sandbox can see, and the demo receiver itself on 127.0.0.1:8009. No real TV and
# no running Stremio is touched. Prints "ok <tag> ..." or "FAIL <tag> ..." per
# check; the tags are what the roadmap goal counts:
#   kapen    status requests without a cast must not launch the receiver
#   cast     the cast reaches the receiver and it fetches the stream
#   positie  the server reports where the film is
#   vloed    status polling must not flood the receiver
#   subs     a chosen subtitle arrives as an active WebVTT track and is fetched
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(dirname "$HERE")
ST=${TMPDIR:-/tmp}/demo-cc-state.json; rm -f "$ST"
C=${TMPDIR:-/tmp}/stremio-cast-e2e
pkill -f 'test/fake-chromecast.js' 2>/dev/null
# the server works out its own address on the network of the device, so the demo
# needs a real interface address, not loopback
HOST=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
node "$HERE/fake-chromecast.js" --host "$HOST" --state-file "$ST" >/dev/null 2>&1 &
CC=$!
FAKE_CC_HOST=$HOST bash "$HERE/sandbox.sh" start >/dev/null 2>&1 || { echo "FAIL cast sandbox did not start"; kill $CC; exit 1; }
source "${TMPDIR:-/tmp}/stremio-sandbox/env"
[ -f "$C/e2e.mkv" ] || python3 -c "import importlib.util as u,sys; s=u.spec_from_file_location('e','$HERE/cast-e2e.py'); m=u.module_from_spec(s); s.loader.exec_module(m); m.build_media()" >/dev/null
MP=47201; (cd "$C" && exec python3 -m http.server $MP --bind 127.0.0.1 >/dev/null 2>&1) & WEB=$!
sleep 1
ID=demo-chromecast; U="$STREMIO_URL/casting/$ID/player"
cleanup() { curl -s -m 10 -X POST "$U?source=" >/dev/null 2>&1; kill $CC $WEB 2>/dev/null; bash "$HERE/sandbox.sh" stop >/dev/null; }
trap cleanup EXIT
j() { python3 -c "import json,sys; d=json.load(open('$ST')); print($1)"; }

for _ in $(seq 1 20); do curl -s -m 2 "$STREMIO_URL/casting" | grep -q "$ID" && break; sleep 0.5; done

# kapen: five status requests with nothing cast
for _ in 1 2 3 4 5; do curl -s -m 8 "$U" >/dev/null; done; sleep 1
L0=$(j 'd["launches"]')
[ "$L0" -eq 0 ] && echo "ok kapen no receiver launched by status requests" || echo "FAIL kapen $L0 launches from status requests"

# cast at 60 s
SRC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('http://127.0.0.1:$MP/e2e.mkv', safe=''))")
curl -s -m 30 -X POST "$U?source=$SRC&time=60000" >/dev/null
for _ in $(seq 1 30); do [ "$(j 'len(d["loads"])')" -ge 1 ] && [ "$(j 'd["loads"][0]["bytes"]')" -gt 100000 ] && break; sleep 1; done
NL=$(j 'len(d["loads"])'); NB=$(j 'd["loads"][0]["bytes"] if d["loads"] else 0')
[ "$NL" -ge 1 ] && [ "$NB" -gt 100000 ] && echo "ok cast LOAD received, $NB bytes fetched" || echo "FAIL cast loads=$NL bytes=$NB"

# positie: what the server reports versus what the receiver plays
sleep 6
REP=$(curl -s -m 8 "$U" | python3 -c 'import json,sys; print(int(float(json.load(sys.stdin).get("time") or 0)))')
TRUE=$(j 'int((d["media"]["base"] + 0) * 1000) if d["media"] else 0')
python3 - "$REP" "$TRUE" <<'PY'
import sys; rep, base = int(sys.argv[1]), int(sys.argv[2])
ok = rep >= base and rep <= base + 60000
print(("ok positie" if ok else "FAIL positie") + " server says %ds, receiver started at %ds" % (rep / 1000, base / 1000))
PY

# vloed: 30 s of polling at the pace of the player and the remote together
R0=$(j 'len(d["requests"])')
END=$((SECONDS + 30)); PIDS=""; while [ $SECONDS -lt $END ]; do curl -s -m 8 "$U" >/dev/null & PIDS="$PIDS $!"; sleep 0.6; done; wait $PIDS
R1=$(j 'len(d["requests"])'); PER=$(( (R1 - R0) * 2 ))
[ "$PER" -lt 30 ] && echo "ok vloed $PER cast requests per minute" || echo "FAIL vloed $PER cast requests per minute"

# subs: choose a subtitle while casting
SUB=$(python3 -c "import urllib.parse; print(urllib.parse.quote('http://127.0.0.1:$MP/e2e.srt', safe=''))")
N0=$(j 'len(d["loads"])')
curl -s -m 30 -X POST "$U?subtitlesSrc=$SUB" >/dev/null
for _ in $(seq 1 20); do [ "$(j 'len(d["loads"])')" -gt "$N0" ] && [ -n "$(j 'd["loads"][-1]["subsHead"] or ""')" ] && break; sleep 1; done
python3 - "$ST" "$N0" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); n0 = int(sys.argv[2])
new = d["loads"][n0:] if len(d["loads"]) > n0 else []
last = new[-1] if new else {}
ok = bool(new) and "/subtitles.vtt" in (last.get("track") or "") and (last.get("subsHead") or "").startswith("WEBVTT")
print(("ok subs" if ok else "FAIL subs") + " track=%s head=%r" % ((last.get("track") or "-")[-40:], (last.get("subsHead") or "")[:12]))
PY
