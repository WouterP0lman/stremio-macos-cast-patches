#!/bin/bash
# Run the platform-dependent parts of the patches on real Linux, in a container.
#
#   bash test/linux.sh
#
# Needs Docker. It builds a Linux home directory with a Stremio-shaped
# localStorage, extracts castingUtils from the patched server.js, and runs it
# under node 16 on linux: the same node version Stremio ships.
#
# This caught two real bugs: userSubtitleLang searching only macOS paths, and
# patch 7 hardcoding Apple's aac_at encoder, which does not exist on Linux and
# made every re-encoding cast produce zero bytes.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
S=${STREMIO_SERVER_JS:-/Applications/Stremio.app/Contents/MacOS/server.js}
command -v docker >/dev/null || { echo "docker not available, skipping"; exit 0; }
docker info >/dev/null 2>&1 || { echo "docker not running, skipping"; exit 0; }
[ -f "$S" ] || { echo "server.js not found at $S"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.local/share/stremio5/Default/x/LocalStorage"
cp "$S" "$T/server.js"

python3 - "$T" <<'PY'
import sys, os, sqlite3, json
d = sys.argv[1]
db = os.path.join(d, "home/.local/share/stremio5/Default/x/LocalStorage/localstorage.sqlite3")
con = sqlite3.connect(db)
con.execute("CREATE TABLE ItemTable(key TEXT, value BLOB)")
con.execute("INSERT INTO ItemTable VALUES (?,?)",
            ("profile", json.dumps({"settings": {"subtitlesLanguage": "nld",
                                                 "subtitlesAutoSelect": True}}).encode("utf-16-le")))
con.execute("INSERT INTO ItemTable VALUES (?,?)",
            ("streams", json.dumps({"uid": "x", "items": [[{"metaId": "tt1", "videoId": "tt1:1:4"},
             {"stream": {"infoHash": "a" * 40, "fileIdx": 7}}]]}).encode("utf-16-le")))
con.commit(); con.close()

lines = open(os.path.join(d, "server.js"), encoding="utf-8").read().split("\n")
try:
    start = next(i for i, l in enumerate(lines) if "remoteSubtitle: function" in l)
    end = next(i for i, l in enumerate(lines) if i > start and "module.exports = castingUtils" in l)
except StopIteration:
    sys.exit("castingUtils not found; is server.js patched?")
head = '''
var fs = require("fs"), path = require("path"), os = require("os"), child = require("child_process");
var mime = { lookup: function () { return null; } };
function fetch() { return Promise.resolve({ json: function () { return {}; } }); }
function __webpack_require__(id) {
  if (id === 22) return os;
  if (id === 1) return fs;
  if (id === 5) return path;
  if (id === 32) return child;
  if (id === 34) return fetch;
  if (id === 68) return mime;
  if (id === 172) return { getFilename: function () { return null; } };
  if (id === 6) return require("url");
  return {};
}
var module = { exports: {} };
var castingUtils = {
'''
tail = '''
var fail = 0;
function check(label, got, want) {
  var ok = got === want;
  if (!ok) fail++;
  console.log("  " + (ok ? "ok    " : "FAIL  ") + label + ": " + got + (ok ? "" : " (expected " + want + ")"));
}
console.log("  running on " + process.platform + ", node " + process.version);
check("sqlite found", !!castingUtils._sqlite(), true);
check("storage found", !!castingUtils._uiDb(), true);
check("aac encoder choice", castingUtils.aacEncoder("ffmpeg"), "aac");
castingUtils.userSubtitleLang(function (lang) {
  check("language preference", lang, "nld");
  castingUtils.videoIdFor("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 7, function (vid) {
    check("video id lookup", vid, "tt1:1:4");
    console.log(fail ? "  " + fail + " failed" : "  all good on linux");
    process.exit(fail ? 1 : 0);
  });
});
'''
open(os.path.join(d, "harness.js"), "w").write(head + "\n".join(lines[start:end + 1]) + tail)
PY

docker run --rm -v "$T:/t" -e HOME=/t/home node:16-alpine \
  sh -c "apk add --no-cache sqlite >/dev/null 2>&1; node /t/harness.js"
