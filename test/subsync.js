// Subtitle sync on a clip whose speech times are known exactly. Prints failing checks.
const fs = require("fs"), path = require("path"), os = require("os"), cp = require("child_process");
const S = require("../engine/subsync.js");
const FF = "/Applications/Stremio.app/Contents/MacOS/ffmpeg", dir = path.join(os.tmpdir(), "stremio-subsync");
fs.mkdirSync(dir, { recursive: true });
// deterministic "speech": tone bursts of 0.8 to 3 s with 0.6 to 2.5 s silence between
let seed = 7; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
const cues = []; let t = 2;
while (t < 170) { const d = 0.8 + rnd() * 2.2; cues.push([t, t + d]); t += d + 0.6 + rnd() * 1.9; }
const wav = path.join(dir, "speech.wav");
if (!fs.existsSync(wav)) {
  const expr = cues.map(([a, b]) => `between(t,${a.toFixed(3)},${b.toFixed(3)})`).join("+");
  cp.execFileSync(FF, ["-v", "error", "-y", "-f", "lavfi", "-i", `aevalsrc='0.4*sin(2*PI*400*t)*(${expr})':s=48000:d=180`, wav]);
}
const fmt = (x) => { const h = Math.floor(x / 3600), m = Math.floor(x % 3600 / 60), s = Math.floor(x % 60), ms = Math.round((x % 1) * 1000) % 1000; return [h, m, s].map((v) => String(v).padStart(2, "0")).join(":") + "," + String(ms).padStart(3, "0"); };
const srt = (k, off) => cues.map(([a, b], i) => `${i + 1}\n${fmt(a / k - off)} --> ${fmt(b / k - off)}\nline ${i + 1}\n`).join("\n");
const checks = []; const ok = (w, c) => checks.push([w, !!c]);
S.speech(FF, wav, 180, (e, active) => {
  ok("speech found in the audio", active.length > 20);
  const shifted = S.bestShift(S.parseSrt(srt(1, 2.3)), active, 180);
  ok("subtitle 2.3 s early: corrected to within 150 ms (found " + shifted.offset + " s)", Math.abs(shifted.offset - 2.3) <= 0.15 && shifted.ratio === 1);
  const scaled = S.bestShift(S.parseSrt(srt(25 / 23.976, 0)), active, 180);
  ok("subtitle for a 25 fps release: frame-rate ratio found (" + scaled.ratio.toFixed(4) + ", " + scaled.offset + " s)", Math.abs(scaled.ratio - 25 / 23.976) < 1e-6 && Math.abs(scaled.offset) <= 0.15);
  const good = S.bestShift(S.parseSrt(srt(1, 0)), active, 180);
  ok("a subtitle already in step stays in step", Math.abs(good.offset) <= 0.1 && good.ratio === 1);
  ok("the correction stands out clearly (confidence)", shifted.confidence > 0.3);
  const fixed = S.shiftSrt(srt(1, 2.3), shifted.offset, shifted.ratio);
  const back = S.bestShift(S.parseSrt(fixed), active, 180);
  ok("after applying it, no further shift needed", Math.abs(back.offset) <= 0.1);
  let bad = 0; for (const [w, c] of checks) { console.error((c ? "ok   " : "FAIL ") + w); if (!c) bad++; }
  console.log(bad); process.exit(bad ? 1 : 0);
});
