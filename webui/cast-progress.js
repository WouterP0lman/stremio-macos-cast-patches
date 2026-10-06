/* Watch progress for a cast, written back the way Stremio itself keeps it.
 *
 * Pure functions, no DOM and no network, so the same code runs in the cast remote
 * and in node for tests. The caller supplies deflate/inflate (zlib format) because
 * a browser and node offer them differently.
 *
 * Stremio's rules, as stremio-core applies them:
 *   - a library item's state carries timeOffset and duration in ms, lastWatched,
 *     video_id, and _mtime on the item; the newest _mtime wins on sync
 *   - a video counts as watched from 70 % of its duration
 *   - for a series the watched episodes live in state.watched as a bitfield:
 *     "<anchor video id>:<anchor length>:<base64 of zlib-deflated bits>", bit i is
 *     byte i>>3, mask 1 << (i & 7), over the meta's videos in their listed order;
 *     the anchor is the last watched video, so the field survives videos being
 *     added later
 * If a series has no usable anchor in the current list, the watched field is left
 * alone rather than guessed.
 */
(function (root, factory) {
    if (typeof module === 'object' && module.exports) module.exports = factory();
    else root.CastProgress = factory();
}(typeof self !== 'undefined' ? self : this, function () {
    var WATCHED_AT = 0.7;

    function b64encode(bytes) {
        if (typeof Buffer !== 'undefined') return Buffer.from(bytes).toString('base64');
        var s = ''; for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
        return btoa(s);
    }
    function b64decode(str) {
        if (typeof Buffer !== 'undefined') return new Uint8Array(Buffer.from(str, 'base64'));
        var s = atob(str), out = new Uint8Array(s.length);
        for (var i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
        return out;
    }

    /* The watched bits as an array of booleans aligned to videoIds, or null when the
     * field cannot be placed on the current list. */
    function decodeWatched(field, videoIds, inflate) {
        if (!field) return videoIds.map(function () { return false; });
        var parts = String(field).split(':');
        if (parts.length < 3) return null;
        var data = parts.pop(), anchorLen = parseInt(parts.pop(), 10), anchor = parts.join(':');
        var anchorIdx = videoIds.indexOf(anchor);
        if (anchorIdx < 0 || !(anchorLen > 0)) return null;
        var bytes = inflate(b64decode(data)), shift = anchorIdx - (anchorLen - 1);
        return videoIds.map(function (_, i) {
            var j = i - shift;
            return j >= 0 && (j >> 3) < bytes.length ? !!(bytes[j >> 3] & (1 << (j & 7))) : false;
        });
    }

    function encodeWatched(bits, videoIds, deflate) {
        var last = bits.lastIndexOf(true);
        if (last < 0) return '';
        // Stremio packs the bits of the whole list, trailing empty bytes included
        var bytes = new Uint8Array(Math.max((last >> 3) + 1, (videoIds.length + 7) >> 3));
        for (var i = 0; i <= last; i++) if (bits[i]) bytes[i >> 3] |= 1 << (i & 7);
        return videoIds[last] + ':' + (last + 1) + ':' + b64encode(deflate(bytes));
    }

    /* The item as it should be after watching videoId up to timeMs of durationMs.
     * Returns { item, watchedNow, watchedLeftAlone } and never changes the input. */
    function progressed(item, opts) {
        var next = JSON.parse(JSON.stringify(item));
        var state = next.state || (next.state = {});
        var now = new Date(opts.now || Date.now()).toISOString();
        state.timeOffset = Math.max(0, Math.round(opts.timeMs));
        state.duration = Math.max(0, Math.round(opts.durationMs));
        state.lastWatched = now;
        state.video_id = opts.videoId;
        next._mtime = now;
        next.removed = false;
        var watchedNow = opts.durationMs > 0 && opts.timeMs >= WATCHED_AT * opts.durationMs, leftAlone = false;
        if (watchedNow) {
            if (opts.videoIds && opts.videoIds.length) {
                var bits = decodeWatched(state.watched, opts.videoIds, opts.inflate);
                var idx = opts.videoIds.indexOf(opts.videoId);
                if (bits && idx >= 0) {
                    if (!bits[idx]) state.timesWatched = (state.timesWatched || 0) + 1;
                    bits[idx] = true;
                    state.watched = encodeWatched(bits, opts.videoIds, opts.deflate);
                } else leftAlone = true;
            } else {
                if (!state.flaggedWatched) state.timesWatched = (state.timesWatched || 0) + 1;
                state.flaggedWatched = 1;
            }
        }
        return { item: next, watchedNow: watchedNow, watchedLeftAlone: leftAlone };
    }

    /* The body for api.strem.io/api/datastorePut. */
    function datastorePut(authKey, item) {
        return { authKey: authKey, collection: 'libraryItem', changes: [item] };
    }

    return { WATCHED_AT: WATCHED_AT, decodeWatched: decodeWatched, encodeWatched: encodeWatched,
             progressed: progressed, datastorePut: datastorePut };
}));
