#!/usr/bin/env python3
"""Find out what a DLNA TV actually accepts, by trying it.

    python3 test/renderer-probe.py http://<tv-ip>:<port>/<description>.xml

A renderer's GetProtocolInfo list says which formats it knows, not how it wants
a live stream served. That second part is where casting breaks: a TV that
believes the stream can be seeked asks for byte ranges the transcoder cannot
give, and stops with ERROR_OCCURRED. This tool serves the same short test clip
in a few ways, each time exactly as a live transcode would, tells the TV to play
it, and records what the TV asked for and whether it played.

Each attempt shows a test pattern on the TV for about fifteen seconds.
"""
import http.server, json, os, re, socket, socketserver, subprocess, sys, tempfile
import threading, time, urllib.parse, urllib.request, html
import xml.etree.ElementTree as ET

APP = "/Applications/Stremio.app/Contents/MacOS"
FFMPEG = os.environ.get("FFMPEG", os.path.join(APP, "ffmpeg"))
CACHE = os.path.join(tempfile.gettempdir(), "stremio-renderer-probe")
AVT = "urn:schemas-upnp-org:service:AVTransport:1"

STREMIO_FEATURES = "DLNA.ORG_OP=01;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=01300000000000000000000000000000"
LIVE_FEATURES = "DLNA.ORG_OP=00;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=01300000000000000000000000000000"

# name, container for ffmpeg, mime, contentFeatures, what it tests
VARIANTS = [
    ("stremio-mkv", "matroska", "video/x-mkv", STREMIO_FEATURES, "what Stremio sends today"),
    ("mkv-live",    "matroska", "video/x-mkv", LIVE_FEATURES,    "same, but honest that it cannot seek"),
    ("ts-live",     "mpegts",   "video/mpeg",  LIVE_FEATURES,    "MPEG-TS, the broadcast format every TV plays"),
    ("mp4-live",    "mp4",      "video/mp4",   LIVE_FEATURES,    "fragmented MP4"),
]

requests_seen = []
lock = threading.Lock()


def lan_ip_towards(host):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((host, 9)); ip = s.getsockname()[0]; s.close(); return ip


def build_clip():
    os.makedirs(CACHE, exist_ok=True)
    clip = os.path.join(CACHE, "pattern.mkv")
    if not os.path.exists(clip):
        subprocess.run([FFMPEG, "-y", "-v", "error",
                        "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=25:duration=300",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=300", "-af", "volume=-30dB",
                        "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-g", "50",
                        "-c:a", "aac", "-shortest", clip], check=True)
    return clip


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def _variant(self):
        name = os.path.splitext(os.path.basename(urllib.parse.urlparse(self.path).path))[0]
        return next((v for v in VARIANTS if v[0] == name), None)

    def _record(self):
        with lock:
            requests_seen.append({
                "t": time.time(), "method": self.command, "path": self.path,
                "range": self.headers.get("Range"),
                "ua": self.headers.get("User-Agent"),
                "features": self.headers.get("getcontentFeatures.dlna.org"),
                "mediainfo": self.headers.get("getMediaInfo.sec"),
                "caption": self.headers.get("getCaptionInfo.sec"),
                "timeseek": self.headers.get("TimeSeekRange.dlna.org"),
            })

    def _headers(self, v):
        self.send_response(200)
        self.send_header("Content-Type", v[2])
        self.send_header("Accept-Ranges", "none")
        self.send_header("Connection", "close")
        self.send_header("transferMode.dlna.org", "Streaming")
        self.send_header("contentFeatures.dlna.org", v[3])

    def do_HEAD(self):
        self._record(); v = self._variant()
        if not v: self.send_error(404); return
        self._headers(v); self.end_headers()

    def do_GET(self):
        self._record(); v = self._variant()
        if not v: self.send_error(404); return
        self._headers(v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        args = [FFMPEG, "-v", "error", "-i", self.server.clip, "-map", "0:v:0", "-map", "0:a:0",
                "-c:v", "copy", "-c:a", "copy"]
        if v[1] == "mp4":
            args += ["-movflags", "frag_keyframe+empty_moov+default_base_moof"]
        if v[1] == "mpegts":
            args += ["-bsf:v", "h264_mp4toannexb"]
        args += ["-f", v[1], "pipe:1"]
        p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            while True:
                chunk = p.stdout.read(65536)
                if not chunk: break
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            p.kill()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def find_avtransport(desc_url):
    xml = urllib.request.urlopen(desc_url, timeout=10).read().decode("utf-8", "replace")
    root = ET.fromstring(xml)
    ns = "{urn:schemas-upnp-org:device-1-0}"
    base = urllib.parse.urlparse(desc_url)
    name = (root.find(".//%sfriendlyName" % ns).text or "").strip()
    for s in root.iter(ns + "service"):
        if "AVTransport" in s.find(ns + "serviceType").text:
            ctl = s.find(ns + "controlURL").text
            return name, urllib.parse.urljoin("%s://%s/" % (base.scheme, base.netloc), ctl)
    raise SystemExit("no AVTransport service in " + desc_url)


def soap(ctl, action, inner=""):
    body = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            f'<u:{action} xmlns:u="{AVT}"><InstanceID>0</InstanceID>{inner}</u:{action}>'
            '</s:Body></s:Envelope>')
    req = urllib.request.Request(ctl, data=body.encode(), headers={
        "Content-Type": 'text/xml; charset="utf-8"', "SOAPACTION": f'"{AVT}#{action}"'})
    try:
        return 200, urllib.request.urlopen(req, timeout=10).read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, str(e)


