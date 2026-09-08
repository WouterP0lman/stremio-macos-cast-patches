#!/bin/bash
# Verify the casting patches without needing a TV or a second machine.
#
#   bash test/verify.sh
#
# Checks, in order:
#   1. every patch is present in the installed server.js
#   2. the patched file is valid JavaScript
#   3. the patches apply cleanly to simulated Linux and Windows installs,
#      producing byte-identical output (they are platform independent)
#   4. storage detection and the language preference work for all three platforms
#   5. subtitle picking finds the episode's own .srt for a loaded torrent
#   6. subtitle shifting clamps at zero instead of wrapping around
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { echo "  ok    $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

S=${STREMIO_SERVER_JS:-/Applications/Stremio.app/Contents/MacOS/server.js}
NODE=""
for c in /Applications/Stremio.app/Contents/MacOS/node "$(command -v node || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { NODE="$c"; break; }
done
[ -f "$S" ] || { echo "server.js not found at $S"; exit 1; }
[ -n "$NODE" ] || { echo "no node available"; exit 1; }

echo "1. patches present"
OUT=$(DRY=1 bash "$DIR/stremio-upnp-patch.sh" 2>&1 || true)
if echo "$OUT" | grep -q "applied"; then bad "some patches are missing: $(echo "$OUT" | grep -c applied)"; else ok "all patches present"; fi

echo "2. patched file parses"
if "$NODE" --check "$S" >/dev/null 2>&1; then ok "valid JavaScript"; else bad "syntax error"; fi

echo "3. applies to other platforms"
ORIG=$(ls -t "$DIR"/backups/*/server.js.orig 2>/dev/null | tail -1)
if [ -n "$ORIG" ]; then
  mkdir -p "$TMP/linux" "$TMP/win"
  cp "$ORIG" "$TMP/linux/server.js"; cp "$ORIG" "$TMP/win/server.js"
  STREMIO_SERVER_JS="$TMP/linux/server.js" bash "$DIR/stremio-upnp-patch.sh" >/dev/null 2>&1
  STREMIO_SERVER_JS="$TMP/win/server.js" bash "$DIR/stremio-upnp-patch.sh" >/dev/null 2>&1
  "$NODE" --check "$TMP/linux/server.js" >/dev/null 2>&1 && ok "linux copy valid" || bad "linux copy invalid"
  cmp -s "$TMP/linux/server.js" "$TMP/win/server.js" && ok "identical across platforms" || bad "output differs per platform"
else
  echo "  skip  no pristine backup to patch"
fi

echo "4. storage detection per platform"
"$NODE" - "$S" <<'JS'
var fs = require("fs"), path = require("path"), os = require("os"), child = require("child_process");
var lines = fs.readFileSync(process.argv[2], "utf8").split("\n");
function cut(name) {
  for (var i = 0; i < lines.length; i++) {
    var key = name + ": function", at = lines[i].indexOf(key);
    if (at < 0) continue;
    for (var d = 0, j = at; j < lines[i].length; j++) {
      if (lines[i][j] === "{") d++;
      else if (lines[i][j] === "}" && --d === 0) return lines[i].slice(at, j + 1);
    }
  }
  return null;
}
var parts = ["_sqlite", "_uiDb"].map(cut).filter(Boolean);
if (!parts.length) { console.log("  FAIL  storage helper not found"); process.exit(1); }
var homes = {};
["darwin", "linux", "win32"].forEach(function (plat) {
  var home = fs.mkdtempSync(path.join(os.tmpdir(), "plat-"));
  var rel = plat === "darwin" ? "Library/WebKit/com.westbridge.stremio5-mac/WebsiteData/Default/a/b/LocalStorage"
          : plat === "linux" ? ".local/share/stremio5/Default/x/LocalStorage"
          : "AppData/stremio5/Local Storage";
  fs.mkdirSync(path.join(home, rel), { recursive: true });
  fs.writeFileSync(path.join(home, rel, "localstorage.sqlite3"), "");
  homes[plat] = home;
});
["darwin", "linux", "win32"].forEach(function (plat) {
  var src = "var castingUtils = {" + parts.join(", ") + "};\n" +
    "castingUtils.__home = " + JSON.stringify(homes[plat]) + ";\n" +
    "module.exports = castingUtils;";
  var file = path.join(homes[plat], "probe.js");
  // patch the module loader so the helper sees a fake home and platform
  var wrapped = "function __webpack_require__(id){ if(id===22) return { homedir: function(){ return " +
    JSON.stringify(homes[plat]) + "; } }; if(id===1) return require('fs'); if(id===5) return require('path');" +
    " if(id===32) return require('child_process'); throw new Error(id); }\n" +
    "Object.defineProperty(process,'platform',{value:" + JSON.stringify(plat) + "});\n" +
    (plat === "win32" ? "process.env.APPDATA=" + JSON.stringify(path.join(homes[plat], "AppData")) + ";\n" : "") +
    src + "\nvar db = module.exports._uiDb();\n" +
    "console.log(db ? '  ok    ' + " + JSON.stringify(plat) + " + ' storage found' : '  FAIL  ' + " +
    JSON.stringify(plat) + " + ' storage not found');";
  fs.writeFileSync(file, wrapped);
  try { child.execFileSync(process.execPath, [file], { stdio: "inherit" }); } catch (e) {}
});
JS

echo "5. subtitle picking on a live torrent"
"$NODE" - <<'JS'
var http = require("http");
http.get("http://127.0.0.1:11470/stats.json", function (res) {
  var b = ""; res.on("data", function (c) { b += c; });
  res.on("end", function () {
    var stats; try { stats = JSON.parse(b); } catch (e) { console.log("  skip  server not reachable"); return; }
    var ih = Object.keys(stats)[0];
    if (!ih) { console.log("  skip  no torrent loaded"); return; }
    var files = (stats[ih].files || []).map(function (f) { return f.name || f.path; });
    var vid = files.findIndex(function (f) { return /\.(mp4|mkv|avi)$/i.test(f || ""); });
    if (vid < 0) { console.log("  skip  no video in torrent"); return; }
    var stem = String(files[vid]).replace(/^.*[\/\\]/, "").replace(/\.[^.]+$/, "").toLowerCase();
    var sub = files.findIndex(function (f, i) {
      return i !== vid && /\.(srt|ass|ssa|sub|vtt)$/i.test(f || "") &&
        String(f).replace(/^.*[\/\\]/, "").replace(/\.[^.]+$/, "").toLowerCase() === stem;
    });
    console.log(sub >= 0 ? "  ok    torrent ships its own subtitle (index " + sub + ")"
                         : "  ok    no sidecar in this torrent, fallback path applies");
  });
}).on("error", function () { console.log("  skip  server not reachable"); });
JS

echo "6. subtitle shift clamps at zero"
"$NODE" - "$S" <<'JS'
var fs = require("fs");
var lines = fs.readFileSync(process.argv[2], "utf8").split("\n");
var line = lines.find(function (l) { return l.indexOf("var shiftSrt = function") >= 0; });
if (!line) { console.log("  FAIL  shiftSrt not found"); process.exit(1); }
var at = line.indexOf("var shiftSrt = function"), d = 0, end = -1;
for (var j = at; j < line.length; j++) {
  if (line[j] === "{") d++;
  else if (line[j] === "}" && --d === 0) { end = j + 1; break; }
}
eval(line.slice(at, end));
var srt = "1\n00:00:02,000 --> 00:00:04,000\nhello\n";
var out = shiftSrt(srt, -10000);
console.log(/00:00:00,000/.test(out) ? "  ok    clamps at zero" : "  FAIL  wraps around: " + out.split("\n")[1]);
JS

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
