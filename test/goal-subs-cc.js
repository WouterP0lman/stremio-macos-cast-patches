// Chromecast subtitles: choosing a subtitle must reach the TV as an active WebVTT track.
//   node test/goal-subs-cc.js [server.js]   exit 0 = green
const fs = require("fs");
const src = fs.readFileSync(process.argv[2] || "/Applications/Stremio.app/Contents/MacOS/server.js", "utf8");
function grab(name) {
  const a = src.indexOf("ChromecastClient.prototype." + name + " = function");
  if (a < 0) throw new Error("not found: " + name);
  let i = src.indexOf("{", a), d = 0, j = i;
  for (; j < src.length; j++) { if (src[j] === "{") d++; else if (src[j] === "}" && --d === 0) break; }
  return src.slice(src.indexOf("function", a), j + 1);
}
const querystring = require("querystring");
const P = {};
for (const n of ["_subsPrepare", "playFromStatus", "subtitles"]) P[n] = eval("(" + grab(n) + ")");
let sent = [];
const cc = Object.assign(Object.create(P), {
  endpoint: "http://192.168.5.4:11470", transcodeURL: "http://192.168.5.4:11470/casting/x/transcode",
  audio: { currentTrack: "0:1" }, seekTime: 2024,
  mediaStatus: { source: "http://localhost:11470/abc/3", time: 2100000, length: 3520100, subtitlesSize: 2 },
  _mediaRequest(m) { sent.push(m); return Promise.resolve({}); },
});
cc.subtitles("https://subs.example/en.srt", 0, {});
const load = sent.find((m) => m.type === "LOAD");
const t = load && load.media.tracks && load.media.tracks[0];
const checks = [
  ["subtitle choice restarts the stream with a LOAD", !!load],
  ["the LOAD carries the subtitle track", !!t],
  ["the track is WebVTT from /subtitles.vtt", !!t && /\/subtitles\.vtt\?from=/.test(t.trackContentId)],
  ["the track is switched on", !!load && JSON.stringify(load.activeTrackIds) === "[1]"],
  ["it resumes where the film is, not where the cast began", !!load && /time=2100/.test(load.media.contentId)],
];
let bad = 0;
for (const [what, okk] of checks) { console.log((okk ? "ok   " : "FAIL ") + what); if (!okk) bad++; }
process.exit(bad ? 1 : 0);
