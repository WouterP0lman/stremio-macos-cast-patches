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
# 11  cast keeps your position         : play() no longer forces time=0, so a cast can start where you were
# 12  no double-counted position       : ffmpeg uses -copyts so the renderer already reports absolute time;
#                                        adding seekTime on top made the position jump ahead after every seek
# 13  requested position survives      : the ffmpeg probe in play() left a window where the still-playing old
#                                        stream overwrote the position you asked for; Chromecast also needs seekTime
# 14  subtitles chosen automatically   : most torrents ship a matching .srt next to the video; use it,
#                                        so casting has subtitles without any helper script or internet
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

# 11: a cast keeps the position the request carries instead of always starting at 0
OLD11A = 'isset(params.source) && (params.source ? args[method = "play"] = params.source : method = "close")'
NEW11A = 'isset(params.source) && (params.source ? args[method = "play"] = [ params.source, params.time ] : method = "close")'
OLD11B = 'DLNAClient.prototype.play = function(srcURL) {'
NEW11B = 'DLNAClient.prototype.play = function(srcURL, startAt) {'
OLD11C = 'ChromecastClient.prototype.play = function(srcURL) {'
NEW11C = 'ChromecastClient.prototype.play = function(srcURL, startAt) {'
TIME0 = 'this.mediaStatus.time = 0'
TIMEN = 'this.mediaStatus.time = parseInt(startAt, 10) || 0'
if any(NEW11A in l for l in L): print("patch 11: present")
else:
    i = one(lambda l: OLD11A in l, "patch 11 (dispatch)"); L[i] = L[i].replace(OLD11A, NEW11A, 1)
    for name, old, new in (("DLNA", OLD11B, NEW11B), ("Chromecast", OLD11C, NEW11C)):
        j = one(lambda l, o=old: o in l, "patch 11 (%s play)" % name)
        L[j] = L[j].replace(old, new, 1)
        k = next(x for x in range(j, j + 4) if TIME0 in L[x])
        L[k] = L[k].replace(TIME0, TIMEN, 1)
    changed.append(11); print("patch 11: applied (line %d plus both play methods)" % (i+1))

# 12: position from a DLNA renderer is not double counted after a seek
OLD12 = 'this.mediaStatus[field] = this.seekTime + 1e3 * parseInt(value, 10);'
NEW12 = ('this.mediaStatus[field] = (function (t, s) { return t >= s ? t : s + t; })'
         '(1e3 * parseInt(value, 10), this.seekTime || 0);')
if any(NEW12 in l for l in L): print("patch 12: present")
else:
    i = one(lambda l: OLD12 in l, "patch 12"); L[i] = L[i].replace(OLD12, NEW12, 1)
    changed.append(12); print("patch 12: applied (line %d)" % (i+1))

# 13: the requested start position survives the probe that runs before the device is loaded
OLD13A = 'var self = this;\n        return castingUtils.getVideoInfo(this.executables.ffmpeg, srcURL).then((function(info) {'
NEW13A = 'var self = this, wantedAt = this.mediaStatus.time;\n        return castingUtils.getVideoInfo(this.executables.ffmpeg, srcURL).then((function(info) {'
OLD13B = 'self.mediaStatus.length = 1e3 * info.duration, self.delayedPlayFromStatus();'
NEW13B = 'self.mediaStatus.length = 1e3 * info.duration, self.mediaStatus.time = wantedAt, self.delayedPlayFromStatus();'
OLD13C = 'this.seekTime = 0, this.mediaStatus.source = srcURL, this.mediaStatus.time = parseInt(startAt, 10) || 0,'
NEW13C = 'this.seekTime = (parseInt(startAt, 10) || 0) / 1e3, this.mediaStatus.source = srcURL, this.mediaStatus.time = parseInt(startAt, 10) || 0,'
if any("wantedAt" in l for l in L): print("patch 13: present")
else:
    i = one(lambda l: 'var self = this;' == l.strip() and "DLNAClient" not in l, "patch 13 (marker)") if False else None
    # DLNA: bewaar de gevraagde tijd voordat de ffmpeg-probe draait
    d = one(lambda l: "DLNAClient.prototype.play = function(srcURL, startAt)" in l, "patch 13 (dlna play)")
    j = next(k for k in range(d, d + 6) if L[k].strip() == "var self = this;")
    L[j] = L[j].replace("var self = this;", "var self = this, wantedAt = this.mediaStatus.time;", 1)
    k = next(x for x in range(j, j + 10) if OLD13B in L[x])
    L[k] = L[k].replace(OLD13B, NEW13B, 1)
    # Chromecast: seekTime (in seconden) bepaalt daar de startpositie, niet mediaStatus.time
    c = one(lambda l: OLD13C in l, "patch 13 (chromecast play)")
    L[c] = L[c].replace(OLD13C, NEW13C, 1)
    changed.append(13); print("patch 13: applied (lines %d, %d, %d)" % (j+1, k+1, c+1))

