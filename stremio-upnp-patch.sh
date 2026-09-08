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
# 12  no double-counted position       : learn per device whether it reports absolute or relative time;
#                                        adding seekTime on top made the position jump ahead after every seek
# 13  requested position survives      : the ffmpeg probe in play() left a window where the still-playing old
#                                        stream overwrote the position you asked for; Chromecast also needs seekTime
# 14  subtitles chosen automatically   : most torrents ship a matching .srt next to the video; use it,
#                                        so casting has subtitles without any helper script or internet
# 15  AC3 only where it is supported    : ask the renderer what it accepts instead of assuming every DLNA TV
#                                        decodes Dolby Digital, which would leave silent audio on those that do not
# Setting: castSubtitles in server-settings.json. auto (default) uses the torrent's own
# subtitle and falls back to OpenSubtitles; local never touches the network; off disables it.
# A Stremio auto-update replaces server.js and removes all of this; just run the script again (or install launchd/).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)

# Locate Stremio. The patches themselves are plain JavaScript and platform
# independent; only finding the file and re-signing the bundle are not.
APP=""
find_server() {
  local c
  for c in \
    /Applications/Stremio.app/Contents/MacOS/server.js \
    "$HOME/Applications/Stremio.app/Contents/MacOS/server.js" \
    "$LOCALAPPDATA/Programs/LNV/Stremio-4/server.js" \
    "$PROGRAMFILES/Stremio/server.js" \
    /opt/stremio/server.js \
    /usr/lib/stremio/server.js \
    "$HOME/.local/share/stremio/server.js" \
    /usr/share/stremio/server.js
  do
    [ -f "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}
S=${STREMIO_SERVER_JS:-$(find_server || true)}
[ -n "$S" ] && [ -f "$S" ] || {
  echo "Could not find Stremio's server.js. Point at it explicitly:"
  echo "  STREMIO_SERVER_JS=/path/to/server.js bash $0"
  exit 1
}
case "$S" in *"/Stremio.app/Contents/MacOS/"*) APP="${S%/Contents/MacOS/server.js}";; esac
LIVE=1; [ -n "$DRY" ] && LIVE=; [ -n "$STREMIO_SERVER_JS" ] && LIVE=

# node: prefer the one Stremio ships, fall back to whatever is on PATH
NODE=""
for c in "$APP/Contents/MacOS/node" "$(dirname "$S")/node" "$(command -v node || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { NODE="$c"; break; }
done

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
# Patch 17a herschrijft deze regel later tot et.parse(fixXmlSoap(...)), dus de
# aanwezigheidstoets kijkt naar wat beide vormen delen: de catch met EUPNP op de
# regel waar de SOAP-response wordt geparsed. Keek hij alleen naar de kale vorm,
# dan zag patch 3 zichzelf na 17a niet meer terug, probeerde hij opnieuw, vond
# hij zijn anker niet en brak het hele script af. Dan wordt er niets gepatcht,
# ook de vijftien andere niet.
if any('catch (e) { e.code = "EUPNP"' in l and "et.parse(" in l and "buf.toString()" in l for l in L):
    print("patch 3: present")
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
NEW6 = 'copyAudio = "aac" == audioStream.codec && "stereo" == audioStream.channels || "1" === req.query.ac3 && "ac3" == audioStream.codec)'
PREV6 = 'copyAudio = "aac" == audioStream.codec && "stereo" == audioStream.channels || /\\.mp4$/i.test(req.path) && "ac3" == audioStream.codec)'   # first variant, req.path is undefined in pillarjs/router
if any(NEW6 in l for l in L): print("patch 6: present")
else:
    i = one(lambda l: OLD6 in l or PREV6 in l, "patch 6"); L[i] = L[i].replace(PREV6 if PREV6 in L[i] else OLD6, NEW6, 1)
    changed.append(6); print("patch 6: applied (line %d)" % (i+1))

# 7: AAC fallback via AudioToolbox at 192 kbit/s.
# The encoder name has to come from ffmpegPath, the local the surrounding
# Promise.all already resolved. "this" is undefined inside that callback, so
# reaching for this.executables there throws and every cast that re-encodes
# audio dies after 54 bytes.
OLD7 = '"-c:a", "aac", "-ac", "2")'
NEW7 = '"-c:a", castingUtils.aacEncoder(ffmpegPath), "-b:a", "192k", "-ac", "2")'
BAD7 = 'castingUtils.aacEncoder(this.executables.ffmpeg)'
if any(NEW7 in l for l in L): print("patch 7: present")
elif any(BAD7 in l for l in L):
    i = one(lambda l: BAD7 in l, "patch 7 repair")
    L[i] = L[i].replace(BAD7, 'castingUtils.aacEncoder(ffmpegPath)', 1)
    changed.append(7); print("patch 7: applied, replacing an earlier broken version (line %d)" % (i+1))
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

# 12: position from a DLNA renderer is not double counted after a seek.
# Renderers disagree about what they report: some answer with the point in the
# film, others with how long they have been playing. Decide once per cast, and
# never on a report below 5 seconds, because a renderer that has been told to
# play but has not started yet answers 0 whichever kind it is. Learning "not
# started" as "counts from zero" is what put an LG 20 minutes ahead of itself.
OLD12 = 'this.mediaStatus[field] = this.seekTime + 1e3 * parseInt(value, 10);'
NEW12 = ('var _t = 1e3 * parseInt(value, 10), _s = this.seekTime || 0; '
         'if (_s > 3e4 && this._absTime === undefined && _t >= 5e3) this._absTime = _t >= _s - 5e3; '
         'this.mediaStatus[field] = this._absTime === true ? _t : '
         '(this._absTime === false ? _s + _t : (_t >= _s ? _t : _s + _t));')
BAD12 = 'if (_s > 3e4 && this._absTime === undefined) this._absTime'
if any(NEW12 in l for l in L): print("patch 12: present")
elif any(BAD12 in l for l in L):
    i = one(lambda l: BAD12 in l, "patch 12 repair")
    k = L[i].index('var _t = 1e3 * parseInt(value, 10), _s = this.seekTime || 0;')
    end = L[i].index('_s + _t);', k) + len('_s + _t);')
    L[i] = L[i][:k] + NEW12 + L[i][end:]
    changed.append(12); print("patch 12: applied, replacing an earlier version (line %d)" % (i+1))
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
PICK = 'pickSubtitle: function (srcURL) { return new Promise(function (resolve) { try { var mode = castingUtils._castSubs(); if (mode === "off") return resolve(null); var m = String(srcURL || "").match(/\\/([0-9a-f]{40})\\/(\\d+)/); if (!m) return resolve(null); var ih = m[1], idx = parseInt(m[2], 10), efs = __webpack_require__(172); var stem = function (n) { return String(n).replace(/^.*[\\/\\\\]/, "").replace(/\\.[^.]+$/, "").toLowerCase(); }; var vid = efs.getFilename(ih, idx); if (!vid) return resolve(null); var want = stem(vid), hits = []; for (var i = 0; i < 500; i++) { var n = efs.getFilename(ih, i); if (!n) break; if (i === idx || !/\\.(srt|ass|ssa|sub|vtt)$/i.test(n)) continue; var b = stem(n); if (b === want) { hits.push({ i: i, tag: "" }); } else if (b.indexOf(want + ".") === 0) { hits.push({ i: i, tag: b.slice(want.length + 1) }); } } if (!hits.length) return resolve(null); var done = function (h) { resolve({ index: h.i, url: "http://127.0.0.1:11470/" + ih + "/" + h.i, name: efs.getFilename(ih, h.i) }); }; var exact = hits.filter(function (h) { return !h.tag; }); if (hits.length === 1 || (exact.length && hits.length === exact.length)) return done(exact[0] || hits[0]); castingUtils.userSubtitleLang(function (lang) { var L = { eng: ["en", "eng", "english"], nld: ["nl", "nld", "dut", "dutch"], ger: ["de", "ger", "deu", "german"], fre: ["fr", "fre", "fra", "french"], spa: ["es", "spa", "spanish"], por: ["pt", "por", "portuguese"], ita: ["it", "ita", "italian"], pol: ["pl", "pol", "polish"] }, l = String(lang || "").toLowerCase(), tags = L[l] || [l]; for (var k in L) { if (L[k].indexOf(l) >= 0) { tags = L[k]; break; } } var byLang = hits.filter(function (h) { return tags.indexOf(h.tag) >= 0; }); done(byLang[0] || exact[0] || hits[0]); }); } catch (e) { console.error("[patch] pickSubtitle:", e && e.message); resolve(null); } }); }, userSubtitleLang: function (cb) { var self = castingUtils; if (self._langAt && Date.now() - self._langAt < 3e5) return cb(self._lang); try { var db = self._uiDb(); if (!db) { self._lang = null, self._langAt = Date.now(); return cb(null); } if (/leveldb$/i.test(db)) { var lg = self._scanLevelDb(db, "subtitlesLanguage"); self._lang = lg, self._langAt = Date.now(); return cb(lg); } child.execFile(castingUtils._sqlite(), ["file:" + db + "?mode=ro", "SELECT hex(value) FROM ItemTable WHERE key=\'profile\';"], { timeout: 4e3, maxBuffer: 33554432 }, function (err, out) { var lang = null; try { if (!err && out.trim()) { var prof = JSON.parse(Buffer.from(out.trim(), "hex").toString("utf16le")), st = prof.settings || {}; if (!1 !== st.subtitlesAutoSelect) lang = st.subtitlesLanguage || null; } } catch (e) {} self._lang = lang, self._langAt = Date.now(); cb(lang); }); } catch (e) { self._lang = null, self._langAt = Date.now(); cb(null); } }, '
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

# 14d: fall back to OpenSubtitles when the torrent has no subtitle file of its own
REMOTE = 'remoteSubtitle: function (ih, idx, lang, cb) { var self = castingUtils, done = false; var finish = function (r) { if (!done) { done = true; cb(r); } }; setTimeout(function () { finish(null); }, 12e3); try { self.videoIdFor(ih, idx, function (vid) { if (!vid) return finish(null); var base = "http://127.0.0.1:11470/" + ih + "/" + idx; fetch("http://127.0.0.1:11470/opensubHash?videoUrl=" + encodeURIComponent(base), { timeout: 9e3 }) .then(function (r) { return r.json(); }).catch(function () { return {}; }) .then(function (h) { var res = (h || {}).result || {}, extra = res.hash ? "/videoHash=" + res.hash + "&videoSize=" + res.size : ""; var kind = vid.indexOf(":") >= 0 ? "series" : "movie"; return fetch("https://opensubtitles-v3.strem.io/subtitles/" + kind + "/" + vid + extra + ".json", { timeout: 9e3, headers: { "User-Agent": "Stremio" } }).then(function (r) { return r.json(); }); }) .then(function (d) { var subs = (d || {}).subtitles || []; var L = { eng: ["en", "eng"], nld: ["nl", "nld", "dut"], ger: ["de", "ger", "deu"], fre: ["fr", "fre", "fra"], spa: ["es", "spa"], por: ["pt", "por", "pob"], ita: ["it", "ita"], pol: ["pl", "pol"] }; var l = String(lang || "").toLowerCase(), tags = L[l] || (l ? [l] : []); for (var k in L) { if (L[k].indexOf(l) >= 0) { tags = L[k]; break; } } var inLang = tags.length ? subs.filter(function (x) { return tags.indexOf(String(x.lang || "").toLowerCase()) >= 0; }) : subs; var exact = inLang.filter(function (x) { return x.m === "h"; }); var pick = exact[0] || inLang[0] || null; finish(pick ? { url: pick.url, name: pick.subtitleFileName || pick.id, remote: true, hashMatch: !!exact[0] } : null); }) .catch(function () { finish(null); }); }); } catch (e) { finish(null); } }, videoIdFor: function (ih, idx, cb) { try { var child2 = __webpack_require__(32), os2 = __webpack_require__(22), fs3 = __webpack_require__(1), path3 = __webpack_require__(5); var db = castingUtils._uiDb(); if (!db) return cb(null); child2.execFile(castingUtils._sqlite(), ["file:" + db + "?mode=ro", "SELECT hex(value) FROM ItemTable WHERE key=\'streams\';"], { timeout: 5e3, maxBuffer: 67108864 }, function (err, out) { if (err || !out.trim()) return cb(null); try { var data = JSON.parse(Buffer.from(out.trim(), "hex").toString("utf16le")); var items = data.items || []; for (var i = 0; i < items.length; i++) { var k = items[i][0], v = items[i][1] || {}, st = v.stream || {}; if (st.infoHash === ih && st.fileIdx === idx) return cb(k && k.videoId); } cb(null); } catch (e) { cb(null); } }); } catch (e) { cb(null); } }, aacEncoder: function (ffmpegPath) { if (castingUtils._aac) return castingUtils._aac; castingUtils._aac = \"aac\"; try { var out = __webpack_require__(32).execFileSync(ffmpegPath || \"ffmpeg\", [\"-hide_banner\", \"-encoders\"], { timeout: 5e3, maxBuffer: 8388608 }).toString(); if (out.indexOf(\"aac_at\") >= 0) castingUtils._aac = \"aac_at\"; } catch (e) {} return castingUtils._aac; }, _scanLevelDb: function (dir, key) { try { var fs5 = __webpack_require__(1), path5 = __webpack_require__(5); var files = fs5.readdirSync(dir); for (var i = files.length - 1; i >= 0; i--) { if (!/\\.(log|ldb)$/i.test(files[i])) continue; var raw = fs5.readFileSync(path5.join(dir, files[i])).toString("latin1"); var txt = raw.split(String.fromCharCode(0)).join(""); var at = txt.indexOf(key); if (at < 0) continue; var m = /([a-zA-Z]{2,3}(?:-[a-zA-Z]{2,4})?)/.exec(txt.slice(at + key.length, at + key.length + 24)); if (m) return m[1]; } } catch (e) {} return null; }, _castSubs: function () { try { var st = __webpack_require__(106); var v = st && st.castSubtitles; return v === undefined || v === null ? "auto" : String(v); } catch (e) { return "auto"; } }, _sqlite: function () { if (castingUtils._sq !== undefined) return castingUtils._sq; var fs4 = __webpack_require__(1), c = ["/usr/bin/sqlite3", "/usr/local/bin/sqlite3", "/opt/homebrew/bin/sqlite3"]; castingUtils._sq = "sqlite3"; for (var i = 0; i < c.length; i++) { try { if (fs4.existsSync(c[i])) { castingUtils._sq = c[i]; break; } } catch (e) {} } return castingUtils._sq; }, _uiDb: function () { try { var os2 = __webpack_require__(22), fs3 = __webpack_require__(1), path3 = __webpack_require__(5); if (castingUtils._db !== undefined) return castingUtils._db; var home = os2.homedir(), roots = []; if (process.platform === "darwin") { roots = [ path3.join(home, "Library/WebKit/com.westbridge.stremio5-mac/WebsiteData/Default"), path3.join(home, "Library/WebKit/com.stremio.stremio-shell-macos/WebsiteData/Default") ]; } else if (process.platform === "win32") { roots = [ path3.join(process.env.LOCALAPPDATA || "", "stremio5"), path3.join(process.env.LOCALAPPDATA || "", "Programs/LNV/Stremio-4"), path3.join(process.env.APPDATA || "", "stremio5") ]; } else { roots = [ path3.join(home, ".local/share/stremio5"), path3.join(home, ".stremio5") ]; } var found = null, walk = function (d, depth) { if (found || depth > 3) return; var ls; try { ls = fs3.readdirSync(d); } catch (e) { return; } for (var i = 0; i < ls.length; i++) { if (found) return; var full = path3.join(d, ls[i]); if (/localstorage\\.sqlite3?$/i.test(ls[i])) { found = full; return; } if (ls[i] === "leveldb") { try { if (fs3.statSync(full).isDirectory()) { found = full; return; } } catch (e) {} } try { if (fs3.statSync(full).isDirectory()) walk(full, depth + 1); } catch (e) {} } }; roots.forEach(function (r) { walk(r, 0); }); castingUtils._db = found; return found; } catch (e) { castingUtils._db = null; return null; } }, '
if any("remoteSubtitle: function" in l for l in L): print("patch 14d: present")
else:
    i = one(lambda l: "pickSubtitle: function (srcURL)" in l, "patch 14d")
    ind = L[i][: len(L[i]) - len(L[i].lstrip())]
    L[i] = ind + REMOTE + "\n" + L[i]
    # geen sidecar? dan de terugval proberen in plaats van meteen opgeven
    NEWN = ('if (!hits.length) { if (mode === "local") return resolve(null); '
            'return castingUtils.userSubtitleLang(function (lang) { '
            'castingUtils.remoteSubtitle(ih, idx, lang, resolve); }); }')
    j = one(lambda l: "if (!hits.length)" in l and "pickSubtitle" in l, "patch 14d (fallback hook)")
    import re as _re
    # vervang de hele tak, ongeacht of er logging in zit
    m = _re.search(r'if \(!hits\.length\)\s*(\{.*?return resolve\(null\); \}|return resolve\(null\);)', L[j])
    assert m, "fallback-tak niet herkend"
    L[j] = L[j][:m.start()] + NEWN + L[j][m.end():]
    changed.append("14d"); print("patch 14d: applied (lines %d, %d)" % (i+1, j+1))

# 15: only pass AC3 through to a device that says it can decode it
OLD15A = 'DLNAClient.prototype.playFromStatus = function() {'
if any("_canAc3" in l for l in L): print("patch 15: present")
else:
    # de vlag meesturen in de transcode-URL
    i = one(lambda l: "}, proxySrv = this.transcodeURL" in l, "patch 15 (url)")
    OLD = "audioTrack: this.mediaStatus.audioTrack,"
    NEW = "audioTrack: this.mediaStatus.audioTrack, ac3: this._canAc3 ? 1 : 0,"
    at = next(x for x in range(i, i + 8) if OLD in L[x])
    L[at] = L[at].replace(OLD, NEW, 1)
    # bij het starten van een cast eenmalig vragen wat het apparaat aankan
    j = one(lambda l: "DLNAClient.prototype.play = function(srcURL, startAt)" in l, "patch 15 (probe)")
    k = next(x for x in range(j, j + 6) if "var self = this, wantedAt" in L[x])
    L[k] = L[k].rstrip() + (' if (self._canAc3 === undefined) { self._canAc3 = false; try { '
        'self.player.getSupportedProtocols(function (e, protos) { try { '
        'var txt = (protos || []).map(function (x) { return String(x.contentFormat) + " " + String(x.additionalInfo); })'
        '.join(" ").toLowerCase(); '
        'self._canAc3 = /ac-?3|dolby/.test(txt) || /mpeg_ts_(sd|hd)_(na|eu|ko)/.test(txt); } catch (e2) {} }); '
        '} catch (e) {} }')
    changed.append(15); print("patch 15: applied (lines %d, %d)" % (at + 1, k + 1))

# 16: forget how the previous stream reported time when a new cast starts
OLD16 = 'this.mediaStatus.source = srcURL, this.mediaStatus.time = parseInt(startAt, 10) || 0, this.mediaStatus.subtitlesSrc = null'
NEW16 = 'this._absTime = undefined, this.mediaStatus.source = srcURL, this.mediaStatus.time = parseInt(startAt, 10) || 0, this.mediaStatus.subtitlesSrc = null'
if any("this._absTime = undefined, this.mediaStatus.source" in l for l in L): print("patch 16: present")
else:
    i = one(lambda l: OLD16 in l, "patch 16"); L[i] = L[i].replace(OLD16, NEW16, 1)
    changed.append(16); print("patch 16: applied (line %d)" % (i+1))

# 17: repair the XML a TV sends about itself, and never let a parse error kill the process
#
# Patch 9 repairs the event XML, but the same LG quirk (our cast URL echoed back
# with an unescaped '&', plus a trailing NUL) also lands in two other places:
# the SOAP reply to Play/Stop, and the device description fetched at discovery.
#
# The SOAP one was caught by patch 3, so it only broke casting. The description
# one was not caught at all: et.parse throws inside a fetch callback, nothing is
# listening, and the process dies. That is "Stremio server stopped" a second
# after "Discovery of new tv device - [TV]42LM760S-ZB".
#
# So: repair first (same regex as patch 9, from the same constant), and keep a
# catch behind it that hands the error to the callback instead of the void.
DESC_FIX = FIX.replace("var fixXml", "var fixXmlDesc").replace("fixXml(", "fixXmlDesc(")

# a) SOAP reply: repair, not just catch. Works on both the patched and the raw line.
if any("et.parse(fixXmlSoap(buf.toString()))" in l for l in L): print("patch 17a: present")
else:
    i = one(lambda l: "doc = et.parse(buf.toString());" in l and "errorDescription" not in l, "patch 17a")
    SOAP_FIX = FIX.replace("var fixXml", "var fixXmlSoap").replace("fixXml(", "fixXmlSoap(")
    if "try { doc = et.parse(buf.toString());" in L[i]:
        # patch 3 is already there: put the repair in front of its parse
        L[i] = L[i].replace("try { doc = et.parse(buf.toString());",
                            "try { " + SOAP_FIX + "doc = et.parse(fixXmlSoap(buf.toString()));", 1)
    else:
        L[i] = L[i].replace("var doc = et.parse(buf.toString());",
                            'var doc; try { ' + SOAP_FIX + 'doc = et.parse(fixXmlSoap(buf.toString())); } '
                            'catch (e) { e.code = "EUPNP", console.error("[patch] unrepairable SOAP response XML:", e && e.message); return callback(e); }', 1)
    changed.append("17a"); print("patch 17a: applied (line %d)" % (i+1))

# b) device description: repair the parse and catch what is left
if any("fixXmlDesc" in l for l in L): print("patch 17b: present")
else:
    i = one(lambda l: l.strip() == "var desc = (function(xml, url) {", "patch 17b open")
    j = one(lambda l: 'var doc = et.parse(xml), desc = extractFields(doc.find("./device")' in l, "patch 17b parse")
    k = one(lambda l: l.strip() == "})(body, self.url);", "patch 17b close")
    assert i < j < k, (i, j, k)
    L[i] = L[i].replace("var desc = (function(xml, url) {",
                        "var desc; try { desc = (function(xml, url) { " + DESC_FIX, 1)
    L[j] = L[j].replace("et.parse(xml)", "et.parse(fixXmlDesc(xml))", 1)
    L[k] = L[k].replace("})(body, self.url);",
                        '})(body, self.url); } catch (e) { e.code = "EUPNP", '
                        'console.error("[patch] unreadable device description XML:", e && e.message); return callback(e); }', 1)
    changed.append("17b"); print("patch 17b: applied (lines %d-%d)" % (i+1, k+1))

# c) service description: same treatment
if any("fixXmlSvc" in l for l in L): print("patch 17c: present")
else:
    SVC_FIX = FIX.replace("var fixXml", "var fixXmlSvc").replace("fixXml(", "fixXmlSvc(")
    i = one(lambda l: l.strip() == "var desc = (function(xml) {", "patch 17c open")
    j = one(lambda l: l.strip().startswith("var doc = et.parse(xml), desc = {"), "patch 17c parse")
    k = one(lambda l: l.strip() == "})(body);", "patch 17c close")
    assert i < j < k, (i, j, k)
    L[i] = L[i].replace("var desc = (function(xml) {",
                        "var desc; try { desc = (function(xml) { " + SVC_FIX, 1)
    L[j] = L[j].replace("et.parse(xml)", "et.parse(fixXmlSvc(xml))", 1)
    L[k] = L[k].replace("})(body);",
                        '})(body); } catch (e) { e.code = "EUPNP", '
                        'console.error("[patch] unreadable service description XML:", e && e.message); return callback(e); }', 1)
    changed.append("17c"); print("patch 17c: applied (lines %d-%d)" % (i+1, k+1))

if changed and not dry:
    open(p, "w", encoding="utf-8").write("\n".join(L)); print("written:", p)
elif changed: print("DRY: patches %s NOT written" % changed)
else: print("nothing to do")
PY
}

