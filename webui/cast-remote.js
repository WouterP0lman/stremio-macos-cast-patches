/* Stremio cast remote.
 *
 * The player hands playback to a TV and then stops talking to it: pause, seek,
 * subtitles and volume all keep driving the local video, so the desktop and the
 * TV drift apart and nothing you press reaches the room you are sitting in.
 *
 * This is the missing half. The streaming server proxies the interface, so it can
 * add this to the page it serves, on the same origin, with no second process and
 * nothing to install. It watches for a cast and puts a remote on screen while one
 * is running.
 */
(function () {
    'use strict';
    if (window.__stremioCastRemote) return;
    window.__stremioCastRemote = true;

    var SERVER = location.origin;               // the server serves this page
    var DEVICE_POLL = 3000;
    var STATE_POLL = 1500;
    var SETTLE = 9000;                          // a change restarts the transcode
    var SEEK_STEPS = [-300, -30, 30, 300];

    var device = null;                          // {id, name, type}
    var state = {};
    var held = null;                            // optimistic values, with an expiry
    var subtitleOptions = null;
    var mediaName = '';
    var subtitleSourceKey = null;
    var collapsed = false;
    var scrubbing = false;

    /* ---------- talking to the server ---------- */

    function get(path) {
        return fetch(SERVER + path, { cache: 'no-store' })
            .then(function (r) { return r.ok ? r.json() : null; })
            .catch(function () { return null; });
    }

    function command(params) {
        if (!device) return Promise.resolve(null);
        var q = new URLSearchParams();
        Object.keys(params).forEach(function (k) { q.set(k, String(params[k])); });
        return fetch(SERVER + '/casting/' + device.id + '/player?' + q.toString(), { method: 'POST' })
            .catch(function () { return null; });
    }

    function hold(patch) {
        held = Object.assign({}, held || {}, patch, { until: Date.now() + SETTLE });
        Object.assign(state, patch);
        render();
    }

    /* A cast is running when the server holds a source for the device, and stops
     * being one when that source is cleared. What the renderer says about itself is
     * not usable: an LG 42LM760S answers GetTransportInfo with nothing at all, so
     * its reported state sits at STOPPED for the whole film. */
    function isCasting(s) {
        return !!(s && typeof s === 'object' && typeof s.source === 'string' && s.source);
    }

    /* ---------- watching ---------- */

    function findDevice() {
        return get('/casting').then(function (list) {
            if (!Array.isArray(list)) return null;
            var candidates = list.filter(function (d) { return d.type === 'tv' || d.type === 'chromecast'; });
            var checks = candidates.map(function (d) {
                return get('/casting/' + d.id + '/player').then(function (s) {
                    return isCasting(s) ? { device: d, state: s } : null;
                });
            });
            return Promise.all(checks).then(function (found) {
                return found.filter(Boolean)[0] || null;
            });
        });
    }

    function pollDevice() {
        findDevice().then(function (hit) {
            if (hit) {
                if (!device || device.id !== hit.device.id) {
                    device = hit.device;
                    subtitleOptions = null;
                    held = null;
                }
                apply(hit.state);
            } else if (device) {
                device = null;
                state = {};
                held = null;
                subtitleOptions = null;
                render();
            }
        }).then(function () { setTimeout(pollDevice, DEVICE_POLL); });
    }

    function pollState() {
        if (!device) return setTimeout(pollState, STATE_POLL);
        get('/casting/' + device.id + '/player').then(function (s) {
            if (s) apply(s);
        }).then(function () { setTimeout(pollState, STATE_POLL); });
    }

    function apply(s) {
        var holding = held && Date.now() < held.until;
        if (held && !holding) held = null;
        var next = {
            time: s.time, length: s.length, paused: s.paused, volume: s.volume,
            source: s.source, subtitlesSrc: s.subtitlesSrc, subtitlesDelay: s.subtitlesDelay || 0
        };
        if (holding) {
            if ('time' in held) next.time = held.time;
            if ('paused' in held) next.paused = held.paused;
            if ('subtitlesDelay' in held) next.subtitlesDelay = held.subtitlesDelay;
            if ('subtitlesSrc' in held) next.subtitlesSrc = held.subtitlesSrc;
        }
        state = next;
        if (state.source && state.source !== subtitleSourceKey) {
            subtitleSourceKey = state.source;
            subtitleOptions = null;
            mediaName = '';
            loadSubtitleOptions();
        }
        render();
    }

    /* ---------- which subtitles are on offer ---------- */

    var LANGS = {
        eng: 'English', nld: 'Nederlands', dut: 'Nederlands', nl: 'Nederlands', en: 'English',
        ger: 'Deutsch', deu: 'Deutsch', de: 'Deutsch', fre: 'Francais', fra: 'Francais', fr: 'Francais',
        spa: 'Espanol', es: 'Espanol', ita: 'Italiano', it: 'Italiano', por: 'Portugues',
        pob: 'Portugues (BR)', pt: 'Portugues', pol: 'Polski', pl: 'Polski', swe: 'Svenska',
        dan: 'Dansk', nor: 'Norsk', fin: 'Suomi', tur: 'Turkce', rus: 'Russian', ara: 'Arabic'
    };

    function langName(tag) {
        var t = String(tag || '').toLowerCase();
        return LANGS[t] || (t ? t.toUpperCase() : 'Unknown');
    }

    function stemOf(name) {
        return String(name).replace(/^.*[\/\\]/, '').replace(/\.[^.]+$/, '').toLowerCase();
    }

    /* Subtitles that came with the torrent belong to this exact release, so they
     * need no shifting. They are worth more than anything fetched afterwards. */
    function sidecarOptions(src) {
        var m = String(src).match(/\/([0-9a-f]{40})\/(\d+)/i);
        if (!m) return Promise.resolve([]);
        var ih = m[1].toLowerCase(), idx = parseInt(m[2], 10);
        return get('/stats.json').then(function (stats) {
            var entry = stats && (stats[ih] || stats[m[1]]);
            var files = (entry && entry.files) || [];
            var video = files[idx];
            if (!video) return [];
            mediaName = video.name || video.path || '';
            var want = stemOf(mediaName);
            var out = [];
            files.forEach(function (f, i) {
                var name = f.name || f.path || '';
                if (i === idx || !/\.(srt|ass|ssa|sub|vtt)$/i.test(name)) return;
                var base = stemOf(name);
                if (base !== want && base.indexOf(want + '.') !== 0) return;
                var tag = base === want ? '' : base.slice(want.length + 1);
                out.push({
                    url: SERVER + '/' + ih + '/' + i,
                    name: (tag ? langName(tag) : 'With this release') + ' (in the download)',
                    hashMatch: true
                });
            });
            return out;
        }).catch(function () { return []; });
    }

    /* The interface keeps which episode each stream belongs to, which is what
     * OpenSubtitles needs to be asked about. */
    function videoIdFor(src) {
        var m = String(src).match(/\/([0-9a-f]{40})\/(\d+)/i);
        if (!m) return null;
        var ih = m[1].toLowerCase(), idx = parseInt(m[2], 10);
        try {
            var raw = window.localStorage.getItem('streams');
            var data = raw ? JSON.parse(raw) : null;
            var items = (data && data.items) || [];
            for (var i = 0; i < items.length; i++) {
                var key = items[i][0], value = items[i][1] || {}, stream = value.stream || {};
                if (String(stream.infoHash || '').toLowerCase() === ih && stream.fileIdx === idx) {
                    return key && key.videoId;
                }
            }
        } catch (e) { /* storage can be unreadable, that is not fatal */ }
        return null;
    }

    function onlineOptions(src) {
        var videoId = videoIdFor(src);
        if (!videoId) return Promise.resolve([]);
        var kind = videoId.indexOf(':') >= 0 ? 'series' : 'movie';
        return get('/opensubHash?videoUrl=' + encodeURIComponent(src)).then(function (h) {
            var result = (h && h.result) || {};
            var extra = result.hash ? '/videoHash=' + result.hash + '&videoSize=' + result.size : '';
            return fetch('https://opensubtitles-v3.strem.io/subtitles/' + kind + '/' + videoId + extra + '.json')
                .then(function (r) { return r.json(); });
        }).then(function (d) {
            var subs = (d && d.subtitles) || [];
            var seen = {}, out = [];
            subs.forEach(function (x) {
                var lang = String(x.lang || '').toLowerCase();
                var exact = x.m === 'h';
                var key = lang + (exact ? '!' : '');
                if (seen[key] || !x.url) return;
                seen[key] = true;
                out.push({ url: x.url, name: langName(lang), hashMatch: exact });
            });
            out.sort(function (a, b) { return (b.hashMatch ? 1 : 0) - (a.hashMatch ? 1 : 0); });
            return out.slice(0, 14);
        }).catch(function () { return []; });
    }

    function loadSubtitleOptions() {
        var src = state.source;
        if (!src) return;
        Promise.all([sidecarOptions(src), onlineOptions(src)]).then(function (lists) {
            if (state.source !== src) return;
            subtitleOptions = lists[0].concat(lists[1]);
            render();
        });
    }

    /* ---------- what the buttons do ---------- */

    function togglePlay() {
        var next = !state.paused;
        hold({ paused: next });
        command({ paused: next ? 1 : 0 });
    }

    function seekTo(ms) {
        var t = Math.max(0, Math.round(ms));
        if (state.length) t = Math.min(t, state.length - 5000);
        hold({ time: t, paused: false });
        command({ time: t });
    }

    function skip(seconds) {
        seekTo((state.time || 0) + seconds * 1000);
    }

    function setVolume(v) {
        state.volume = v;
        command({ volume: v });
    }

    function setSubtitle(url) {
        hold({ subtitlesSrc: url || null });
        command({ subtitlesSrc: url || '' });
    }

    function nudgeSubtitles(ms) {
        var next = (state.subtitlesDelay || 0) + ms;
        hold({ subtitlesDelay: next });
        command({ subtitlesDelay: next });
    }

    function stopCasting() {
        command({ stop: 1 });
        device = null; state = {}; held = null;
        render();
    }

    /* ---------- the panel ---------- */

    var host = document.createElement('div');
    host.id = 'stremio-cast-remote';
    var root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;

    var CSS = [
        ':host{all:initial}',
        '*{box-sizing:border-box;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}',
        '.panel{position:fixed;right:24px;bottom:24px;width:340px;z-index:2147483000;',
        'background:rgba(23,20,40,.96);color:#fff;border:1px solid rgba(255,255,255,.14);',
        'border-radius:12px;box-shadow:0 12px 40px rgba(0,0,0,.5);padding:14px 16px;',
        'backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);user-select:none;',
        'max-height:calc(100vh - 48px);overflow:auto}',
        '.panel.collapsed{padding:10px 14px;width:auto}',
        '.head{display:flex;align-items:center;gap:8px}',
        '.dot{width:8px;height:8px;border-radius:50%;background:#7b5bf5;flex:none}',
        '.name{font-size:13px;font-weight:600;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
        '.iconbtn{background:none;border:none;color:rgba(255,255,255,.6);cursor:pointer;',
        'font-size:14px;line-height:1;padding:4px 6px;border-radius:6px}',
        '.iconbtn:hover{color:#fff;background:rgba(255,255,255,.1)}',
        '.title{font-size:12px;color:rgba(255,255,255,.55);margin:6px 0 10px;',
        'white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
        '.bar{width:100%;height:4px;-webkit-appearance:none;appearance:none;border-radius:2px;',
        'background:rgba(255,255,255,.2);outline:none;cursor:pointer}',
        '.bar::-webkit-slider-thumb{-webkit-appearance:none;width:12px;height:12px;border-radius:50%;background:#7b5bf5}',
        '.times{display:flex;justify-content:space-between;font-size:11px;',
        'color:rgba(255,255,255,.5);margin-top:5px;font-variant-numeric:tabular-nums}',
        '.row{display:flex;align-items:center;gap:6px;margin-top:10px}',
        '.row.center{justify-content:center}',
        '.btn{background:rgba(255,255,255,.08);border:none;color:#fff;cursor:pointer;',
        'border-radius:8px;padding:7px 10px;font-size:12px;min-width:44px}',
        '.btn:hover{background:rgba(255,255,255,.18)}',
        '.btn.play{background:#7b5bf5;min-width:52px;font-size:15px;padding:8px 12px}',
        '.btn.play:hover{background:#8f74f7}',
        '.label{font-size:11px;color:rgba(255,255,255,.5);min-width:26px}',
        'select{background:rgba(255,255,255,.08);color:#fff;border:none;border-radius:8px;',
        'padding:6px 8px;font-size:12px;flex:1;min-width:0;cursor:pointer}',
        'select option{background:#221d3a;color:#fff}',
        'input[type=range].vol{flex:1;height:4px;-webkit-appearance:none;appearance:none;',
        'border-radius:2px;background:rgba(255,255,255,.2);outline:none;cursor:pointer}',
        'input[type=range].vol::-webkit-slider-thumb{-webkit-appearance:none;width:10px;height:10px;',
        'border-radius:50%;background:#fff}',
        '.delay{font-variant-numeric:tabular-nums;font-size:12px;min-width:46px;text-align:center}'
    ].join('');

    var style = document.createElement('style');
    style.textContent = CSS;
    root.appendChild(style);
    var panel = document.createElement('div');
    panel.className = 'panel';
    root.appendChild(panel);

    function hms(ms) {
        if (typeof ms !== 'number' || !isFinite(ms) || ms < 0) return '--:--';
        var s = Math.floor(ms / 1000), h = Math.floor(s / 3600);
        var m = Math.floor((s % 3600) / 60), r = s % 60;
        var mm = (m < 10 && h ? '0' : '') + m, rr = (r < 10 ? '0' : '') + r;
        return (h ? h + ':' : '') + mm + ':' + rr;
    }

    /* A torrent stream is addressed by number, so the name has to come from the
     * torrent's own file list rather than from the URL. */
    function prettyTitle(source) {
        var name = mediaName;
        if (!name && source) {
            try { name = decodeURIComponent(String(source).split('?')[0].split('/').pop() || ''); }
            catch (e) { name = ''; }
        }
        if (!name || /^\d+$/.test(name)) return 'Playing from Stremio';
        return name.replace(/^.*[\/\\]/, '').replace(/\.[a-z0-9]{2,4}$/i, '').replace(/[._]/g, ' ');
    }

    function render() {
        if (!device) {
            if (host.parentNode) host.parentNode.removeChild(host);
            return;
        }
        if (!host.parentNode) document.documentElement.appendChild(host);

        if (collapsed) {
            panel.className = 'panel collapsed';
            panel.innerHTML = '';
            var h = el('div', 'head');
            h.appendChild(el('span', 'dot'));
            var n = el('span', 'name'); n.textContent = device.name; h.appendChild(n);
            h.appendChild(iconBtn('▴', 'Expand', function () { collapsed = false; render(); }));
            panel.appendChild(h);
            return;
        }

        panel.className = 'panel';
        panel.innerHTML = '';

        var head = el('div', 'head');
        head.appendChild(el('span', 'dot'));
        var nm = el('span', 'name');
        nm.textContent = 'Casting to ' + device.name;
        head.appendChild(nm);
        head.appendChild(iconBtn('▾', 'Collapse', function () { collapsed = true; render(); }));
        head.appendChild(iconBtn('✕', 'Stop casting', stopCasting));
        panel.appendChild(head);

        var title = el('div', 'title');
        title.textContent = prettyTitle(state.source);
        panel.appendChild(title);

        var bar = document.createElement('input');
        bar.type = 'range'; bar.className = 'bar';
        bar.min = 0; bar.max = Math.max(1, state.length || 1);
        bar.value = Math.min(state.time || 0, state.length || 0);
        bar.disabled = !state.length;
        bar.addEventListener('input', function () {
            scrubbing = true;
            times.firstChild.textContent = hms(Number(bar.value));
        });
        bar.addEventListener('change', function () {
            scrubbing = false;
            seekTo(Number(bar.value));
        });
        panel.appendChild(bar);

        var times = el('div', 'times');
        var left = document.createElement('span');
        left.textContent = hms(state.time);
        var right = document.createElement('span');
        right.textContent = hms(state.length);
        times.appendChild(left); times.appendChild(right);
        panel.appendChild(times);

        var controls = el('div', 'row center');
        controls.appendChild(btn('-5m', 'Back five minutes', function () { skip(SEEK_STEPS[0]); }));
        controls.appendChild(btn('-30s', 'Back thirty seconds', function () { skip(SEEK_STEPS[1]); }));
        var play = btn(state.paused ? '▶' : '❚❚', 'Play or pause', togglePlay);
        play.className = 'btn play';
        controls.appendChild(play);
        controls.appendChild(btn('+30s', 'Forward thirty seconds', function () { skip(SEEK_STEPS[2]); }));
        controls.appendChild(btn('+5m', 'Forward five minutes', function () { skip(SEEK_STEPS[3]); }));
        panel.appendChild(controls);

        var volRow = el('div', 'row');
        var volLabel = el('span', 'label'); volLabel.textContent = 'Vol';
        volRow.appendChild(volLabel);
        var vol = document.createElement('input');
        vol.type = 'range'; vol.className = 'vol'; vol.min = 0; vol.max = 1; vol.step = 0.05;
        vol.value = typeof state.volume === 'number' ? state.volume : 0.5;
        vol.addEventListener('change', function () { setVolume(Number(vol.value)); });
        volRow.appendChild(vol);
        panel.appendChild(volRow);

        var subRow = el('div', 'row');
        var subLabel = el('span', 'label'); subLabel.textContent = 'Subs';
        subRow.appendChild(subLabel);
        var sel = document.createElement('select');
        var opts = [{ url: '', name: 'Off' }].concat(subtitleOptions || []);
        var current = state.subtitlesSrc || '';
        var known = opts.some(function (o) { return o.url === current; });
        if (current && !known) opts.push({ url: current, name: 'Current subtitle' });
        opts.forEach(function (o) {
            var op = document.createElement('option');
            op.value = o.url;
            op.textContent = o.name + (o.hashMatch ? ' (exact)' : '');
            if (o.url === current) op.selected = true;
            sel.appendChild(op);
        });
        if (subtitleOptions === null) {
            var loading = document.createElement('option');
            loading.textContent = 'Looking for subtitles...';
            loading.disabled = true;
            sel.appendChild(loading);
        }
        sel.addEventListener('change', function () { setSubtitle(sel.value); });
        subRow.appendChild(sel);
        panel.appendChild(subRow);

        var delayRow = el('div', 'row');
        var dl = el('span', 'label'); dl.textContent = 'Time';
        delayRow.appendChild(dl);
        delayRow.appendChild(btn('-0.5s', 'Subtitles earlier', function () { nudgeSubtitles(-500); }));
        var dv = el('span', 'delay');
        var d = (state.subtitlesDelay || 0) / 1000;
        dv.textContent = (d > 0 ? '+' : '') + d.toFixed(1) + 's';
        delayRow.appendChild(dv);
        delayRow.appendChild(btn('+0.5s', 'Subtitles later', function () { nudgeSubtitles(500); }));
        panel.appendChild(delayRow);
    }

    function el(tag, cls) {
        var e = document.createElement(tag);
        if (cls) e.className = cls;
        return e;
    }

    function btn(text, title, onClick) {
        var b = el('button', 'btn');
        b.textContent = text;
        b.title = title;
        b.addEventListener('click', onClick);
        return b;
    }

    function iconBtn(text, title, onClick) {
        var b = el('button', 'iconbtn');
        b.textContent = text;
        b.title = title;
        b.addEventListener('click', onClick);
        return b;
    }

    pollDevice();
    pollState();
})();