# 14: pick a subtitle automatically when casting; the file usually sits in the same torrent
PICK = 'pickSubtitle: function (srcURL) { return new Promise(function (resolve) { try { var m = String(srcURL || "").match(/\\/([0-9a-f]{40})\\/(\\d+)/); if (!m) return resolve(null); var ih = m[1], idx = parseInt(m[2], 10), efs = __webpack_require__(172); var stem = function (n) { return String(n).replace(/^.*[\\/\\\\]/, "").replace(/\\.[^.]+$/, "").toLowerCase(); }; var vid = efs.getFilename(ih, idx); if (!vid) return resolve(null); var want = stem(vid), hits = []; for (var i = 0; i < 500; i++) { var n = efs.getFilename(ih, i); if (!n) break; if (i === idx || !/\\.(srt|ass|ssa|sub|vtt)$/i.test(n)) continue; var b = stem(n); if (b === want) { hits.push({ i: i, tag: "" }); } else if (b.indexOf(want + ".") === 0) { hits.push({ i: i, tag: b.slice(want.length + 1) }); } } if (!hits.length) return resolve(null); var done = function (h) { resolve({ index: h.i, url: "http://127.0.0.1:11470/" + ih + "/" + h.i, name: efs.getFilename(ih, h.i) }); }; var exact = hits.filter(function (h) { return !h.tag; }); if (hits.length === 1 || (exact.length && hits.length === exact.length)) return done(exact[0] || hits[0]); castingUtils.userSubtitleLang(function (lang) { var L = { eng: ["en", "eng", "english"], nld: ["nl", "nld", "dut", "dutch"], ger: ["de", "ger", "deu", "german"], fre: ["fr", "fre", "fra", "french"], spa: ["es", "spa", "spanish"], por: ["pt", "por", "portuguese"], ita: ["it", "ita", "italian"], pol: ["pl", "pol", "polish"] }, l = String(lang || "").toLowerCase(), tags = L[l] || [l]; for (var k in L) { if (L[k].indexOf(l) >= 0) { tags = L[k]; break; } } var byLang = hits.filter(function (h) { return tags.indexOf(h.tag) >= 0; }); done(byLang[0] || exact[0] || hits[0]); }); } catch (e) { console.error("[patch] pickSubtitle:", e && e.message); resolve(null); } }); }, userSubtitleLang: function (cb) { var self = castingUtils; if (self._langAt && Date.now() - self._langAt < 3e5) return cb(self._lang); try { var os = __webpack_require__(22), fs2 = __webpack_require__(1), path2 = __webpack_require__(5); var roots = [path2.join(os.homedir(), "Library/WebKit/com.westbridge.stremio5-mac/WebsiteData/Default"), path2.join(os.homedir(), "Library/WebKit/com.stremio.stremio-shell-macos/WebsiteData/Default")]; var db = null, walk = function (d, depth) { if (db || depth > 3) return; var ls = []; try { ls = fs2.readdirSync(d); } catch (e) { return; } ls.forEach(function (f) { if (db) return; var full = path2.join(d, f); if (f === "localstorage.sqlite3") { db = full; return; } try { if (fs2.statSync(full).isDirectory()) walk(full, depth + 1); } catch (e) {} }); }; roots.forEach(function (r) { walk(r, 0); }); if (!db) { self._lang = null, self._langAt = Date.now(); return cb(null); } child.execFile("/usr/bin/sqlite3", ["file:" + db + "?mode=ro", "SELECT hex(value) FROM ItemTable WHERE key=\'profile\';"], { timeout: 4e3, maxBuffer: 33554432 }, function (err, out) { var lang = null; try { if (!err && out.trim()) { var prof = JSON.parse(Buffer.from(out.trim(), "hex").toString("utf16le")), st = prof.settings || {}; if (!1 !== st.subtitlesAutoSelect) lang = st.subtitlesLanguage || null; } } catch (e) {} self._lang = lang, self._langAt = Date.now(); cb(lang); }); } catch (e) { self._lang = null, self._langAt = Date.now(); cb(null); } }, '
if any("pickSubtitle: function" in l for l in L): print("patch 14a: present")
else:
    i = one(lambda l: l.strip().startswith("getMime: function(mimeURL)"), "patch 14a")
    ind = L[i][: len(L[i]) - len(L[i].lstrip())]
    L[i] = ind + PICK + "\n" + L[i]
    changed.append("14a"); print("patch 14a: applied (line %d)" % (i+1))

# 14b/14c: use it in play(), after the line that nulls subtitlesSrc
OLD14B = 'self.mediaStatus.length = 1e3 * info.duration, self.mediaStatus.time = wantedAt, self.delayedPlayFromStatus();'
NEW14B = ('self.mediaStatus.length = 1e3 * info.duration, self.mediaStatus.time = wantedAt, '
          'castingUtils.pickSubtitle(srcURL).then(function (sub) { '
          'sub && !self.mediaStatus.subtitlesSrc && (self.mediaStatus.subtitlesSrc = sub.url); '
          'self.delayedPlayFromStatus(); });')
if any("pickSubtitle(srcURL)" in l and "delayedPlayFromStatus" in l for l in L): print("patch 14b: present")
else:
    i = one(lambda l: OLD14B in l, "patch 14b"); L[i] = L[i].replace(OLD14B, NEW14B, 1)
    changed.append("14b"); print("patch 14b: applied (line %d)" % (i+1))

# Chromecast: dezelfde haak, maar de lookup moet af zijn voordat playFromStatus draait
OLD14C = 'self.stateFlags = 0, self.status().then((function(status) {'
NEW14C = ('self.stateFlags = 0, castingUtils.pickSubtitle(srcURL).then(function (sub) { '
          'sub && !self.mediaStatus.subtitlesSrc && (self.mediaStatus.subtitlesSrc = sub.url); }), '
          'self.status().then((function(status) {')
if any("pickSubtitle(srcURL)" in l and "self.status()" in l for l in L): print("patch 14c: present")
else:
    i = one(lambda l: OLD14C in l, "patch 14c"); L[i] = L[i].replace(OLD14C, NEW14C, 1)
    changed.append("14c"); print("patch 14c: applied (line %d)" % (i+1))

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
