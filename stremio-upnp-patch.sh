#!/bin/bash
# Stremio for macOS (5.1.x, bundled ffmpeg 7.1.1): repeatable fixes for DLNA/Chromecast casting.
#   apply:            bash stremio-upnp-patch.sh
#   check only:       DRY=1 bash stremio-upnp-patch.sh
#   test on a copy:   STREMIO_SERVER_JS=/path/to/copy.js bash stremio-upnp-patch.sh
# Patches (all string-anchored, idempotent, verified on server.js 4.21.0 shipped with Stremio 5.1.26 and 5.1.27):
#  1  UPnP eventing parser try/catch     : "Stremio server stopped" (sax strictFail) on malformed NOTIFY XML from a TV
#  2  casting regex: [0x..] stream id     : ffmpeg 7 prints "Stream #0:1[0x2](eng)"; without this every cast is muxed
#                                           with matroska defaults (libx264 re-encode + Vorbis audio) -> "unsupported audio codec"
#  3  SOAP response try/catch             : same crash class as 1, for replies to Play/Stop/GetPositionInfo
#  4  casting regex: optional profile     : "Audio: ac3, 48000 Hz, ..." lost channels/default; multi-audio picked the wrong track
#  5  -vbsf -> -bsf:v                     : -vbsf no longer exists in ffmpeg 7 (legacy HLSv1 DLNA route, exit 8)
#  6  DLNA: AC3 passthrough              : keep Dolby Digital 5.1 as is for DLNA TVs (they carry an AC-3 decoder) instead of AAC stereo
#  7  better AAC fallback               : aac_at (Apple AudioToolbox) at 192 kbit/s instead of ffmpeg's native aac at 128
#  8  subtitle sync                     : do not pre-shift the .srt; with -copyts the frames keep their original PTS,
#                                        so shifting made burned-in subtitles drift (measured 18s off at offset 20) and vanish
# 10  subtitle delay in JS            : shift the .srt text instead of ffmpeg -ss, which cannot seek a subtitle
#                                        stream and rebased on the previous cue; enables working earlier/later timing
#  9  repair TV event XML                : LG echoes our cast URL with unescaped '&' plus a trailing NUL byte, so every UPnP
#                                        status event was unparseable; repair instead of discard, restoring transport state
# A Stremio auto-update replaces server.js and removes all of this; just run the script again (or install launchd/).
set -e
APP=/Applications/Stremio.app
S=${STREMIO_SERVER_JS:-$APP/Contents/MacOS/server.js}
DIR=$(cd "$(dirname "$0")" && pwd)
LIVE=1; [ -n "$DRY" ] && LIVE=; [ -n "$STREMIO_SERVER_JS" ] && LIVE=
[ -f "$S" ] || { echo "server.js not found: $S"; exit 1; }

