/* Which stream of the same episode suits this TV best.
 *
 * Reads what add-ons put in a stream's name and title (Torrentio, TPB+ and the like
 * write resolution, codec, seeders and size there) and scores each one for a TV:
 * a stream the TV can play without re-encoding wins over one it cannot, then enough
 * peers to keep up, then the highest resolution the TV shows, and finally a size the
 * swarm can deliver in real time. Pure functions, for the cast remote and for tests.
 */
(function (root, factory) {
    if (typeof module === 'object' && module.exports) module.exports = factory();
    else root.CastSources = factory();
}(typeof self !== 'undefined' ? self : this, function () {
    function text(s) { return [s.name, s.title, s.description, s.behaviorHints && s.behaviorHints.filename].filter(Boolean).join(' '); }

    function parse(s) {
        var t = text(s), lo = t.toLowerCase();
        var res = /2160p|\b4k\b|uhd/.test(lo) ? 2160 : /1080p/.test(lo) ? 1080 : /720p/.test(lo) ? 720 : /480p|\bsd\b/.test(lo) ? 480 : 0;
        var codec = /x265|hevc|h\.?265/.test(lo) ? 'hevc' : /x264|avc|h\.?264/.test(lo) ? 'h264' : /av1/.test(lo) ? 'av1' : '';
        var seeds = 0, m = t.match(/👤\s*([\d.,]+)/) || lo.match(/(\d+)\s*(?:seeders|seeds|peers)/);
        if (m) seeds = parseInt(String(m[1]).replace(/[.,]/g, ''), 10) || 0;
        var bytes = 0, z = t.match(/💾\s*([\d.,]+)\s*(gb|mb)/i) || t.match(/([\d.,]+)\s*(gb|mb)\b/i);
        if (z) bytes = parseFloat(z[1].replace(',', '.')) * (z[2].toLowerCase() === 'gb' ? 1e9 : 1e6);
        return { res: res, codec: codec, seeds: seeds, bytes: bytes, hdr: /\bhdr|dolby.?vision|\bdv\b/.test(lo) };
    }

    /* tv: { hevc: bool, maxRes: number }; durationS: length of the episode */
    function score(s, tv, durationS) {
        var p = parse(s), out = 0;
        var native = p.codec === 'h264' || (p.codec === 'hevc' && tv.hevc);
        if (native) out += 1000;
        if (p.seeds >= 20) out += 300; else out += p.seeds * 15;
        out += Math.min(p.res || 720, tv.maxRes || 1080) / 10;
        if (p.res > (tv.maxRes || 1080)) out -= 50;            // more pixels than the TV shows
        if (p.hdr && !tv.hdr) out -= 100;                        // would need tonemapping
        if (p.bytes && durationS) {
            var mbit = p.bytes * 8 / durationS / 1e6;
            if (mbit > 25) out -= 200;                           // more than a typical swarm keeps up with
        }
        return { score: out, native: native, parsed: p };
    }

    function pick(streams, tv, durationS) {
        return streams.map(function (s, i) { var r = score(s, tv, durationS); r.index = i; r.stream = s; return r; })
            .sort(function (a, b) { return b.score - a.score; });
    }

    return { parse: parse, score: score, pick: pick };
}));
