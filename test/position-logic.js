// Runs the position line straight out of the installed server.js, so what is
// tested is what casts.
//
//   node test/position-logic.js
//
// Renderers disagree about what "position" means. An LG answers with the point
// in the film; others answer with how long they have been playing. Both have to
// come out at the same place, and a renderer that has not started yet answers 0
// whichever kind it is, which is the report that must never teach anything.
var fs = require("fs");
var S = process.env.STREMIO_SERVER_JS || "/Applications/Stremio.app/Contents/MacOS/server.js";
var src = fs.readFileSync(S, "utf8");

var START = "var _t = 1e3 * parseInt(value, 10)";
var at = src.indexOf(START);
if (at < 0) { console.log("  FAIL  patch 12 is not in " + S); process.exit(1); }
var end = src.indexOf("this.mediaStatus[field] =", at);
for (var i = end, depth = 0; i < src.length; i++) {
  if (src[i] === "(") depth++;
  else if (src[i] === ")") depth--;
  else if (src[i] === ";" && depth === 0) { end = i + 1; break; }
}
var BODY = src.slice(at, end);
var run = new Function("value", "field", BODY + " return this.mediaStatus[field];");

var fail = 0;
function check(name, seek, reports, want) {
  var dev = { seekTime: seek, _absTime: undefined, mediaStatus: {} };
  var got = reports.map(function (r) { return run.call(dev, String(r), "time"); });
  var ok = got.length === want.length && got.every(function (g, i) { return g === want[i]; });
  if (!ok) fail++;
  console.log("  " + (ok ? "ok   " : "FAIL ") + name + ": " +
              got.map(function (g) { return (g / 1000) + "s"; }).join(", ") +
              (ok ? "" : " (verwacht " + want.map(function (w) { return (w / 1000) + "s"; }).join(", ") + ")"));
}

// An LG with -copyts: the stream carries the original timestamps, so the TV
// answers with the point in the film.
check("absolute tv na een sprong naar 14:37", 877000, [877, 892], [877000, 892000]);
// A renderer that counts from the start of what it was handed.
check("relatieve tv na dezelfde sprong", 877000, [15, 30], [892000, 907000]);
// What actually happened on the 42LM760S: it answers 0 while still buffering.
// Reading that as "counts from zero" put every later report 3:25 too far ahead.
check("tv meldt eerst nul, dan de echte tijd", 205000, [0, 204, 209], [205000, 204000, 209000]);
check("relatieve tv meldt eerst nul", 205000, [0, 6, 12], [205000, 211000, 217000]);
// No seek at all.
check("geen sprong", 0, [30], [30000]);
// A short seek stays a guess: under 30 seconds the two readings are too close
// to tell apart, so nothing is learned and nothing is broken.
check("korte sprong naar 5s", 5000, [10], [10000]);

console.log(fail ? "  " + fail + " mislukt" : "  PASS: elke soort renderer komt op dezelfde plek uit");
process.exit(fail ? 1 : 0);
