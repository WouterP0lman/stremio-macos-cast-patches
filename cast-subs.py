#!/usr/bin/env python3
"""Turn subtitles on for a running Stremio DLNA cast.

The Stremio UI never passes your subtitle choice to the cast, so the server is
never asked to render one. This sends it the way the UI should have.

  python3 cast-subs.py tt14186672:1:3         subtitles for a series episode
  python3 cast-subs.py tt1234567              subtitles for a movie
  python3 cast-subs.py tt14186672:1:3 dut     another language (eng, dut, ger, fre, spa)
  python3 cast-subs.py --list tt14186672:1:3  show what is available
  python3 cast-subs.py off                    subtitles off, back to the lossless copy
  python3 cast-subs.py tt14186672:1:3 --at 24:01   also jump to that position
  python3 cast-subs.py --at 24:01             only jump, leave subtitles as they are

A cast always starts at 0 because DLNAClient.play resets the position, and the
Stremio UI does not send your current one. --at sets it explicitly.

Needs the casting patches from this repo. Patch 8 keeps the timing right at any
position; burning subtitles in forces a video re-encode for as long as they are on.
"""
import json, sys, urllib.parse, urllib.request

SRV = "http://127.0.0.1:11470"

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Stremio/5"

def get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")

def main():
    args = [a for a in sys.argv[1:] if a]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__); return 0
    listing = args[0] == "--list"
    if listing: args = args[1:]
    at = None
    if "--at" in args:
        i = args.index("--at")
        if i + 1 >= len(args): sys.exit("--at needs a position, for example --at 24:01")
        parts = args[i + 1].split(":")
        try: secs = sum(int(p) * 60 ** k for k, p in enumerate(reversed(parts)))
        except ValueError: sys.exit("--at wants MM:SS or HH:MM:SS")
        at = secs * 1000
        args = args[:i] + args[i + 2:]
    ident = args[0] if args else ""
    lang = args[1] if len(args) > 1 else "eng"

    try: get(SRV + "/settings", 5)
    except Exception: sys.exit("Stremio's streaming server is not running on port 11470.")

    devs = [d for d in json.loads(get(SRV + "/casting")) if d.get("type") in ("tv", "chromecast")]
    if not devs: sys.exit("No cast device found on the network.")
    dev = devs[0]
    print(f"cast target: {dev.get('name')}")

    st = json.loads(get(f"{SRV}/casting/{dev['id']}/player"))
    if not st.get("source"):
        sys.exit("Nothing is casting right now. Start the cast in Stremio, then run this again.")
    pos = int(st.get("time") or 0)
    print(f"playing at {pos // 1000}s, subtitles currently: {st.get('subtitlesSrc') or 'off'}")
    if at is not None:
        pos = at
        print(f"jumping to {pos // 1000}s")

    def send(**kw):
        kw.setdefault("time", pos)
        url = f"{SRV}/casting/{dev['id']}/player?" + urllib.parse.urlencode(kw)
        try:
            get(url, 40)
        except Exception as e:
            # the server answers only after the TV has been stopped and reloaded,
            # which can outlast any sane timeout. The command itself did go out.
            print(f"  (no reply within 40s: {type(e).__name__}; the command was sent)")

    if ident == "off":
        send(subtitlesSrc="", subtitlesDelay=0)
        print("subtitles off; the stream restarts and the video is a lossless copy again")
        return 0
    if not ident:
        if at is not None:
            send(subtitlesSrc=st.get("subtitlesSrc") or "", subtitlesDelay=0)
            print(f"the TV restarts at {pos // 1000}s within about 5 seconds")
            return 0
        sys.exit("Give an IMDb id, for example tt14186672:1:3 (series) or tt1234567 (movie).")

    kind = "series" if ":" in ident else "movie"
    data = json.loads(get(f"https://opensubtitles-v3.strem.io/subtitles/{kind}/{ident}.json"))
    subs = data.get("subtitles", [])
    hits = [s for s in subs if s.get("lang") == lang]
    if listing:
        print(f"{len(subs)} tracks total, {len(hits)} in '{lang}'")
        for s in hits[:10]: print("  ", s.get("id"), s.get("url"))
        langs = sorted({s.get("lang") for s in subs})
        print("languages:", " ".join(l for l in langs if l))
        return 0
    if not hits:
        langs = sorted({s.get("lang") for s in subs})
        sys.exit(f"No '{lang}' subtitles for {ident}. Available: {' '.join(l for l in langs if l)}")

    for cand in hits[:4]:
        url = cand["url"]
        try:
            sample = get(f"{SRV}/subtitles.srt?from={urllib.parse.quote(url, safe='')}", 25)
        except Exception:
            continue
        if "-->" in sample:
            send(subtitlesSrc=url, subtitlesDelay=0, subtitlesSize=100)
            print(f"sent: {url}")
            print(f"the TV restarts at {pos // 1000}s within about 5 seconds, with subtitles burned in")
            return 0
        print(f"  skipping unusable track {cand.get('id')}")
    sys.exit("None of the tracks could be fetched by Stremio. Try another language, or --list.")

if __name__ == "__main__":
    sys.exit(main())
