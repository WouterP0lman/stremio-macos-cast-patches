// Watch progress written back, dry: against a fake API on this Mac, never api.strem.io.
const zlib = require("zlib"), http = require("http");
const P = require("../webui/cast-progress.js");
const inflate = (b) => new Uint8Array(zlib.inflateSync(Buffer.from(b)));
const deflate = (b) => new Uint8Array(zlib.deflateSync(Buffer.from(b)));
const ids = Array.from({ length: 10 }, (_, i) => "tt0944947:6:" + (i + 1));
const checks = [];
const ok = (what, cond) => checks.push([what, !!cond]);

// a series with episode 1 already watched
const ep1 = P.encodeWatched([true].concat(Array(9).fill(false)), ids, deflate);
const series = { _id: "tt0944947", type: "series", _mtime: "2026-01-01T00:00:00.000Z", state: { watched: ep1, timesWatched: 1 } };

let r = P.progressed(series, { videoId: ids[3], timeMs: 600000, durationMs: 3520000, videoIds: ids, inflate, deflate, now: 1.8e12 });
ok("below 70 %: position and length written", r.item.state.timeOffset === 600000 && r.item.state.duration === 3520000);
ok("below 70 %: newer _mtime, so it wins on sync", r.item._mtime > series._mtime);
ok("below 70 %: watched field untouched", r.item.state.watched === ep1 && !r.watchedNow);

r = P.progressed(series, { videoId: ids[3], timeMs: 2700000, durationMs: 3520000, videoIds: ids, inflate, deflate, now: 1.8e12 });
const bits = P.decodeWatched(r.item.state.watched, ids, inflate);
ok("from 70 %: this episode marked watched", r.watchedNow && bits[3] === true);
ok("from 70 %: earlier episodes kept", bits[0] === true && bits.filter(Boolean).length === 2);
const again = P.progressed(r.item, { videoId: ids[3], timeMs: 3000000, durationMs: 3520000, videoIds: ids, inflate, deflate, now: 1.8e12 });
ok("watching it again does not count it twice", again.item.state.timesWatched === r.item.state.timesWatched);

const longer = ids.concat(["tt0944947:6:11"]);           // a video added later
ok("bits cover the whole list, as Stremio writes them", require("zlib").inflateSync(Buffer.from(r.item.state.watched.split(":").pop(), "base64")).length === 2)
ok("field survives the list growing", P.decodeWatched(r.item.state.watched, longer, inflate)[3] === true);
const stranger = Object.assign({}, series, { state: { watched: "tt999:3:" + ep1.split(":").pop() } });
const s2 = P.progressed(stranger, { videoId: ids[3], timeMs: 3000000, durationMs: 3520000, videoIds: ids, inflate, deflate });
ok("anchor not in the list: watched field left alone", s2.watchedLeftAlone && s2.item.state.watched === stranger.state.watched);

const movie = { _id: "tt1", type: "movie", _mtime: "2026-01-01T00:00:00.000Z", state: {} };
const m = P.progressed(movie, { videoId: "tt1", timeMs: 5000000, durationMs: 6000000, inflate, deflate });
ok("movie from 70 %: flagged watched once", m.item.state.flaggedWatched === 1 && m.item.state.timesWatched === 1);

// send it to a fake API and look at what arrived
const srv = http.createServer((req, res) => {
  let body = ""; req.on("data", (d) => (body += d)); req.on("end", () => {
    const j = JSON.parse(body);
    ok("datastorePut body: collection and one change", req.url === "/api/datastorePut" && j.collection === "libraryItem" && j.changes.length === 1);
    ok("the auth key travels in the body, not the URL", j.authKey === "FAKE-KEY" && req.url.indexOf("FAKE") < 0);
    res.end('{"result":{"success":true}}'); srv.close(); report();
  });
}).listen(0, "127.0.0.1", () => {
  const req = http.request({ host: "127.0.0.1", port: srv.address().port, path: "/api/datastorePut", method: "POST", headers: { "content-type": "application/json" } });
  req.end(JSON.stringify(P.datastorePut("FAKE-KEY", r.item)));
});
function report() {
  let bad = 0;
  for (const [w, c] of checks) { console.error((c ? "ok   " : "FAIL ") + w); if (!c) bad++; }
  console.log(bad); process.exit(bad ? 1 : 0);
}