run_patch() {  # $1 = target file, $2 = "dry" or ""
python3 - "$1" "$2" <<'PY'
import sys
p, dry = sys.argv[1], sys.argv[2]
L = open(p, encoding="utf-8").read().split("\n")
changed = []

def one(pred, what):
    h = [i for i, l in enumerate(L) if pred(l)]
    assert len(h) == 1, "%s: pattern not found exactly once: %r" % (what, h)
    return h[0]

# 1: UPnP eventing try/catch
i = one(lambda l: 'lastChange = doc.findtext(".//LastChange")' in l and "et.parse(" in l, "patch 1")
if "try {" in L[i-1]: print("patch 1: present (line %d)" % (i+1))
else:
    assert L[i-1].rstrip().endswith("(function(buf) {"), L[i-1]
    c = next(j for j in range(i, i+40) if L[j].strip() == "})(buf);")
    ind = L[c][: len(L[c]) - len(L[c].lstrip())]
    L[i-1] = L[i-1].rstrip() + " try {"
    L[c] = ind + '} catch (e) { console.error("[patch] ignoring malformed UPnP event XML:", e && e.message); return []; }\n' + L[c]
    changed.append(1); print("patch 1: applied (line %d)" % (i+1))

# 2: casting regex, ffmpeg 7 "[0x..]" stream id block
OLD2 = r'var codec = line.match(/#(\d+:\d+)(?:\((\w{3})\)|):\s(\w+):\s(\w+)'
NEW2 = r'var codec = line.match(/#(\d+:\d+)(?:\[[^\]]*\])?(?:\((\w{3})\)|):\s(\w+):\s(\w+)'
if any(NEW2 in l for l in L): print("patch 2: present")
else:
    i = one(lambda l: OLD2 in l, "patch 2"); L[i] = L[i].replace(OLD2, NEW2, 1)
    changed.append(2); print("patch 2: applied (line %d)" % (i+1))

# 3: SOAP response try/catch (+ null-safe errorDescription)
OLD3 = 'var doc = et.parse(buf.toString());'
NEW3 = 'var doc; try { doc = et.parse(buf.toString()); } catch (e) { e.code = "EUPNP", console.error("[patch] malformed SOAP response XML:", e && e.message); return callback(e); }'
if any('try { doc = et.parse(buf.toString()); } catch (e) { e.code = "EUPNP"' in l for l in L): print("patch 3: present")
else:
    i = one(lambda l: l.strip() == OLD3, "patch 3")
    assert "200 !== res.statusCode" in L[i+1], L[i+1]
    L[i] = L[i].replace(OLD3, NEW3, 1)
    L[i+2] = L[i+2].replace('errorDescription = doc.findtext(".//errorDescription").trim()', 'errorDescription = (doc.findtext(".//errorDescription") || "").trim()', 1)
    changed.append(3); print("patch 3: applied (line %d)" % (i+1))

# 4: casting regex, profile parenthetical after the codec name is optional
OLD4 = r':\s(\w+):\s(\w+)(?:\s([^,]+),\s(\w+\([^)]+\)|[^,]+),\s([^,]+),\s(.*?)(?:\s(\(default\)))?$)?/m'
NEW4 = r':\s(\w+):\s(\w+)(?:(?:\s([^,]+))?,\s(\w+\([^)]+\)|[^,]+),\s([^,]+),\s(.*?)(?:\s(\(default\)))?$)?/m'
if any(NEW4 in l for l in L): print("patch 4: present")
else:
    i = one(lambda l: OLD4 in l and "var codec = line.match(" in l, "patch 4"); L[i] = L[i].replace(OLD4, NEW4, 1)
    changed.append(4); print("patch 4: applied (line %d)" % (i+1))

# 5: -vbsf -> -bsf:v (exactly two lines: h264 and hevc)
h = [i for i, l in enumerate(L) if '[ "-vbsf", ' in l]
if not h: print("patch 5: present")
else:
    assert len(h) == 2 and all("_mp4toannexb" in L[i] for i in h), "patch 5: unexpected -vbsf hits %r" % h
    for i in h: L[i] = L[i].replace('"-vbsf"', '"-bsf:v"', 1)
    changed.append(5); print("patch 5: applied (lines %s)" % ", ".join(str(i+1) for i in h))

# 6: DLNA route (/casting/transcode.mp4) passes AC3 through; Chromecast (/casting/transcode) keeps AAC stereo
OLD6 = 'copyAudio = "aac" == audioStream.codec && "stereo" == audioStream.channels)'
NEW6 = 'copyAudio = "aac" == audioStream.codec && "stereo" == audioStream.channels || /\\.mp4(\\?|$)/i.test(req.originalUrl || req.url) && "ac3" == audioStream.codec)'
PREV6 = 'copyAudio = "aac" == audioStream.codec && "stereo" == audioStream.channels || /\\.mp4$/i.test(req.path) && "ac3" == audioStream.codec)'   # first variant, req.path is undefined in pillarjs/router
if any(NEW6 in l for l in L): print("patch 6: present")
else:
    i = one(lambda l: OLD6 in l or PREV6 in l, "patch 6"); L[i] = L[i].replace(PREV6 if PREV6 in L[i] else OLD6, NEW6, 1)
    changed.append(6); print("patch 6: applied (line %d)" % (i+1))

# 7: AAC fallback via AudioToolbox at 192 kbit/s
OLD7 = '"-c:a", "aac", "-ac", "2")'
NEW7 = '"-c:a", "aac_at", "-b:a", "192k", "-ac", "2")'
if any(NEW7 in l for l in L): print("patch 7: present")
else:
    i = one(lambda l: OLD7 in l and "copyAudio ?" in l, "patch 7"); L[i] = L[i].replace(OLD7, NEW7, 1)
    changed.append(7); print("patch 7: applied (line %d)" % (i+1))

# 8: subtitle sync, makeSubs must not pre-shift the srt (frames keep original PTS because of -copyts)
OLD8 = 'this.makeSubs(req.query.subtitles, Math.max(0, offset - subtitlesDelay))'
MID8 = 'this.makeSubs(req.query.subtitles, 0)'          # first form of this patch
NEW8 = 'this.makeSubs(req.query.subtitles, subtitlesDelay)'
if any(NEW8 in l for l in L): print("patch 8: present")
else:
    i = one(lambda l: OLD8 in l or MID8 in l, "patch 8")
    L[i] = L[i].replace(MID8 if MID8 in L[i] else OLD8, NEW8, 1)
    changed.append(8); print("patch 8: applied (line %d)" % (i+1))

# 9: repair malformed UPnP event XML (unescaped & and control chars) instead of discarding the event
FIX = 'var fixXml = function (x) { return String(x).replace(/[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]/g, "").replace(/&(?!(?:amp|lt|gt|quot|apos|#[0-9]+|#x[0-9a-fA-F]+);)/g, "&amp;"); }; '
if any("var fixXml = function" in l for l in L): print("patch 9: present")
else:
    i = one(lambda l: 'lastChange = doc.findtext(".//LastChange")' in l and "et.parse(" in l, "patch 9")
    assert L[i-1].rstrip().endswith("try {"), "patch 9 requires patch 1 first: " + L[i-1][-40:]
    L[i-1] = L[i-1].rstrip() + " " + FIX
    L[i] = L[i].replace("et.parse(buf.toString())", "et.parse(fixXml(buf.toString()))", 1)
    j = i + 1
    assert "et.parse(lastChange)" in L[j], L[j]
    L[j] = L[j].replace("et.parse(lastChange)", "et.parse(fixXml(lastChange))", 1)
    changed.append(9); print("patch 9: applied (lines %d-%d)" % (i, j+1))

# 10: subtitle delay done in JS on the srt text (ffmpeg cannot seek a subtitle stream accurately)
SHIFT = ('var shiftSrt = function (t, ms) { return ms ? t.replace(/(\\d{2}):(\\d{2}):(\\d{2}),(\\d{3})/g, '
         'function (m, h, mi, s, ms3) { var v = ((+h * 3600 + +mi * 60 + +s) * 1000 + +ms3) + ms; if (v < 0) v = 0; '
         'var p = function (n, w) { return ("000" + n).slice(-w); }; '
         'return p(Math.floor(v / 3600000), 2) + ":" + p(Math.floor(v % 3600000 / 60000), 2) + ":" '
         '+ p(Math.floor(v % 60000 / 1000), 2) + "," + p(v % 1000, 3); }) : t; }; ')
if any("var shiftSrt = function" in l for l in L): print("patch 10: present")
else:
    i = one(lambda l: "Casting.prototype.makeSubs = function(subsUrl, offset)" in l, "patch 10")
    j = next(k for k in range(i, i + 6) if L[k].strip() == "var self = this;")
    L[j] = L[j].replace("var self = this;", "var self = this; " + SHIFT, 1)
    k = one(lambda l: 'subs = Buffer.from(text.replace(/\\r/g, ""), "utf8")' in l, "patch 10 (buffer)")
    L[k] = L[k].replace('Buffer.from(text.replace(/\\r/g, ""), "utf8")', 'Buffer.from(shiftSrt(text.replace(/\\r/g, ""), offset), "utf8")', 1)
    m = one(lambda l: l.strip().startswith("return offset ? new Promise(") and "tmp.file" not in l, "patch 10 (ffmpeg shift)")
    ind = L[m][: len(L[m]) - len(L[m].lstrip())]
    depth = 0
    for e in range(m, m + 25):
        depth += L[e].count("(") - L[e].count(")")
        if depth <= 0 and e > m: break
    L[m:e + 1] = [ind + "return sourceSubsFn;"]
    changed.append(10); print("patch 10: applied (lines %d-%d)" % (j + 1, m + 1))

if changed and not dry:
    open(p, "w", encoding="utf-8").write("\n".join(L)); print("written:", p)
elif changed: print("DRY: patches %s NOT written" % changed)
else: print("nothing to do")
PY
}

