// Drives the real pickSubtitle from the installed server.js against synthetic
// torrents, so the shipped selection logic is tested, not a copy of it.
//
//   node test/subtitle-pick.js
//
// Stubs the two things it reaches outside itself: EngineFS (file names) and
// the online fallback. Everything else is the code that runs when you cast.
var fs = require("fs");
var S = process.env.STREMIO_SERVER_JS || "/Applications/Stremio.app/Contents/MacOS/server.js";
var src = fs.readFileSync(S, "utf8");

function extract(name) {
  var at = src.indexOf(name + ": function ");
  if (at < 0) throw new Error(name + " not found in " + S);
  var open = src.indexOf("{", src.indexOf(")", at));
  for (var i = open, d = 0; i < src.length; i++) {
    if (src[i] === "{") d++;
    else if (src[i] === "}" && --d === 0) return src.slice(at + name.length + 2, i + 1);
  }
  throw new Error("unbalanced braces around " + name);
}

var IH = "0123456789abcdef0123456789abcdef01234567";
var files, lang, mode, remoteCalled;
var castingUtils = {
  _castSubs: function () { return mode; },
  userSubtitleLang: function (cb) { cb(lang); },
  remoteSubtitle: function (ih, idx, l, resolve) { remoteCalled = String(l); resolve({ remote: true }); }
};
var __webpack_require__ = function () {
  return { getFilename: function (ih, i) { return ih === IH ? (files[i] || null) : null; } };
};
castingUtils.pickSubtitle = eval("(" + extract("pickSubtitle") + ")");

function run(t) {
  files = t.files; lang = t.lang || null; mode = t.mode || "auto"; remoteCalled = null;
  return castingUtils.pickSubtitle("http://127.0.0.1:11470/" + IH + "/" + t.idx)
    .then(function (got) {
      var actual = got && got.remote ? "online(" + remoteCalled + ")"
                 : got ? String(got.index) : "null";
      var okk = actual === String(t.want);
      console.log((okk ? "  ok   " : "  FAIL ") + t.name + ": " + actual + " (verwacht " + t.want + ")");
      return okk;
    });
}

var E4 = "Landman.S01E04.1080p.AMZN-[y2flix.cc].mp4";
var CASES = [
  { name: "eigen srt naast de aflevering", idx: 0, want: 1,
    files: [E4, E4.replace(/mp4$/, "srt")] },
  { name: "srt van een andere aflevering telt niet", idx: 0, want: "online(null)",
    files: [E4, "Landman.S01E03.1080p.AMZN-[y2flix.cc].srt"] },
  { name: "nederlands gekozen uit meerdere talen", idx: 0, want: 2, lang: "nld",
    files: [E4, E4.replace(/mp4$/, "eng.srt"), E4.replace(/mp4$/, "nl.srt")] },
  { name: "engels gekozen uit dezelfde set", idx: 0, want: 1, lang: "eng",
    files: [E4, E4.replace(/mp4$/, "eng.srt"), E4.replace(/mp4$/, "nl.srt")] },
  { name: "onbekende taal valt terug op de eerste", idx: 0, want: 1, lang: "swe",
    files: [E4, E4.replace(/mp4$/, "eng.srt"), E4.replace(/mp4$/, "nl.srt")] },
  { name: "juiste aflevering uit een seizoenspak", idx: 3, want: 7,
    files: ["Landman.S01E01.mp4", "Landman.S01E02.mp4", "Landman.S01E03.mp4", "Landman.S01E04.mp4",
            "Landman.S01E01.srt", "Landman.S01E02.srt", "Landman.S01E03.srt", "Landman.S01E04.srt"] },
  { name: "geen srt, alleen lokaal toegestaan", idx: 0, want: "null", mode: "local",
    files: [E4] },
  { name: "geen srt, online mag: nederlands gevraagd", idx: 0, want: "online(nld)", lang: "nld",
    files: [E4] },
  { name: "uitgezet betekent geen ondertiteling", idx: 0, want: "null", mode: "off",
    files: [E4, E4.replace(/mp4$/, "srt")] }
];

CASES.reduce(function (p, t) {
  return p.then(function (all) { return run(t).then(function (r) { return all && r; }); });
}, Promise.resolve(true)).then(function (all) {
  console.log(all ? "  PASS: ondertitelkeuze klopt in alle gevallen"
                  : "  FAIL: ondertitelkeuze wijkt af");
  process.exit(all ? 0 : 1);
});
