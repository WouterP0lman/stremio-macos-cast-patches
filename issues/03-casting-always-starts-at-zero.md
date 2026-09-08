Title: Casting always restarts the video at 0, and the position the UI sends is discarded

**Stremio version:** 5.1.27 macOS (Apple silicon). Streaming server 4.21.0 (bundled), node 16.20.2.
**Devices:** LG 42LM760S-ZB (DLNA), and the same code path applies to Chromecast.

**What happens**
Start an episode in the app, watch to 6:11, then cast. The device starts at 00:00. The same
happens after every subtitle or audio-track change, because each one reloads the stream.

**The UI does its part**
The desktop UI posts the position. Captured on the server:

```
POST /casting/<devID>/player  body={"source":"http://localhost:11470/<infohash>/7?","time":369000}
```

That matches `usePlayOnDevice.ts` in stremio-web and `play_on_device` in stremio-core, which
send `{source, time}`.

**Where it is lost**
Two places in the streaming server, both in `server.js`:

1. `DLNAClient.prototype.play` (and `ChromecastClient.prototype.play`) take only `srcURL` and
   then do `this.mediaStatus.time = 0`. The dispatch in `Player.prototype.middleware` passes
   just `params.source`, so `time` never reaches `play()`:

   ```js
   isset(params.source) && (params.source ? args[method = "play"] = params.source : method = "close")
   ```

2. Even after passing it through, it is overwritten before use. `play()` awaits
   `castingUtils.getVideoInfo` (an ffmpeg probe of the torrent stream, seconds on a cold
   torrent) and only calls `delayedPlayFromStatus()` afterwards. During that window the
   still-playing previous stream keeps emitting UPnP position events, and
   `_updateStatusField("time", …)` overwrites `mediaStatus.time`. Observed concretely:
   requesting 6:11 landed the device at 18:11, the position of the previous stream.

**Fix**
Pass the position to `play()` and let it survive the probe:

```js
// dispatch
args[method = "play"] = [ params.source, params.time ]
// DLNAClient.play(srcURL, startAt) / ChromecastClient.play(srcURL, startAt)
this.mediaStatus.time = parseInt(startAt, 10) || 0
// capture before the probe, restore after it
var self = this, wantedAt = this.mediaStatus.time;
… self.mediaStatus.length = 1e3 * info.duration, self.mediaStatus.time = wantedAt, self.delayedPlayFromStatus();
```

Chromecast additionally needs `this.seekTime`, since `playFromStatus` builds its content id
from that rather than from `mediaStatus.time`.

With both in place, casting at 6:11 produces `ffmpeg -ss 371 …` and the device starts there.

**A second, related defect in the same area**
Once positions from the renderer are processed at all, they are double counted:

```js
this.mediaStatus[field] = this.seekTime + 1e3 * parseInt(value, 10);
```

The cast stream is produced with `-copyts`, so the renderer already reports absolute time.
After resuming at 14:37 the app showed 29:29 within seconds. Guarding it covers renderers
that do report from zero:

```js
this.mediaStatus[field] = (function (t, s) { return t >= s ? t : s + t; })(1e3 * parseInt(value, 10), this.seekTime || 0);
```

Related: #2731, #2732, #2733 and PR Stremio/stremio-web#1446 cover casting handoff and
subtitles, but not the start position. Patch script and evidence:
https://github.com/WouterP0lman/stremio-macos-cast-patches (patches 11, 12 and 13).
