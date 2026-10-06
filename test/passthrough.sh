#!/bin/bash
# HEVC without re-encoding to a TV that lists HEVC, H.264 for one that does not.
# Casts an HEVC test clip to two demo TVs on the sandbox and prints the number of
# failing checks (0 = green):
#   - the HEVC TV gets HEVC, copied (-c:v copy), not re-encoded
#   - the TV without HEVC still gets H.264
HERE=$(cd "$(dirname "$0")" && pwd)
C=${TMPDIR:-/tmp}/stremio-cast-e2e; mkdir -p "$C"
FF=/Applications/Stremio.app/Contents/MacOS/ffmpeg; FP=/Applications/Stremio.app/Contents/MacOS/ffprobe
[ -f "$C/hevc.mkv" ] || "$FF" -v error -y -f lavfi -i testsrc2=s=640x360:r=25:d=60 -f lavfi -i sine=frequency=440:duration=60 \
  -c:v libx265 -preset ultrafast -x265-params log-level=error -pix_fmt yuv420p -c:a aac -b:a 128k -shortest "$C/hevc.mkv"
bash "$HERE/sandbox.sh" start >/dev/null 2>&1 || { echo 2; exit 1; }
source "${TMPDIR:-/tmp}/stremio-sandbox/env"
MP=47204; (cd "$C" && exec python3 -m http.server $MP --bind 127.0.0.1 >/dev/null 2>&1) & WEB=$!
sleep 1
fail=0
run() {  # $1 = tag, $2 = extra fake TV flag, $3 = expected codec
  local tag="$1" st="${TMPDIR:-/tmp}/pt-$1.json"; rm -f "$st"
  FAKE_TV_ID="pt-$tag-$$" python3 "$HERE/fake-dlna-tv.py" --state-file "$st" --direct-only --port $((47210 + ${#tag})) $2 >/dev/null 2>&1 &
  local tv=$!
  local id=$(python3 -c "import uuid; print(uuid.uuid5(uuid.NAMESPACE_DNS, 'stremio-fake-tv-pt-$tag-$$'))")
  for _ in $(seq 1 40); do curl -s -m 2 "$STREMIO_URL/casting" | grep -q "$id" && break; sleep 1; done
  local src=$(python3 -c "import urllib.parse; print(urllib.parse.quote('http://127.0.0.1:$MP/hevc.mkv', safe=''))")
  local n0=$(grep -c '^Arguments' "$STREMIO_SANDBOX_LOG")
  curl -s -m 30 -X POST "$STREMIO_URL/casting/$id/player?source=$src&time=5000" >/dev/null
  local uri=""; for _ in $(seq 1 30); do uri=$(python3 -c "import json; print(json.load(open('$st')).get('uri') or '')" 2>/dev/null); [ -n "$uri" ] && break; sleep 1; done
  curl -s -m 8 "$uri" -o "${TMPDIR:-/tmp}/pt-$tag.bin" -r 0-1500000
  local codec=$("$FP" -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "${TMPDIR:-/tmp}/pt-$tag.bin" 2>/dev/null)
  local copied=$(tail -n +$((n0 + 1)) "$STREMIO_SANDBOX_LOG" | grep '^Arguments' | grep -c -- '-c:v copy')
  if [ "$codec" != "$3" ]; then echo "FAIL $tag: got $codec, want $3" >&2; fail=$((fail+1)); fi
  if [ "$3" = "hevc" ] && [ "$copied" -lt 1 ]; then echo "FAIL $tag: re-encoded instead of copied" >&2; fail=$((fail+1)); fi
  curl -s -m 10 -X POST "$STREMIO_URL/casting/$id/player?source=" >/dev/null; kill $tv 2>/dev/null
}
run hevc "--hevc" hevc
run plain "" h264
kill $WEB 2>/dev/null; bash "$HERE/sandbox.sh" stop >/dev/null
echo "$fail"; [ "$fail" -eq 0 ]
