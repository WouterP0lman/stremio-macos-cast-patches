# Stremio for macOS: DLNA and Chromecast casting fixes

Two bugs in the streaming server bundled with Stremio for macOS (server.js 4.21.0, shipped with Stremio 5.1.26 and 5.1.27) break casting to a TV. This repository documents the root causes with evidence and ships a repeatable patch script.

1. **The streaming server crashes while casting over DLNA.** A TV sends a malformed UPnP event, the XML parser throws, nothing catches it, the whole node process dies. Stremio shows "Stremio server stopped. The streaming server process stopped unexpectedly" with a `strictFail / SAXParser.write / ElementTree.parse` stack. Reported upstream in 2021 and 2022 (stremio-bugs #327 and #383, both closed), still present in 2026.
2. **Every cast is sent with Vorbis audio and a needless libx264 re-encode.** The cast transcoder parses `ffmpeg -i` output with a regex written for ffmpeg 4. The bundled ffmpeg is 7.1.1, which prints `Stream #0:1[0x2](eng): Audio: ac3 ...`. The `[0x2]` block breaks the regex on every line, the stream list comes back empty, ffmpeg gets no `-map` and no `-c` arguments and falls back to the matroska muxer defaults (h264 via libx264 plus Vorbis). Most TVs cannot decode Vorbis, so they report "unsupported audio codec" or "invalid file" for every source, including plain h264 + AAC mp4 files. The audio track picker in the cast UI is empty for the same reason.

Tested on an LG 42LM760S (2012, NetCast DLNA renderer) and a Chromecast 3rd gen, from macOS 26.5.1 on Apple silicon.

## Quick start

```bash
git clone https://github.com/WouterP0lman/stremio-macos-cast-patches.git
cd stremio-macos-cast-patches
bash stremio-upnp-patch.sh          # quits Stremio, backs up, patches, re-signs, relaunches
DRY=1 bash stremio-upnp-patch.sh    # only report which patches are missing
```

A Stremio auto-update replaces the whole app bundle and removes the patches. Run the script again afterwards, or install the optional launchd watcher (see below).

## Environment where this was diagnosed

| Component | Value |
|---|---|
| macOS | 26.5.1 (25F80), Apple M4 Pro |
| Stremio | 5.1.26, auto-updated to 5.1.27 during the investigation |
| server.js | 4.21.0 (`/settings` reports `serverVersion`), bundled node v16.20.2 |
| ffmpeg | 7.1.1-Jellyfin, bundled in `Stremio.app/Contents/MacOS` |
| TV | LG 42LM760S-ZB, DLNA MediaRenderer, advertises `video/x-matroska:*`, `video/mp4:*`, MPEG-TS profiles, no Vorbis |
| Chromecast | 3rd generation (`caprica`), 1080p, no HEVC |

## Root cause 1: uncaught XML parse error in the UPnP eventing server

`DeviceClient.prototype.ensureEventingServer` (upnp-device-client, bundled) creates an HTTP server that receives NOTIFY events from the renderer and parses the body:

```js
req.pipe(concat(function (buf) {
    var sid = req.headers.sid, seq = req.headers.seq, events = (function (buf) {
        var events = [], doc = et.parse(buf.toString()), lastChange = doc.findtext(".//LastChange");
        ...
```

`et.parse` uses sax in strict mode. On a malformed body it throws synchronously inside concat-stream's `finish` handler. There is no try/catch and no `uncaughtException` handler in the bundle, so the process exits. The stack in the Stremio dialog matches this exactly (`error -> strictFail -> SAXParser.write -> XMLParser.feed -> ElementTree.parse -> ConcatStream -> finishMaybe`).

The same unguarded `et.parse` exists in `DeviceClient.prototype.callAction` for SOAP responses (Play, Stop, GetPositionInfo, GetVolume). A malformed reply kills the server the same way.

Fix (patch 1 and 3): wrap both parses in try/catch. The event handler returns an empty event list, the action handler passes the error to its callback.

## Root cause 2: `castingUtils.getVideoInfo` cannot parse ffmpeg 7 stream lines

The cast transcoder (`Casting.prototype.transcode`, served at `/casting/transcode.mp4`) decides per stream whether to copy or transcode, based on `castingUtils.getVideoInfo`, which runs `ffmpeg -i <url>` and parses stderr with:

```js
/#(\d+:\d+)(?:\((\w{3})\)|):\s(\w+):\s(\w+)(?:\s([^,]+),\s(\w+\([^)]+\)|[^,]+),\s([^,]+),\s(.*?)(?:\s(\(default\)))?$)?/m
```

ffmpeg 4 printed `Stream #0:1(eng): Audio: aac (LC) ...`. ffmpeg 7.1.1 prints `Stream #0:1[0x2](eng): Audio: ac3 ...` for mp4, mov and mpegts inputs. The `[0x2]` block is not in the regex, so every line logs `castingUtils: Cannot parse stream "..."` and `streams` is `[]`.

With no video and no audio stream found, the transcoder builds this command (captured from the live process):

```
ffmpeg -copyts -ss 0 -i http://localhost:11470/<infohash>/0? -t 3363.55 -f matroska -threads 0 pipe:1
```

No `-map`, no `-c`. `ffmpeg -h muxer=matroska` on the bundled binary: default video codec h264, default audio codec **vorbis**. ffprobe on the first 4 MB served by the endpoint, before the patch:

```
container: matroska,webm
   video | h264 High | 1920x960
   audio | vorbis    | 6 channels
   subtitle | ass
```

After the patch, same source (mp4, h264 + AC3 5.1):

```
container: matroska,webm
   video | h264 High | 1920x960     (stream copy)
   audio | aac LC    | 2 stereo     (transcoded, as the code intends)
```

Fix (patch 2): allow an optional `[...]` block after the stream index: `#(\d+:\d+)(?:\[[^\]]*\])?(?:\((\w{3})\)|)`. Capture groups are unchanged.

Patch 4 additionally makes the profile parenthetical after the codec name optional, because ffmpeg 7 prints `Audio: ac3, 48000 Hz, 5.1(side), ...` without `(profile)` for ac3, eac3, opus, vorbis and flac. Without it those tracks lose their channel layout and `(default)` flag, and the default-track selection picks the first track instead of the flagged one on multi-audio files.

## Quality: audio for DLNA TVs (patches 6 and 7)

Video is already a stream copy, so the only lossy step in a cast is audio. The handler copies audio only when it is `aac` and `stereo`; everything else is downmixed to AAC stereo. For a DLNA TV that is a needless loss: the LG's advertised MPEG-TS `_NA` profiles imply an AC-3 decoder, and 2012 LG sets play Dolby Digital inside Matroska.

Patch 6 adds an AC3 passthrough for the DLNA route only. The two cast clients use different URLs, which is what the condition keys on:

- `DLNAClient` requests `/casting/transcode.mp4` (`transcodeURL = endpoint + baseUrl + "/transcode.mp4"`)
- `ChromecastClient` requests `/casting/transcode` (no extension)

so `/\.mp4(\?|$)/i.test(req.originalUrl || req.url)` is true only for the TV. Note that `req.path` does not exist on this router (the bundle uses pillarjs/router, not full express), so the test must use `req.originalUrl`/`req.url`.

Only AC3 passes through. E-AC3, DTS, TrueHD and everything else still transcode, because the LG does not decode them.

Patch 7 replaces the fallback encoder `aac` with `aac_at` (Apple AudioToolbox) at 192 kbit/s. Measured on the same source: 129 kbit/s before, 197 kbit/s after.

Verified end to end against the running server:

| Route | Source audio | Result |
|---|---|---|
| `/casting/transcode.mp4` (TV) | AC3 5.1 | `ac3, 6ch` (copy) |
| `/casting/transcode` (Chromecast) | AC3 5.1 | `aac, 2ch` (unchanged behaviour) |
| `/casting/transcode.mp4` (TV) | E-AC3 5.1 | `aac, 2ch` (no passthrough) |

If a TV stays silent with AC3, it has no Dolby Digital decoder for this container; revert patch 6 by restoring `server.js` from `backups/` and re-running the script without it.

## Subtitles when casting to a DLNA TV (patches 8 and 9, plus cast-subs.py)

Three separate problems stack up here.

**The UI never passes the subtitle along.** `Player.prototype.middleware` (line 42214) only dispatches `subtitles` when a request carries `subtitlesSrc`, `subtitlesDelay` or `subtitlesSize`, and `DLNAClient.play` (line 89073) explicitly nulls `subtitlesSrc` when a cast starts. Reading the live cast URI off the TV with a read-only `GetMediaInfo` shows `...&audioTrack=0%3A1&time=0&subtitles=&subtitlesDelay=0`: the parameter is empty, and the running ffmpeg used `-c copy`, which per line 83053 (`copyVideo = !subtitles`) proves the server was never asked for subtitles. Picking a subtitle in the player before casting does not survive; picking one during the cast restarted the stream but still sent an empty value. `cast-subs.py` in this repo sends the request the UI should have sent.

**The timing was wrong even when it did work.** `makeSubs` was called with `Math.max(0, offset - subtitlesDelay)` and shifts the .srt with `ffmpeg -ss`, while line 83070 passes `-copyts` so the decoded frames keep their original PTS. The subtitles therefore ran ahead by roughly the seek offset, then ran out. Worse, ffmpeg cannot seek inside a subtitle stream and rebases on the previous cue, so the actual shift is quantised (measured: 18 s for a requested 20 s). Patch 8 passes offset 0, which makes the original timings line up exactly and removes an ffmpeg spawn per cast. Demonstrated: shifting produced `00:00:00,000 --> CUE AT 20 SEC` for a cue that belongs at 20 s.

**Soft subtitles are not an option on this TV.** `buildMetadata` (line 89148) already builds a complete `sec:CaptionInfo` / `sec:CaptionInfoEx` / `text/srt` sidecar block whenever `metadata.subtitlesUrl` is set, and `DLNAClient.playFromStatus` never sets it. Wiring it up is a two-line change, but the LG 42LM760S advertises no caption capability at all (no `sec:`/`pv:`/`xbmc:` namespace, no vendor service, nothing subtitle-related in its SCPDs), so it would be ignored. Burn-in, with its full libx264 re-encode, is the only route for this renderer. Chromecast already gets real soft subtitles through `_subsPrepare`.

### Patch 9: the TV's own status messages were unparseable

Capturing a real NOTIFY by subscribing to the TV's AVTransport service showed why every status event was lost. The LG echoes the cast URL back inside `LastChange` without escaping it, and appends a NUL byte:

```
...%2F5%3F&audioTrack=0%3A1&time=0&subtitles=&subtitlesDelay=0&quot;/&gt;...
                      8 unescaped & , plus a trailing \x00
```

That is the exact payload behind the crash in patch 1, and it explains the follow-on symptom: after patch 1 stopped the crash the events were merely discarded, so Stremio never learned the playback position and restarted every stream at 0. Patch 9 repairs the document (`&` that starts no valid entity becomes `&amp;`, XML-illegal control characters are dropped) before both parses, and keeps patch 1's try/catch as a backstop. Verified against the captured event: 22 fields recovered, including `TransportState`, `TransportStatus` and `CurrentTrackDuration`.

### cast-subs.py

```bash
python3 cast-subs.py tt14186672:1:3        # subtitles for a series episode
python3 cast-subs.py tt1234567 dut         # a movie, Dutch
python3 cast-subs.py --list tt14186672:1:3 # what is available
python3 cast-subs.py off                   # back to the lossless copy
```

It finds the active cast, reads the current position, fetches a track from the OpenSubtitles v3 addon, checks that Stremio's own `/subtitles.srt` endpoint can parse it, and sends `subtitlesSrc` plus the position so playback resumes where it was. Only addon subtitles work: a track embedded in the file has no URL for `/subtitles.srt?from=` to fetch.

Known limits: seeking from the TV remote is impossible (the server advertises `DLNA.ORG_OP=01` but has no `TimeSeekRange` handler, and the piped Matroska has no length or cues), and turning subtitles on replaces the lossless video copy with a libx264 ultrafast re-encode for as long as they are on.

## Tools: remote, sync and subtitles

Three scripts sit on top of the patches. They talk to the streaming server's own
casting API (`/casting`, `/casting/<device>/player`), so they work for DLNA TVs
and Chromecasts alike.

### `remote/cast-remote.py` - a remote control in your browser

```bash
python3 remote/cast-remote.py     # then open http://localhost:11471
```

Seek by 10s/30s/1m/5m or scrub to any point, pause, volume, stop. Subtitles with
a language picker (it identifies what is playing through Cinemeta and lists what
OpenSubtitles has) and earlier/later timing in half-second steps. It polls the
device every two seconds and pauses polling right after a command, because every
change restarts the stream.

### `remote/cast-sync.py` - start where you left off, with subtitles

Casting always begins at 0 with no subtitles: `DLNAClient.play` (line 89073)
resets `time` and `subtitlesSrc`, and the UI never sends either. But Stremio does
store your position, in the web UI's localStorage under `library_recent`:

```json
{"video_id": "tt14186672:1:3", "timeOffset": 1554247, "duration": 3268932}
```

This reads that file, matches the streaming file name to the library entry
(title plus SxxExx), and applies the position and a subtitle track to the cast.
When the episode has no stored position yet it still derives the video id from
the show's IMDb id and the file name, so subtitles work on a fresh episode.

```bash
python3 remote/cast-sync.py            # watch, fix every new cast automatically
python3 remote/cast-sync.py --once     # fix the cast running now
python3 remote/cast-sync.py --dry      # show what it would do
python3 remote/cast-sync.py --lang dut # another language
python3 remote/cast-sync.py --no-subs  # position only
```

Stremio writes that position every few minutes rather than continuously, so it
can lag a couple of minutes behind what is on screen.

### `cast-subs.py` - subtitles and position by hand

```bash
python3 cast-subs.py tt14186672:1:3        # subtitles for an episode
python3 cast-subs.py --at 24:01            # jump to a position
python3 cast-subs.py off                   # subtitles off
```

### One thing to know about combining commands

Setting subtitles and a position in a single request does not stick. The
subtitle change restarts the stream, and during that restart Stremio accepts the
device's own position again (which patch 9 made possible), overwriting the
requested one. Send them as two commands a few seconds apart; `cast-sync.py`
already does that.

## Smaller findings

- `-vbsf` was removed in ffmpeg 7. The legacy HLSv1 DLNA MPEG-TS route (`segmentApi.DLNAMpegTtsMiddleware`) passes `-vbsf h264_mp4toannexb` and exits with code 8. Not on the Stremio 5 cast path. Patch 5 changes it to `-bsf:v`.
- `videoApi.probeVideo` (HLSv1) has a second stderr parser. It still finds the stream index with ffmpeg 7 but loses the language tag on `[0x..]` lines. Cosmetic, not patched.
- The eventing server never answers NOTIFY requests with HTTP 200 (`res.end()` is never called). Pre-existing, not patched.
- The DLNA path advertises and serves `video/x-mkv`, the LG only lists `video/x-matroska:*`. The TV tolerates it. Not patched.
- Language tags that are not exactly three word characters (`(en)`, `(pt-BR)`) still fail the regex. ffmpeg 7.1.1 prints ISO 639-2 codes for Matroska and mp4, so this only affects unusual files.

## What the script changes

All edits are anchored on unique strings, not line numbers, and verified with `node --check`. Line numbers below are for server.js 4.21.0 as shipped with Stremio 5.1.27.

| # | Location | Change |
|---|---|---|
| 1 | `ensureEventingServer`, line 89492 | `try { ... } catch (e) { console.error(...); return []; }` around the event parse |
| 2 | `castingUtils.getVideoInfo`, line 22675 | regex accepts `[0x..]` after the stream index |
| 3 | `DeviceClient.callAction`, line 89388 | try/catch around the SOAP response parse, null-safe `errorDescription` |
| 4 | `castingUtils.getVideoInfo`, line 22675 | profile parenthetical after the codec name is optional |
| 5 | `segmentMiddlewareArgs.video.getFilter`, lines 62954 and 62955 | `-vbsf` becomes `-bsf:v` |
| 6 | `Casting.prototype.transcode`, line 83062 | DLNA route keeps AC3 as is (stream copy) instead of downmixing to AAC stereo |
| 7 | `Casting.prototype.transcode`, line 83073 | AAC fallback uses `aac_at` (AudioToolbox) at 192 kbit/s instead of native `aac` at ~128 |
| 8 | `Casting.prototype.transcode`, line 83039 | do not pre-shift the .srt; with `-copyts` the frames keep their original PTS, so shifting desynced burned-in subtitles |
| 9 | `ensureEventingServer`, lines 89491-89493 | repair the TV's malformed event XML instead of discarding it, restoring transport state updates |
| 10 | `Casting.prototype.makeSubs`, lines 83000-83015 | shift the .srt text in JS instead of `ffmpeg -ss`, so subtitle delay (earlier/later) actually works |

Editing a file inside the bundle breaks the code signature seal. The script re-signs the app ad hoc with `--preserve-metadata=entitlements,flags,identifier`, so the hardened runtime flag and entitlements stay. The Developer ID signature and notarization ticket no longer apply to the modified bundle. The app launches normally on macOS 26.5.1 after this. Backups of the original `server.js` and `_CodeSignature` are written to `backups/<timestamp>/` before every change.

## Verification

- `evidence/regex-test.js`: the patched regex against 13 real ffmpeg 4 and ffmpeg 7 stream lines (mp4, mkv, ts; h264, hevc; aac, ac3, eac3, opus, dts; subtitles; with and without language and `(default)`). Run: `/Applications/Stremio.app/Contents/MacOS/node evidence/regex-test.js`.
- The exact `getVideoInfo` function extracted from the live bundle, run standalone against the source: before the patch it logs `Cannot parse stream` three times and returns `streams: []`; after the patch it returns the video, audio and subtitle streams with ids, codecs and channel layouts.
- End to end: `curl` the `/casting/transcode.mp4` endpoint for an h264 + AC3 mp4 and `ffprobe` the output. Before: h264 + vorbis 6ch. After: h264 + aac 2ch.
- Independent review: three reviewers tried to refute each patch and three swept the bundle for other ffmpeg 7 incompatibilities. None refuted. The regex sweep generated 61 files with the bundled ffmpeg (6 containers, 12 audio codecs, 7 video codecs, multi-audio, attached pictures, subtitles) and fed all 122 stream lines through both regexes: the original fails 23, the patched one fails 2 (non-three-letter language tags). Patch 1 was exercised with a harness that replays malformed, empty and valid NOTIFY bodies through the extracted handler: original exits 1, patched keeps serving.

## Auto-update caveat

While this was being diagnosed the Stremio shell updated itself from 5.1.26 to 5.1.27 (23:45, one minute after a restart). The updater replaces every file in the bundle and restarts the server, so all patches were gone and the TV received Vorbis again. The script found all five anchors in the new server.js and re-applied them.

`launchd/` contains an optional LaunchAgent that watches `server.js` and `Info.plist`, waits for the updater to finish, re-runs the script only if patches are missing, restarts Stremio and posts a macOS notification. Install:

```bash
sed "s#__REPO__#$(pwd)#g" launchd/nl.polman.stremio-repatch.plist > ~/Library/LaunchAgents/nl.polman.stremio-repatch.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/nl.polman.stremio-repatch.plist
```

Remove with `launchctl bootout gui/$(id -u)/nl.polman.stremio-repatch`.

## Upstream

The server is not open source. Both bugs are filed at `Stremio/stremio-bugs`: [#2786](https://github.com/Stremio/stremio-bugs/issues/2786) (server crash on malformed UPnP XML) and [#2787](https://github.com/Stremio/stremio-bugs/issues/2787) (Vorbis casting, ffmpeg 7 stream parsing). The submitted texts are in `issues/`. Related earlier reports of the crash: [stremio-bugs #327](https://github.com/Stremio/stremio-bugs/issues/327) (2021), [stremio-bugs #383](https://github.com/Stremio/stremio-bugs/issues/383) (2022).

## Files

- `stremio-upnp-patch.sh`: the patch script (apply, `DRY=1`, or `STREMIO_SERVER_JS=<copy>` to test on a copy)
- `launchd/`: optional re-patch watcher for after auto-updates
- `cast-subs.py`: turn subtitles on for a running cast
- `remote/cast-remote.py`: browser remote control (seek, subtitles, timing)
- `remote/cast-sync.py`: resume where you left off, with subtitles
- `evidence/regex-test.js`: regex unit test
- `issues/`: the bug reports as filed upstream (#2786, #2787)

Not affiliated with Stremio. Use at your own risk; keep the backups the script writes.