# Pass 1: detect. A run with nothing to do must not restart Stremio.
check_syntax() { [ -n "$NODE" ] && "$NODE" --check "$S" || { echo "(no node found, syntax not checked)"; return 0; }; }
OUT=$(run_patch "$S" dry); echo "$OUT"
if ! echo "$OUT" | grep -q "applied"; then check_syntax && echo "syntax OK"; exit 0; fi
[ -n "$DRY" ] && { check_syntax && echo "syntax OK (dry run, nothing written)"; exit 0; }
if [ -z "$LIVE" ]; then   # copy mode: write to the copy, do not touch the app
  run_patch "$S" "" | grep -v "^patch" || true
  check_syntax && echo "syntax OK (copy mode, app untouched)"; exit 0
fi

# Pass 2: live apply.
BK=$DIR/backups/$(date +%Y-%m-%d_%H%M%S)
if [ -n "$APP" ]; then
  osascript -e 'tell application "Stremio" to quit' 2>/dev/null || true; sleep 2
  pkill -f "Stremio.app/Contents/MacOS" 2>/dev/null || true
else
  pkill -f "server\.js" 2>/dev/null || true
  echo "Stremio stopped (close it yourself if it is still running)."
fi
mkdir -p "$BK"; cp -p "$S" "$BK/server.js.orig"
[ -n "$APP" ] && [ -d "$APP/Contents/_CodeSignature" ] && cp -Rp "$APP/Contents/_CodeSignature" "$BK/"
run_patch "$S" "" | grep -v "^patch" || true
check_syntax && echo "syntax OK"
if [ -n "$APP" ] && command -v codesign >/dev/null; then
  # editing a file inside the bundle breaks the code signature seal, so re-sign
  # ad hoc; entitlements and the hardened-runtime flag are preserved
  codesign --force --sign - --preserve-metadata=entitlements,flags,identifier "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  open -a "$APP"
else
  echo "Start Stremio again to pick up the changes."
fi
echo "done, backup in $BK"
