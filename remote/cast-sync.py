#!/usr/bin/env python3
"""Make a Stremio cast start where you left off, with subtitles.

Casting always starts at 0 with no subtitles: DLNAClient.play resets both, and
the Stremio UI never sends your current position or subtitle choice. This reads
the position Stremio itself stores (localStorage key `library_recent`), works
out the episode, and applies both to the cast.

    python3 remote/cast-sync.py            watch, and fix every new cast
    python3 remote/cast-sync.py --once     fix the cast running right now
    python3 remote/cast-sync.py --dry      show what it would do, change nothing
    python3 remote/cast-sync.py --lang dut Dutch subtitles (default eng)
    python3 remote/cast-sync.py --no-subs  position only

Stremio writes that position every few minutes, so it can lag a little behind
what you see on screen. Needs the casting patches from this repo.
"""
import glob, json, os, re, sqlite3, sys, time, urllib.parse, urllib.request

STREMIO = "http://127.0.0.1:11470"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Stremio-cast-sync"
STORE = os.path.expanduser(
    "~/Library/WebKit/com.westbridge.stremio5-mac/WebsiteData/Default/*/*/LocalStorage/localstorage.sqlite3")


def fetch(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def fetch_json(url, timeout=20):
    return json.loads(fetch(url, timeout))


def library():
    """Every library entry Stremio has stored, newest first."""
    out = []
    for path in glob.glob(STORE):
        tmp = f"/tmp/.cast-sync-{os.getpid()}.sqlite3"
        try:
            with open(path, "rb") as src, open(tmp, "wb") as dst:
                dst.write(src.read())
            db = sqlite3.connect(tmp)
            row = db.execute("SELECT value FROM ItemTable WHERE key='library_recent'").fetchone()
            db.close()
            if not row:
                continue
            raw = row[0]
            txt = raw.decode("utf-16-le") if isinstance(raw, bytes) else raw
            for item in (json.loads(txt).get("items") or {}).values():
                st = item.get("state") or {}
                out.append({"name": item.get("name"), "type": item.get("type"),
                            "imdb": item.get("_id") or "",
                            "video_id": st.get("video_id"), "time": int(st.get("timeOffset") or 0),
                            "duration": int(st.get("duration") or 0),
                            "watched": st.get("lastWatched") or ""})
        except Exception:
            continue
        finally:
            try: os.unlink(tmp)
            except OSError: pass
    out.sort(key=lambda x: x["watched"], reverse=True)
    return out


def parse_name(name):
    if not name:
        return None, None, None
    n = re.sub(r"\.(mkv|mp4|avi|m4v)$", "", name.rsplit("/", 1)[-1]).replace(".", " ").replace("_", " ")
    m = re.search(r"\bS(\d{1,2})\s?E(\d{1,2})\b", n, re.I)
    season = episode = None
    if m:
        season, episode = int(m.group(1)), int(m.group(2))
        n = n[: m.start()]
    else:
        y = re.search(r"\b(19|20)\d{2}\b", n)
        if y: n = n[: y.start()]
    n = re.split(r"\b(1080p|720p|2160p|480p|COMPLETE|WEB[- ]?DL|WEBRip|BluRay|HDTV|x264|x265|HEVC|AMZN|NF|AAC|Season)\b",
                 n, flags=re.I)[0]
    return n.strip(" -[]()"), season, episode


def match_library(file_name, lib):
    """Find the library entry for the streaming file.

    Returns (entry, video_id, exact). `exact` is False when the show is known
    but this particular episode has no stored position yet, in which case the
    video id is derived from the file name so subtitles still work."""
    title, season, episode = parse_name(file_name)
    if not title:
        return None, None, False
    key = title.lower().strip()
    show = None
    for it in lib:
        if (it.get("name") or "").lower().strip() != key:
            continue
        show = show or it
        vid = it.get("video_id") or ""
        if season and episode:
            if vid.endswith(f":{season}:{episode}") and it.get("time"):
                return it, vid, True
        elif it.get("time"):
            return it, (vid or it.get("imdb")), True
    if show:
        imdb = show.get("imdb") or ""
        if imdb.startswith("tt"):
            vid = f"{imdb}:{season}:{episode}" if season and episode else imdb
            return show, vid, False
    return None, None, False


def subtitle_url(video_id, lang):
    kind = "series" if ":" in (video_id or "") else "movie"
    data = fetch_json(f"https://opensubtitles-v3.strem.io/subtitles/{kind}/{video_id}.json", 20)
    for s in data.get("subtitles", []):
        if s.get("lang") == lang:
            url = s.get("url")
            try:
                if "-->" in fetch(f"{STREMIO}/subtitles.srt?from={urllib.parse.quote(url, safe='')}", 25):
                    return url
            except Exception:
                continue
    return None


def send(dev, params, dry):
    q = urllib.parse.urlencode(params)
    if dry:
        print(f"  [dry] would send {q}")
        return
    try:
        fetch(f"{STREMIO}/casting/{dev}/player?{q}", 45)
    except Exception:
        pass          # the endpoint only answers after the device reloads


def state_of(dev):
    return fetch_json(f"{STREMIO}/casting/{dev}/player", 12)


def current_file():
    try:
        stats = fetch_json(f"{STREMIO}/stats.json", 8)
    except Exception:
        return None, None
    if not isinstance(stats, dict):
        return None, None
    for h, e in stats.items():
        files = [f.get("path") or f.get("name") for f in (e.get("files") or [])]
        video = [f for f in files if f and re.search(r"\.(mkv|mp4|avi)$", f, re.I)]
        return h, (video[0] if video else e.get("name"))
    return None, None


def sync_once(dev, lang, want_subs, dry, min_seconds=30):
    st = state_of(dev)
    src = st.get("source")
    if not src:
        print("Nothing is casting.")
        return False
    idx = None
    m = re.search(r"/([0-9a-f]{40})/(\d+)", src)
    _, file_name = current_file()
    if m:
        idx = int(m.group(2))
        try:
            stats = fetch_json(f"{STREMIO}/stats.json", 8)
            e = stats.get(m.group(1)) or {}
            files = [f.get("path") or f.get("name") for f in (e.get("files") or [])]
            if idx < len(files):
                file_name = files[idx]
        except Exception:
            pass
    if not file_name:
        print("Could not tell which file is casting.")
        return False
    print(f"casting: {file_name.rsplit('/', 1)[-1]}")

    entry, video_id, exact = match_library(file_name, library())
    if not entry:
        title, se, ep = parse_name(file_name)
        print(f"  '{title}' is not in your Stremio library, nothing to sync")
        return False

    secs = (entry["time"] // 1000) if exact else 0
    if exact:
        print(f"  Stremio has you at {secs // 60}:{secs % 60:02d} ({video_id})")
    else:
        print(f"  no stored position for {video_id} yet, subtitles only")

    did = False
    if want_subs and not st.get("subtitlesSrc"):
        url = subtitle_url(video_id, lang)
        if url:
            print(f"  subtitles ({lang}) on")
            send(dev, {"subtitlesSrc": url, "subtitlesDelay": 0, "subtitlesSize": 100}, dry)
            did = True
            if not dry and exact and secs >= min_seconds:
                time.sleep(12)     # let the device settle before the seek
        else:
            print(f"  no usable {lang} subtitles found for {video_id}")
    elif st.get("subtitlesSrc"):
        print("  subtitles already on")

    if exact and secs >= min_seconds:
        print(f"  jumping to {secs // 60}:{secs % 60:02d}")
        send(dev, {"time": entry["time"]}, dry)
        did = True
    elif exact:
        print("  position is near the start, leaving it alone")
    return did


def main():
    args = sys.argv[1:]
    dry = "--dry" in args
    once = "--once" in args
    want_subs = "--no-subs" not in args
    lang = "eng"
    if "--lang" in args:
        i = args.index("--lang")
        if i + 1 < len(args): lang = args[i + 1]
    if "-h" in args or "--help" in args:
        print(__doc__); return 0
    try:
        fetch(f"{STREMIO}/settings", 5)
    except Exception:
        sys.exit("Stremio's streaming server is not running on port 11470.")

    devs = [d for d in fetch_json(f"{STREMIO}/casting", 8) if d.get("type") in ("tv", "chromecast")]
    if not devs:
        sys.exit("No cast device found.")
    dev = devs[0]["id"]
    print(f"device: {devs[0].get('name')}" + ("  [dry run]" if dry else ""))

    if once:
        sync_once(dev, lang, want_subs, dry)
        return 0

    print("watching for new casts, ctrl-c to stop")
    last_src, handled = None, set()
    while True:
        try:
            st = state_of(dev)
            src, pos = st.get("source"), int(st.get("time") or 0)
            if src and src != last_src:
                last_src = src
                handled.discard(src)
            if src and src not in handled and pos < 15000 and st.get("realStatus") in ("PLAYING", "TRANSITIONING"):
                print(f"\nnew cast detected at {pos // 1000}s")
                if sync_once(dev, lang, want_subs, dry):
                    handled.add(src)
                    time.sleep(20)
        except Exception:
            pass
        time.sleep(3)


if __name__ == "__main__":
    sys.exit(main())
