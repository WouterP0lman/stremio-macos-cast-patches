/* Put a subtitle in step with the speech in a film.
 *
 * ffmpeg's silencedetect marks where the audio is quiet; everything else counts as
 * speech. Each candidate correction (an offset, optionally with the 25 to 23.976
 * frame-rate ratio that a subtitle made for another release often carries) is
 * scored by how much subtitle time lands on speech. The best one is returned with a
 * confidence; a caller applies it only when that confidence is high, and never to a
 * subtitle that matched the file by hash.
 */
const cp = require("child_process");

function speech(ffmpeg, media, seconds, cb) {
    const args = ["-hide_banner", "-nostats", "-t", String(seconds || 300), "-i", media, "-vn",
                  "-af", "highpass=f=200,lowpass=f=3000,silencedetect=noise=-35dB:d=0.35", "-f", "null", "-"];
    cp.execFile(ffmpeg, args, { maxBuffer: 1 << 24 }, (err, out, errOut) => {
        const quiet = []; let start = null;
        String(errOut).split("\n").forEach((l) => {
            let m = l.match(/silence_start: (-?[\d.]+)/); if (m) start = Math.max(0, parseFloat(m[1]));
            m = l.match(/silence_end: ([\d.]+)/); if (m && start !== null) { quiet.push([start, parseFloat(m[1])]); start = null; }
        });
        if (start !== null) quiet.push([start, seconds || 300]);
        const active = []; let t = 0;
        quiet.forEach(([a, b]) => { if (a > t) active.push([t, a]); t = b; });
        if (t < (seconds || 300)) active.push([t, seconds || 300]);
        cb(null, active);
    });
}

function parseSrt(text) {
    const toS = (h, m, s, ms) => +h * 3600 + +m * 60 + +s + +ms / 1000;
    const cues = [], re = /(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)/g;
    let m; while ((m = re.exec(text))) cues.push([toS(m[1], m[2], m[3], m[4]), toS(m[5], m[6], m[7], m[8])]);
    return cues;
}

function overlap(cues, active, offset, ratio, horizon) {
    let hit = 0, total = 0, j = 0;
    for (const [a0, b0] of cues) {
        const a = a0 * ratio + offset, b = b0 * ratio + offset;
        if (b <= 0 || a >= horizon) continue;
        total += b - a;
        while (j > 0 && active[j - 1][1] > a) j--;
        for (let k = j; k < active.length && active[k][0] < b; k++) {
            const lo = Math.max(a, active[k][0]), hi = Math.min(b, active[k][1]);
            if (hi > lo) hit += hi - lo;
        }
    }
    return total ? hit / total : 0;
}

function bestShift(cues, active, horizon) {
    const ratios = [1, 25 / 23.976, 23.976 / 25];
    let best = { score: -1 }, scores = [];
    for (const r of ratios) {
        for (let o = -15; o <= 15; o += 0.05) {
            const s = overlap(cues, active, o, r, horizon);
            scores.push(s);
            if (s > best.score) best = { offset: Math.round(o * 1000) / 1000, ratio: r, score: s };
        }
    }
    // refine around the best offset in 10 ms steps
    for (let o = best.offset - 0.06; o <= best.offset + 0.06; o += 0.01) {
        const s = overlap(cues, active, o, best.ratio, horizon);
        if (s > best.score) best = { offset: Math.round(o * 1000) / 1000, ratio: best.ratio, score: s };
    }
    const sorted = scores.sort((a, b) => b - a), median = sorted[Math.floor(sorted.length / 2)];
    best.confidence = best.score - median;                // how far it stands out
    best.unchanged = overlap(cues, active, 0, 1, horizon);
    return best;
}

function shiftSrt(text, offset, ratio) {
    const fmt = (t) => { t = Math.max(0, t); const h = Math.floor(t / 3600), m = Math.floor(t % 3600 / 60), s = Math.floor(t % 60), ms = Math.round((t % 1) * 1000) % 1000;
        return [h, m, s].map((x) => String(x).padStart(2, "0")).join(":") + "," + String(ms).padStart(3, "0"); };
    return text.replace(/(\d+):(\d+):(\d+)[,.](\d+)/g, (_, h, m, s, ms) => fmt((+h * 3600 + +m * 60 + +s + +ms / 1000) * ratio + offset));
}

module.exports = { speech, parseSrt, overlap, bestShift, shiftSrt };
