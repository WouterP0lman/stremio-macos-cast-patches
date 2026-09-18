// The log filter (patch 29) against addresses as Stremio logs them.
//
//   node test/log-redaction.js [path/to/server.js]
//
// Loads only the first line of the given server.js, where the filter lives, so
// nothing else of the server starts. A made-up key stands in for a debrid key;
// the test fails if it survives any line, including an Error's stack.
const fs = require("fs"), path = require("path"), os = require("os");
const file = process.argv[2] || "/Applications/Stremio.app/Contents/MacOS/server.js";
const first = fs.readFileSync(file, "utf8").split("\n", 1)[0];
if (!first.includes("__redactURL")) { console.info("patch 29 is not in " + file); process.exit(1); }
const tmp = path.join(os.tmpdir(), "stremio-line1-" + process.pid + ".js");
fs.writeFileSync(tmp, first);
require(tmp);
fs.unlinkSync(tmp);
const red = global.__redactURL;
const K = "SECRETKEY123";
const cases = [
  ["Arguments -copyts -ss 205 -i https://torrentio.strem.fun/resolve/realdebrid/" + K + "/abc/null/0/file.mkv -t 300", "https://torrentio.strem.fun/… -t 300"],
  ["-> GET /casting/transcode.mp4?video=https%3A%2F%2Ftorrentio.strem.fun%2Fresolve%2Frealdebrid%2F" + K + "%2Fx&ts=1&time=205", "video=https%3A%2F%2Ftorrentio.strem.fun…&ts=1"],
  ["-> POST /casting/abc/player?source=https%3A%2F%2Fabc.download.real-debrid.com%2Fd%2F" + K + "%2Ff.mkv&time=60000", "source=https%3A%2F%2Fabc.download.real-debrid.com…&time=60000"],
  ["EngineFS server started at http://127.0.0.1:11470", "EngineFS server started at http://127.0.0.1:11470"],
  ["http://127.0.0.1:11470/0123456789abcdef0123456789abcdef01234567/3", "http://127.0.0.1:11470/0123456789abcdef0123456789abcdef01234567/3"],
  ["-> GET /hlsv2/x/video0.m3u8?mediaURL=http%3A%2F%2F127.0.0.1%3A11470%2Fsamples%2Fhevc.mkv&profile=vt", "mediaURL=http%3A%2F%2F127.0.0.1%3A11470%2Fsamples%2Fhevc.mkv&profile=vt"],
  ["http://user:" + K + "@nas.local:8096/Videos/1/stream?api_key=" + K, "http://nas.local:8096/…"],
  ["----> Using updater endpoint https://www.stremio.net", "https://www.stremio.net"],
  ["double %68 https%253A%252F%252Fevil.example%252F" + K, "https%253A%252F%252Fevil.example…"],
  ["http://127.0.0.1:11470/proxy/d=https%3A%2F%2Fapi.example%2F" + K, "d=https%3A%2F%2Fapi.example…"],
];
let fail = 0;
for (const [inp, want] of cases) {
  const out = red(inp);
  const good = out.includes(want) && !out.includes(K);
  if (!good) fail++;
  console.info((good ? "ok   " : "FAIL ") + JSON.stringify(out.replace(K, "<KEY>")));
}
// the console wrapper itself, with an Error object and a format string
const e = new Error("403 for https://x.real-debrid.com/d/" + K);
let captured = "";
const w = process.stdout.write.bind(process.stdout);
process.stdout.write = (s) => { captured += s; return true; };
console.log("%s failed", "https://torrentio.strem.fun/realdebrid=" + K + "/y");
process.stdout.write = w;
const w2 = process.stderr.write.bind(process.stderr);
let cap2 = "";
process.stderr.write = (s) => { cap2 += s; return true; };
console.error(e);
process.stderr.write = w2;
const wrapped = !captured.includes(K) && !cap2.includes(K) && captured.includes("torrentio.strem.fun") && cap2.includes("x.real-debrid.com");
if (!wrapped) fail++;
console.info((wrapped ? "ok   " : "FAIL ") + "console.log/console.error wrappers redact format strings and Error stacks");
console.info(fail ? fail + " FAILED" : "all passed");
process.exit(fail ? 1 : 0);
