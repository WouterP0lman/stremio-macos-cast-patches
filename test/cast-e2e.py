#!/usr/bin/env python3
"""Cast a real video to a fake TV and check what actually arrives.

    python3 test/cast-e2e.py

Everything the earlier tests check in isolation, checked together instead: the
server picks up the device, starts ffmpeg at the requested point, burns the
subtitle into the picture, and reports back where the film is. No TV, no
Chromecast and no torrent needed.

It runs twice, because renderers disagree about what "position" means. An LG
answers GetPositionInfo with the point in the film; other renderers answer with
how long they have been playing. Both runs must end up at the same place.

Needs Stremio running with the patched server. Roughly a minute.
"""
import http.server, json, os, socket, socketserver, subprocess, sys, tempfile
import threading, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
APP = "/Applications/Stremio.app/Contents/MacOS"
FFMPEG = os.environ.get("FFMPEG", os.path.join(APP, "ffmpeg"))
FFPROBE = os.environ.get("FFPROBE", os.path.join(APP, "ffprobe"))
SERVER = os.environ.get("STREMIO_URL", "http://127.0.0.1:11470")
CACHE = os.path.join(tempfile.gettempdir(), "stremio-cast-e2e")
SEEK_S = 205                      # past the 30s mark where the server may learn the renderer
PASS, FAIL = [], []


def ok(m):  PASS.append(m); print("  ok    " + m)
def bad(m): FAIL.append(m); print("  FAIL  " + m)


def build_media():
    """A black film with a subtitle line every five seconds naming the time it
    belongs to. Black on purpose: any non-black pixel in the output can only come
    from a burned-in subtitle. A line every five seconds means one is on screen
    wherever the film resumes."""
    os.makedirs(CACHE, exist_ok=True)
    mkv, srt = os.path.join(CACHE, "e2e.mkv"), os.path.join(CACHE, "e2e.srt")
    if not os.path.exists(srt):
        blocks = []
        for n, t in enumerate(range(0, 300, 5), 1):
            blocks.append("%d\n00:%02d:%02d,000 --> 00:%02d:%02d,800\npositie %02d:%02d\n"
                          % (n, t // 60, t % 60, (t + 4) // 60, (t + 4) % 60, t // 60, t % 60))
        open(srt, "w", encoding="utf-8").write("\n".join(blocks))
    if not os.path.exists(mkv):
        print("  (eenmalig testbeeld maken)")
        subprocess.run([FFMPEG, "-y", "-v", "error",
                        "-f", "lavfi", "-i", "color=c=black:s=640x360:r=10:d=300",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=300",
                        "-af", "volume=-25dB",
                        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                        "-g", "20", "-c:a", "libvorbis", "-shortest", mkv], check=True)
    return mkv, srt


class Range(http.server.SimpleHTTPRequestHandler):
    """Serves the media with byte ranges, which the transcoder needs to seek."""
    def log_message(self, *a): pass

    def do_GET(self):
        path = os.path.join(CACHE, os.path.basename(urllib.parse.urlparse(self.path).path))
        if not os.path.isfile(path):
            self.send_error(404); return
        size = os.path.getsize(path)
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        if rng and rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-")
            start = int(a) if a else 0
            end = int(b) if b else size - 1
        ctype = "application/x-subrip" if path.endswith(".srt") else "video/x-matroska"
        self.send_response(206 if rng else 200)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if rng:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = f.read(min(65536, left))
                if not chunk: break
                try: self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError): return
                left -= len(chunk)


def free_port():
    s = socket.socket(); s.bind(("", 0)); p = s.getsockname()[1]; s.close(); return p


def get(path, timeout=10):
    with urllib.request.urlopen(SERVER + path, timeout=timeout) as r:
        return json.loads(r.read().decode())


def post(path, timeout=30):
    req = urllib.request.Request(SERVER + path, data=b"", method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode()


def device_id(tag):
    """The fake TV derives its UDN from this tag, so the id is known up front.
    Matching on it matters: Stremio keeps devices in its list after they are gone,
    so a run that matched on the name would cast at a TV that stopped existing."""
    import uuid
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, "stremio-fake-tv-" + tag))


def wait_device(want, deadline=40):
    end = time.time() + deadline
    while time.time() < end:
        try:
            if any(d.get("id") == want for d in get("/casting")):
                return want
        except Exception:
            pass
        time.sleep(1)
    return None


def probe(path):
    out = subprocess.run([FFPROBE, "-v", "error", "-of", "json",
                          "-show_entries", "format=start_time:stream=codec_type,codec_name",
                          path], capture_output=True, text=True).stdout
    try: return json.loads(out)
    except Exception: return {}


