#!/bin/bash
# The stream probe must not hang forever on a source that stops sending. Serves a
# file that sends 200 KB and then stalls, the way a starving torrent does, asks
# the sandbox for a cast stream of it (which first probes the file with ffmpeg),
# hangs up, and counts the ffmpeg processes still alive 40 seconds later.
# Green = 0. Needs: bash test/sandbox.sh start
source "${TMPDIR}stremio-sandbox/env"
C=${TMPDIR}stremio-cast-e2e; PORT=47199
python3 - "$C/e2e.mkv" $PORT <<'PY' &
import http.server, sys, time, threading
path, port = sys.argv[1], int(sys.argv[2])
data = open(path, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_HEAD(self):
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.send_header("Accept-Ranges", "bytes"); self.end_headers()
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers()
        try: self.wfile.write(data[:200_000]); self.wfile.flush(); time.sleep(120)
        except Exception: pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
threading.Timer(60, s.shutdown).start(); s.serve_forever()
PY
SRV=$!; sleep 1
V=$(python3 -c "import urllib.parse; print(urllib.parse.quote('http://127.0.0.1:$PORT/stall.mkv', safe=''))")
curl -s -m 4 "$STREMIO_URL/casting/transcode.mp4?video=$V&time=0" -o /dev/null
sleep 40
n=$(pgrep -P "$STREMIO_PID" ffmpeg | wc -l | tr -d ' ')
pkill -9 -P "$STREMIO_PID" ffmpeg 2>/dev/null; kill $SRV 2>/dev/null
echo "$n"; [ "$n" -eq 0 ]
