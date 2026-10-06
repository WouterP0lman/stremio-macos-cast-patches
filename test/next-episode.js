// Next episode at the end of a cast: file choice in season packs and the remote's countdown.
const fs = require("fs"), path = require("path"), N = require("../webui/cast-nextup.js");
const checks = []; const ok = (w, c) => checks.push([w, !!c]);
const pack = [
  "Game.of.Thrones.S06.1080p/Game.of.Thrones.S06E01.The.Red.Woman.1080p.mkv",
  "Game.of.Thrones.S06.1080p/Game.of.Thrones.S06E02.Home.1080p.mkv",
  "Game.of.Thrones.S06.1080p/Sample/Game.of.Thrones.S06E05.sample.mkv",
  "Game.of.Thrones.S06.1080p/Game.of.Thrones.S06E04.Book.of.the.Stranger.1080p.mkv",
  "Game.of.Thrones.S06.1080p/Game.of.Thrones.S06E05.The.Door.1080p.mkv",
  "Game.of.Thrones.S06.1080p/Game.of.Thrones.S06E05.The.Door.1080p.srt",
  "Game.of.Thrones.S06.1080p/Game.of.Thrones.S06E03.Oathbreaker.1080p.mkv",
  "Game.of.Thrones.S06.1080p/info.nfo",
].map((name) => ({ name }));
ok("reads season and episode", JSON.stringify(N.episodeOf(pack[3].name)) === '{"season":6,"episode":4}' && N.episodeOf("GoT.6x09.mkv").episode === 9);
ok("after E04 comes E05, not its sample or subtitle", N.nextInPack(pack, 3) === 4);
ok("files out of order still give the right next one (E02 -> E03)", N.nextInPack(pack, 1) === 6);
const multi = pack.concat([{ name: "S07/Game.of.Thrones.S07E01.Dragonstone.mkv" }, { name: "S07/Game.of.Thrones.S07E02.mkv" }]);
ok("last of a season goes to the next season's first", N.nextInPack(multi, 4) === multi.length - 2);
ok("nothing after the last episode", N.nextInPack(pack, 4) === -1);
ok("end: within 15 s of the length", N.atEnd({ source: "x", length: 3520000, time: 3510000 }) && !N.atEnd({ source: "x", length: 3520000, time: 3000000 }));
ok("end: stopped past 95 %", N.atEnd({ source: "x", length: 3520000, time: 3400000, stopped: true }));
ok("no advance without a cast or for short clips", !N.atEnd({ length: 3520000, time: 3519000 }) && !N.atEnd({ source: "x", length: 30000, time: 29000 }));
const remote = fs.readFileSync(path.join(__dirname, "..", "webui", "cast-remote.js"), "utf8");
ok("the remote counts down, can cancel, then casts the next file", /syncNextUp\(\)/.test(remote) && /cancelNext/.test(remote) && /nextInPack/.test(remote) && /command\(\{ source: SERVER/.test(remote));
const inst = fs.readFileSync(path.join(__dirname, "..", "stremio-upnp-patch.sh"), "utf8");
ok("the installer ships cast-nextup.js with the remote", inst.indexOf('"$DIR/webui/cast-nextup.js"') >= 0);
let bad = 0; for (const [w, c] of checks) { console.error((c ? "ok   " : "FAIL ") + w); if (!c) bad++; }
console.log(bad); process.exit(bad ? 1 : 0);
