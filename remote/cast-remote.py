#!/usr/bin/env python3
"""A remote control for Stremio casts, in your browser.

    python3 remote/cast-remote.py        then open http://localhost:11471

Works with DLNA TVs and Chromecasts. Seek forward and back, pause, volume,
subtitles on/off with earlier/later timing. Needs the casting patches from this
repo: patch 8/10 for subtitle timing, patch 9 so the position survives.

Every change restarts the stream on the device (Stremio debounces ~3s), so a
seek or subtitle change takes a few seconds to take effect. That is how
Stremio's DLNA casting works, not something this tool adds.
"""
import http.server, json, os, re, socketserver, sys, threading, urllib.error, urllib.parse, urllib.request

STREMIO = "http://127.0.0.1:11470"
PORT = int(os.environ.get("CAST_REMOTE_PORT", "11471"))
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Stremio-cast-remote"
HERE = os.path.dirname(os.path.abspath(__file__))


def fetch(url, timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def fetch_json(url, timeout=15):
    return json.loads(fetch(url, timeout))


def parse_title(name):
    """Guess title and season/episode from a torrent or file name."""
    if not name:
        return None, None, None
    n = re.sub(r"\.(mkv|mp4|avi|m4v)$", "", name.rsplit("/", 1)[-1])
    n = n.replace(".", " ").replace("_", " ")
    m = re.search(r"\bS(\d{1,2})\s?E(\d{1,2})\b", n, re.I)
    season = episode = None
    if m:
        season, episode = int(m.group(1)), int(m.group(2))
        n = n[: m.start()]
    else:
        m = re.search(r"\b(\d{4})\b", n)          # a year marks the end of a movie title
        if m:
            n = n[: m.start()]
    n = re.split(r"\b(1080p|720p|2160p|480p|COMPLETE|WEB[- ]?DL|WEBRip|BluRay|HDTV|x264|x265|HEVC|AMZN|NF|DDP?5|AAC|Season)\b", n, flags=re.I)[0]
    return n.strip(" -[]()"), season, episode


def find_imdb(title):
    for kind in ("series", "movie"):
        try:
            data = fetch_json(f"https://v3-cinemeta.strem.io/catalog/{kind}/top/search={urllib.parse.quote(title)}.json", 12)
        except Exception:
            continue
        for item in data.get("metas", [])[:1]:
            if item.get("id", "").startswith("tt"):
                return item["id"], kind, item.get("name")
    return None, None, None


def now_playing():
    """What Stremio is streaming, as far as the server knows."""
    try:
        stats = fetch_json(f"{STREMIO}/stats.json", 8)
    except Exception:
        return {}
    if not isinstance(stats, dict):
        return {}
    for h, e in stats.items():
        files = e.get("files") or []
        return {"infoHash": h, "name": e.get("name"), "files": [f.get("path") or f.get("name") for f in files],
                "peers": e.get("peers"), "speed": e.get("downloadSpeed")}
    return {}


def send_command(dev_id, params):
    """Fire a player command. The endpoint only answers after the device has
    reloaded, so do not make the browser wait for it."""
    url = f"{STREMIO}/casting/{dev_id}/player?" + urllib.parse.urlencode(params)
    def run():
        try:
            fetch(url, 60)
        except Exception:
            pass
    threading.Thread(target=run, daemon=True).start()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, body, ctype="application/json", code=200):
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        one = lambda k, d=None: (q.get(k) or [d])[0]
        try:
            if u.path in ("/", "/index.html"):
                with open(os.path.join(HERE, "cast-remote.html"), encoding="utf-8") as f:
                    return self._send(f.read(), "text/html; charset=utf-8")

            if u.path == "/api/state":
                try:
                    devices = [d for d in fetch_json(f"{STREMIO}/casting", 8) if d.get("type") in ("tv", "chromecast")]
                except Exception as e:
                    return self._send({"error": f"Stremio's streaming server is not reachable ({type(e).__name__})"}, code=200)
                dev_id = one("device") or (devices[0]["id"] if devices else None)
                state = {}
                if dev_id:
                    try:
                        state = fetch_json(f"{STREMIO}/casting/{dev_id}/player", 10)
                    except Exception as e:
                        state = {"error": type(e).__name__}
                return self._send({"devices": devices, "device": dev_id, "state": state, "playing": now_playing()})

            if u.path == "/api/identify":
                name = one("name") or ""
                title, season, episode = parse_title(name)
                if not title:
                    return self._send({"error": "could not read a title from the file name"})
                imdb, kind, matched = find_imdb(title)
                if not imdb:
                    return self._send({"title": title, "error": f"no match for '{title}' in Cinemeta"})
                ident = f"{imdb}:{season}:{episode}" if season and episode else imdb
                return self._send({"title": title, "matched": matched, "kind": kind, "id": ident,
                                   "season": season, "episode": episode})

            if u.path == "/api/subs":
                ident = one("id") or ""
                kind = "series" if ":" in ident else "movie"
                try:
                    data = fetch_json(f"https://opensubtitles-v3.strem.io/subtitles/{kind}/{ident}.json", 20)
                except Exception as e:
                    return self._send({"error": f"OpenSubtitles unreachable ({type(e).__name__})"})
                subs = data.get("subtitles", [])
                langs = {}
                for s in subs:
                    langs.setdefault(s.get("lang") or "?", []).append({"id": s.get("id"), "url": s.get("url")})
                return self._send({"languages": sorted(langs), "tracks": {k: v[:8] for k, v in langs.items()},
                                   "total": len(subs)})

            if u.path == "/api/cmd":
                dev_id = one("device")
                if not dev_id:
                    return self._send({"error": "no device"}, code=400)
                params = {k: v[0] for k, v in q.items() if k != "device"}
                if not params:
                    return self._send({"error": "no command"}, code=400)
                send_command(dev_id, params)
                return self._send({"sent": params})

            self._send({"error": "not found"}, code=404)
        except BrokenPipeError:
            pass
        except Exception as e:
            try:
                self._send({"error": f"{type(e).__name__}: {e}"}, code=500)
            except Exception:
                pass

    def log_message(self, *a):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    try:
        fetch(f"{STREMIO}/settings", 5)
    except Exception:
        sys.exit("Stremio's streaming server is not running on port 11470. Start Stremio first.")
    print(f"Cast remote on http://localhost:{PORT}  (ctrl-c to stop)")
    try:
        Server(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
