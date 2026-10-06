#!/bin/bash
# Subtitles as a separate file for a TV that asks for one (Samsung's getcaptionInfo.sec),
# with the castSubtitleFile setting on. Plays the Samsung's part against the sandbox
# and prints the number of failing checks (0 = green):
#   - the stream answers with a CaptionInfo.sec header pointing at the subtitle
#   - that address serves the subtitle text
#   - the picture is not re-encoded to burn it in (-c:v copy, no subtitles filter)
#   - without the request header the subtitle is still burned in (other TVs unchanged)
HERE=$(cd "$(dirname "$0")" && pwd); C=${TMPDIR:-/tmp}/stremio-cast-e2e
bash "$HERE/sandbox.sh" start >/dev/null 2>&1 || { echo 4; exit 1; }
source "${TMPDIR:-/tmp}/stremio-sandbox/env"
python3 - "$STREMIO_APP_PATH/server-settings.json" <<'PY'
import json, sys, os
p = sys.argv[1]; d = json.load(open(p)) if os.path.exists(p) else {}
d["castSubtitleFile"] = True; json.dump(d, open(p, "w"))
PY
MP=47205; (cd "$C" && exec python3 -m http.server $MP --bind 127.0.0.1 >/dev/null 2>&1) & WEB=$!
sleep 1
q() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }
U="$STREMIO_URL/casting/transcode.mp4?video=$(q http://127.0.0.1:$MP/e2e.mkv)&time=60&ts=1&subtitles=$(q http://127.0.0.1:$MP/e2e.srt)"
fail=0; H=${TMPDIR:-/tmp}/sc-h.txt
n0=$(grep -c '^Arguments' "$STREMIO_SANDBOX_LOG")
curl -s -m 6 -D "$H" -H 'getcaptionInfo.sec: 1' "$U" -o /dev/null -r 0-200000
cap=$(grep -i '^captioninfo.sec:' "$H" | cut -d' ' -f2- | tr -d '\r')
[ -n "$cap" ] || { echo "FAIL no CaptionInfo.sec header" >&2; fail=$((fail+1)); }
curl -s -m 6 "$cap" | grep -q 'positie' || { echo "FAIL the subtitle address does not serve the subtitle" >&2; fail=$((fail+1)); }
a=$(tail -n +$((n0 + 1)) "$STREMIO_SANDBOX_LOG" | grep '^Arguments' | tail -1)
echo "$a" | grep -q -- '-c:v copy' && ! echo "$a" | grep -q 'subtitles=' || { echo "FAIL the picture was re-encoded for the subtitle" >&2; fail=$((fail+1)); }
sleep 10; n1=$(grep -c '^Arguments' "$STREMIO_SANDBOX_LOG")
curl -s -m 6 "$U&x=2" -o /dev/null -r 0-200000
b=$(tail -n +$((n1 + 1)) "$STREMIO_SANDBOX_LOG" | grep '^Arguments' | tail -1)
echo "$b" | grep -q 'subtitles=' || { echo "FAIL without the header the subtitle is no longer burned in" >&2; fail=$((fail+1)); }
kill $WEB 2>/dev/null; bash "$HERE/sandbox.sh" stop >/dev/null
echo "$fail"; [ "$fail" -eq 0 ]