def brightest(path, frame=20):
    """Decode one frame as grayscale and return its brightest pixel. The test film
    is black, so anything bright can only be a subtitle drawn over it."""
    out = subprocess.run([FFMPEG, "-v", "error", "-i", path,
                          "-vf", "select=gte(n\\,%d)" % frame,
                          "-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "-"],
                         capture_output=True).stdout
    return max(out) if out else -1


def read_state(path, want_events=1, deadline=25):
    end = time.time() + deadline
    last = None
    while time.time() < end:
        try:
            st = json.load(open(path))
            last = st
            if st.get("transport") == "PLAYING" and len(st.get("events") or []) >= want_events:
                return st
        except Exception:
            pass
        time.sleep(0.5)
    return last


def grab(url, mode, tag, cap=3_000_000):
    """Pull a few seconds off the stream the TV was handed."""
    path = os.path.join(CACHE, "grab-%s-%s.mkv" % (mode, tag))
    got = 0
    with open(path, "wb") as f:
        try:
            with urllib.request.urlopen(url, timeout=45) as r:
                while got < cap:
                    c = r.read(65536)
                    if not c: break
                    f.write(c); got += len(c)
        except Exception:
            pass
    return path if got > 100_000 else None


def run(mode, media_port):
    relative = mode == "relative"
    print("\n  %s renderer" % ("relatieve" if relative else "absolute"))
    tag = "e2e-%s-%d" % (mode, os.getpid())
    state_file = os.path.join(CACHE, "tv-%s.json" % mode)
    if os.path.exists(state_file): os.remove(state_file)
    env = dict(os.environ, PYTHONUNBUFFERED="1", FAKE_TV_ID=tag)
    args = [sys.executable, os.path.join(HERE, "fake-dlna-tv.py"), "--state-file", state_file]
    if relative: args.append("--relative")
    tv = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    dev = None
    try:
        dev = wait_device(device_id(tag))
        if not dev:
            bad("%s: the server never discovered the fake TV" % mode); return
        ok("%s: device discovered" % mode)

        src = "http://127.0.0.1:%d/e2e.mkv" % media_port
        sub = "http://127.0.0.1:%d/e2e.srt" % media_port

        post("/casting/%s/player?%s" % (dev, urllib.parse.urlencode(
            {"source": src, "time": SEEK_S * 1000})))
        st = read_state(state_file, 1)
        if not st or not st.get("uri"):
            bad("%s: the TV was never told to play" % mode); return
        told = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(st["uri"]).query))
        if abs(float(told.get("time") or -1) - SEEK_S) < 1.5:
            ok("%s: cast starts at %ds, as asked" % (mode, SEEK_S))
        else:
            bad("%s: cast starts at %ss instead of %ds" % (mode, told.get("time"), SEEK_S))

        plain = grab(st["uri"], mode, "plain")
        if not plain:
            bad("%s: the stream the TV was handed carries no data" % mode)
        else:
            start = float(probe(plain).get("format", {}).get("start_time") or -1)
            if abs(start - SEEK_S) < 3:
                ok("%s: the stream itself starts at %.0fs, so the TV shows the right point"
                   % (mode, start))
            else:
                bad("%s: the stream starts at %.1fs instead of %ds" % (mode, start, SEEK_S))
            if brightest(plain) < 60:
                ok("%s: nothing is drawn over the picture yet" % mode)
            else:
                bad("%s: something is drawn before any subtitle was asked for" % mode)

        # The interface sends the subtitle in a second call, so the server has to
        # keep its place across the restart that burning one in costs.
        time.sleep(6)
        post("/casting/%s/player?subtitlesSrc=%s" % (dev, urllib.parse.quote(sub, safe="")))
        st2 = read_state(state_file, 2)
        ev = [e for e in (st2 or {}).get("events") or [] if e[0] == "SetAVTransportURI"]
        if len(ev) < 2:
            bad("%s: adding a subtitle never reached the TV" % mode); return
        told2 = ev[-1][1]
        if told2.get("subtitles"):
            ok("%s: the subtitle travels with the stream" % mode)
        else:
            bad("%s: no subtitle in the second cast URL" % mode)
        again = float(told2.get("time") or -1)
        if SEEK_S - 2 <= again <= SEEK_S + 60:
            ok("%s: it resumes at %.0fs, where the film was" % (mode, again))
        else:
            bad("%s: it resumes at %.0fs instead of near %ds" % (mode, again, SEEK_S))

        withsub = grab(st2["uri"], mode, "sub")
        if not withsub:
            bad("%s: the subtitled stream carries no data" % mode)
        else:
            lum = brightest(withsub)
            if lum > 60:
                ok("%s: the subtitle is burned into the picture (peak %d on black)" % (mode, lum))
            else:
                bad("%s: the subtitle never reaches the picture (peak %d)" % (mode, lum))

        time.sleep(6)
        try:
            status = get("/casting/%s/player" % dev)
        except Exception as e:
            bad("%s: the server stopped answering for its own status (%s)" % (mode, e)); return
        if not isinstance(status, dict):
            bad("%s: status came back as %r" % (mode, status)); return
        rep = int(status.get("time") or 0)
        low, high = SEEK_S * 1000 - 2000, SEEK_S * 1000 + 90000
        if low <= rep <= high:
            ok("%s: Stremio reports %.0fs, in step with the TV" % (mode, rep / 1000.0))
        elif rep < low:
            bad("%s: Stremio reports %.0fs, it lost the starting point" % (mode, rep / 1000.0))
        else:
            bad("%s: Stremio reports %.0fs, far past the truth" % (mode, rep / 1000.0))
    finally:
        try:
            if dev: post("/casting/%s/player?stop=1" % dev, timeout=10)
        except Exception: pass
        tv.terminate()
        try: tv.wait(timeout=5)
        except Exception: tv.kill()
        time.sleep(2)


def main():
    for exe in (FFMPEG, FFPROBE):
        if not os.path.exists(exe):
            print("  ffmpeg not found at " + exe); return 1
    try: get("/settings", timeout=4)
    except Exception:
        print("  Stremio's server is not running on " + SERVER); return 1
    build_media()
    port = free_port()
    httpd = socketserver.ThreadingTCPServer(("127.0.0.1", port), Range)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        for mode in ("absolute", "relative"):
            run(mode, port)
    finally:
        httpd.shutdown()
    print("\n  %d ok, %d mislukt" % (len(PASS), len(FAIL)))
    print("  PASS: casten werkt van begin tot eind" if not FAIL else "  FAIL: zie hierboven")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
