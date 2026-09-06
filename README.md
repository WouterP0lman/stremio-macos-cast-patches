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

The server is not open source. Issue texts ready for `Stremio/stremio-bugs` are in `issues/`. Related earlier reports of the crash: [stremio-bugs #327](https://github.com/Stremio/stremio-bugs/issues/327) (2021), [stremio-bugs #383](https://github.com/Stremio/stremio-bugs/issues/383) (2022).

## Files

- `stremio-upnp-patch.sh`: the patch script (apply, `DRY=1`, or `STREMIO_SERVER_JS=<copy>` to test on a copy)
- `launchd/`: optional re-patch watcher for after auto-updates
- `evidence/regex-test.js`: regex unit test
- `issues/`: upstream bug report texts

Not affiliated with Stremio. Use at your own risk; keep the backups the script writes.