def didl(url, mime):
    # the same shape Stremio's buildMetadata produces
    return ('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" '
            'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:sec="http://www.sec.co.kr/">'
            '<item id="0" parentID="-1" restricted="false">'
            '<upnp:class>object.item.videoItem.movie</upnp:class>'
            '<dc:title>Stremio test</dc:title><dc:creator>Stremio</dc:creator>'
            f'<res protocolInfo="http-get:*:{mime}:*">{html.escape(url)}</res>'
            '</item></DIDL-Lite>')


def tag(xml, name):
    m = re.search(rf"<{name}>(.*?)</{name}>", xml or "", re.S)
    return m.group(1) if m else ""


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    only = sys.argv[2].split(",") if len(sys.argv) > 2 else None
    tv_name, ctl = find_avtransport(sys.argv[1])
    host = urllib.parse.urlparse(sys.argv[1]).hostname
    ip = lan_ip_towards(host)
    httpd = Server(("0.0.0.0", 0), Handler)
    httpd.clip = build_clip()
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print("  %s, via %s" % (tv_name, ctl))
    results = []
    for v in VARIANTS:
        if only and v[0] not in only: continue
        url = "http://%s:%d/%s.%s" % (ip, port, v[0], {"matroska": "mkv", "mpegts": "ts", "mp4": "mp4"}[v[1]])
        soap(ctl, "Stop")
        time.sleep(1.5)
        mark = len(requests_seen)
        code, out = soap(ctl, "SetAVTransportURI",
                         "<CurrentURI>%s</CurrentURI><CurrentURIMetaData>%s</CurrentURIMetaData>"
                         % (html.escape(url), html.escape(didl(url, v[2]))))
        err = tag(out, "errorDescription") or tag(out, "errorCode")
        if code != 200:
            results.append((v, "rejected: %s" % (err or code), [])); print("  %-12s rejected: %s" % (v[0], err or code)); continue
        soap(ctl, "Play", "<Speed>1</Speed>")
        state, pos, t0 = "", "", time.time()
        while time.time() - t0 < 15:
            time.sleep(2)
            _, ti = soap(ctl, "GetTransportInfo")
            _, pi = soap(ctl, "GetPositionInfo")
            state = tag(ti, "CurrentTransportState") + "/" + tag(ti, "CurrentTransportStatus")
            pos = tag(pi, "RelTime")
            if "ERROR" in state or (state.startswith("PLAYING") and pos not in ("", "0:00:00", "00:00:00")):
                break
        seen = requests_seen[mark:]
        results.append((v, "%s at %s" % (state, pos or "-"), seen))
        print("  %-12s %-28s %s" % (v[0], state, pos))
        for r in seen:
            print("      %-4s range=%-14s features=%s mediainfo=%s ua=%s" % (
                r["method"], r["range"] or "-", r["features"] or "-", r["mediainfo"] or "-", (r["ua"] or "-")[:40]))
    soap(ctl, "Stop")
    httpd.shutdown()
    out = os.path.join(CACHE, "result-%s.json" % re.sub(r"\W+", "-", tv_name).strip("-"))
    json.dump([{"variant": v[0], "tests": v[4], "result": res, "requests": seen} for v, res, seen in results],
              open(out, "w"), indent=1)
    print("  vastgelegd in " + out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
