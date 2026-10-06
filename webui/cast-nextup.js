/* The next episode, for a cast that reaches the end.
 *
 * Season packs hold the next episode in the same torrent, so the next file is
 * found in the torrent's own file list: same season and the next episode, or the
 * first episode of the next season. Samples and extras are skipped. The advance
 * itself waits for the end of the film and a ten-second countdown that can be
 * cancelled. Pure functions, for the cast remote and for tests.
 */
(function (root, factory) {
    if (typeof module === 'object' && module.exports) module.exports = factory();
    else root.CastNextUp = factory();
}(typeof self !== 'undefined' ? self : this, function () {
    var VIDEO = /\.(mkv|mp4|avi|m4v|mov|ts|webm)$/i;

    function episodeOf(name) {
        var n = String(name).replace(/^.*[\/\\]/, ''), m = n.match(/s(\d{1,2})[ ._-]?e(\d{1,3})/i) || n.match(/(\d{1,2})x(\d{2,3})/i);
        return m ? { season: parseInt(m[1], 10), episode: parseInt(m[2], 10) } : null;
    }

    function nextInPack(files, idx) {
        var cur = files[idx] && episodeOf(files[idx].name || files[idx].path);
        if (!cur) return -1;
        var best = -1, bestKey = null;
        files.forEach(function (f, i) {
            var name = f.name || f.path || '';
            if (i === idx || !VIDEO.test(name) || /sample|trailer|featurette/i.test(name)) return;
            var e = episodeOf(name); if (!e) return;
            var later = e.season > cur.season || (e.season === cur.season && e.episode > cur.episode);
            if (!later) return;
            var key = e.season * 1000 + e.episode;
            if (bestKey === null || key < bestKey) { bestKey = key; best = i; }
        });
        return best;
    }

    /* At the end: within 15 s of the length while playing, or stopped past 95 %. */
    function atEnd(s) {
        if (!s || !s.source || !(s.length > 60000)) return false;
        if (s.time >= s.length - 15000) return true;
        return !!s.stopped && s.time >= 0.95 * s.length;
    }

    return { episodeOf: episodeOf, nextInPack: nextInPack, atEnd: atEnd, COUNTDOWN_MS: 10000 };
}));
