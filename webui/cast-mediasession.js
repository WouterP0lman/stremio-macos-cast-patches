/* The Mac's media keys and Now Playing for a cast.
 *
 * While a cast runs, the page claims the media session: the play/pause key, the
 * Control Center player and AirPods gestures then reach the TV instead of the
 * player that is not showing anything. Pure wrapper around navigator.mediaSession,
 * so it can be tested with a stand-in navigator.
 */
(function (root, factory) {
    if (typeof module === 'object' && module.exports) module.exports = factory();
    else root.CastMediaSession = factory();
}(typeof self !== 'undefined' ? self : this, function () {
    var ACTIONS = ['play', 'pause', 'seekbackward', 'seekforward', 'seekto', 'stop'];

    function install(nav, h) {
        var ms = nav && nav.mediaSession; if (!ms) return false;
        ACTIONS.forEach(function (a) {
            try { ms.setActionHandler(a, h[a] ? function (d) { h[a](d || {}); } : null); } catch (e) { /* not every action exists everywhere */ }
        });
        return true;
    }

    function update(nav, s, Meta) {
        var ms = nav && nav.mediaSession; if (!ms) return;
        if (s.title && (!ms.metadata || ms.metadata.title !== s.title) && Meta) ms.metadata = new Meta({ title: s.title, artist: 'Casting to ' + (s.device || 'TV') });
        ms.playbackState = s.paused ? 'paused' : 'playing';
        if (ms.setPositionState && s.length > 0) {
            try { ms.setPositionState({ duration: s.length / 1000, position: Math.min(s.length, Math.max(0, s.time || 0)) / 1000, playbackRate: 1 }); } catch (e) {}
        }
    }

    function clear(nav) {
        var ms = nav && nav.mediaSession; if (!ms) return;
        ACTIONS.forEach(function (a) { try { ms.setActionHandler(a, null); } catch (e) {} });
        ms.playbackState = 'none';
    }

    return { ACTIONS: ACTIONS, install: install, update: update, clear: clear };
}));
