#!/bin/bash
# One transcode per cast. A Samsung asks HEAD, GET, HEAD, GET for one cast; each GET
# used to start its own ffmpeg. Plays that pattern against the sandbox and prints the
# number of failing checks (0 = green):
#   - exactly one ffmpeg transcode started for the four requests
#   - the second GET gets the stream from the start (same first bytes as the first)
#   - the ffmpeg is gone 25 s after the last viewer hangs up
HERE=$(cd "$(dirname "$0")" && pwd)
bash "$HERE/sandbox.sh" start >/dev/null 2>&1 || { echo 3; exit 1; }
source "${TMPDIR:-/tmp}/stremio-sandbox/env"
C=${TMPDIR:-/tmp}/stremio-cast-e2e; MP=47203
(cd "$C" && exec python3 -m http.server $MP --bind 127.0.0.1 >/dev/null 2>&1) & WEB=$!
sleep 1
V=$(python3 -c "import urllib.parse; print(urllib.parse.quote('http://127.0.0.1:$MP/e2e.mkv', safe=''))")
U="$STREMIO_URL/casting/transcode.mp4?video=$V&time=60&ts=1"
N0=$(grep -c '^Arguments' "$STREMIO_SANDBOX_LOG")
O=${TMPDIR:-/tmp}/one-ffmpeg; mkdir -p "$O"
curl -s -m 10 -I "$U" >/dev/null
curl -s -m 4 "$U" -o "$O/a.ts" -r 0-300000
curl -s -m 10 -I "$U" >/dev/null
curl -s -m 4 "$U" -o "$O/b.ts" -r 0-300000
N1=$(grep -c '^Arguments' "$STREMIO_SANDBOX_LOG")
fail=0
[ $((N1 - N0)) -eq 1 ] || { echo "FAIL $((N1 - N0)) transcodes for one cast" >&2; fail=$((fail+1)); }
cmp -s -n 100000 "$O/a.ts" "$O/b.ts" || { echo "FAIL second GET does not start at the beginning" >&2; fail=$((fail+1)); }
sleep 25
left=$(pgrep -P "$STREMIO_PID" ffmpeg | wc -l | tr -d ' ')
[ "$left" -eq 0 ] || { echo "FAIL $left ffmpeg still running after the viewers left" >&2; fail=$((fail+1)); }
kill $WEB 2>/dev/null; bash "$HERE/sandbox.sh" stop >/dev/null
echo "$fail"; [ "$fail" -eq 0 ]