# Pass 1: detect. A run with nothing to do must not restart Stremio.
OUT=$(run_patch "$S" dry); echo "$OUT"
if ! echo "$OUT" | grep -q "applied"; then "$APP/Contents/MacOS/node" --check "$S" && echo "syntax OK"; exit 0; fi
[ -n "$DRY" ] && { "$APP/Contents/MacOS/node" --check "$S" && echo "syntax OK (dry run, nothing written)"; exit 0; }
if [ -z "$LIVE" ]; then   # copy mode: write to the copy, do not touch the app
  run_patch "$S" "" | grep -v "^patch" || true
  "$APP/Contents/MacOS/node" --check "$S" && echo "syntax OK (copy mode, app untouched)"; exit 0
fi

# Pass 2: live apply.
BK=$DIR/backups/$(date +%Y-%m-%d_%H%M%S)
osascript -e 'tell application "Stremio" to quit' 2>/dev/null || true; sleep 2
pkill -f "Stremio.app/Contents/MacOS" 2>/dev/null || true
mkdir -p "$BK"; cp -p "$S" "$BK/server.js.orig"; cp -Rp "$APP/Contents/_CodeSignature" "$BK/"
run_patch "$S" "" | grep -v "^patch" || true
"$APP/Contents/MacOS/node" --check "$S" && echo "syntax OK"
# The bundle seal now differs, so re-sign ad hoc (entitlements and hardened-runtime flag are preserved).
codesign --force --sign - --preserve-metadata=entitlements,flags,identifier "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
open -a "$APP"; echo "done, backup in $BK"
