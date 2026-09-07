#!/usr/bin/env python3
"""Turn subtitles on for a running Stremio DLNA cast.

The Stremio UI never passes your subtitle choice to the cast, so the server is
never asked to render one. This sends it the way the UI should have.

  python3 cast-subs.py tt14186672:1:3         subtitles for a series episode
  python3 cast-subs.py tt1234567              subtitles for a movie
  python3 cast-subs.py tt14186672:1:3 dut     another language (eng, dut, ger, fre, spa)
  python3 cast-subs.py --list tt14186672:1:3  show what is available
  python3 cast-subs.py off                    subtitles off, back to the lossless copy

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

    def send(**kw):
        kw.setdefault("time", pos)
        get(f"{SRV}/casting/{dev['id']}/player?" + urllib.parse.urlencode(kw), 25)

    if ident == "off":
        send(subtitlesSrc="", subtitlesDelay=0)
        print("subtitles off; the stream restarts and the video is a lossless copy again")
        return 0
    if not ident:
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
