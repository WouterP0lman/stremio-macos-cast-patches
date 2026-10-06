// Mac media keys reach the cast: module with a stand-in navigator, plus the served bundle.
const fs = require("fs"), path = require("path"), cp = require("child_process");
const M = require("../webui/cast-mediasession.js");
const checks = []; const ok = (w, c) => checks.push([w, !!c]);
const handlers = {}; const ms = { setActionHandler: (a, f) => { handlers[a] = f; }, setPositionState: (p) => { ms.pos = p; } };
const nav = { mediaSession: ms }, calls = [];
const h = {}; M.ACTIONS.forEach((a) => { h[a] = (d) => calls.push([a, d]); });
ok("installs a handler for every action", M.install(nav, h) && M.ACTIONS.every((a) => typeof handlers[a] === "function"));
handlers.play(); handlers.pause(); handlers.seekforward(); handlers.seekto({ seekTime: 754 });
ok("keys call the remote's play, pause and skip", calls.map((c) => c[0]).join() === "play,pause,seekforward,seekto");
ok("scrubbing in Now Playing passes the time", calls[3][1].seekTime === 754);
function Meta(o) { Object.assign(this, o); }
M.update(nav, { title: "Game of Thrones S06E04", device: "METZ 2K TV", paused: false, time: 2100000, length: 3520000 }, Meta);
ok("Now Playing shows the title and the TV", ms.metadata.title === "Game of Thrones S06E04" && /METZ/.test(ms.metadata.artist));
ok("Now Playing shows state and position", ms.playbackState === "playing" && Math.round(ms.pos.position) === 2100 && Math.round(ms.pos.duration) === 3520);
let casting = true; h.isCasting = () => casting; M.install(nav, h); calls.length = 0;
casting = false; M.clear(nav); handlers.play(); handlers.pause();
ok("after the cast the keys do nothing here and Stremio's own handlers are not wiped", calls.length === 0 && ms.playbackState === "none" && typeof handlers.play === "function");
const dir = path.join(__dirname, "..", "webui"), bundle = fs.readFileSync(path.join(dir, "cast-mediasession.js"), "utf8") + fs.readFileSync(path.join(dir, "cast-remote.js"), "utf8");
const tmp = path.join(require("os").tmpdir(), "cast-remote-bundle.js"); fs.writeFileSync(tmp, bundle);
let syntax = true; try { cp.execFileSync(process.execPath, ["--check", tmp]); } catch (e) { syntax = false; }
ok("the served bundle parses", syntax);
ok("the remote installs the keys while casting", /window\.CastMediaSession/.test(bundle) && /M\.install\(navigator/.test(bundle) && /syncMediaKeys\(\)/.test(bundle));
const inst = fs.readFileSync(path.join(__dirname, "..", "stremio-upnp-patch.sh"), "utf8");
ok("the installer ships the helper with the remote", /cat "\$DIR\/webui\/cast-mediasession\.js" "\$DIR\/webui\/cast-nextup\.js" "\$DIR\/webui\/cast-remote\.js"/.test(inst));
let bad = 0; for (const [w, c] of checks) { console.error((c ? "ok   " : "FAIL ") + w); if (!c) bad++; }
console.log(bad); process.exit(bad ? 1 : 0);
