Title: Casting sends Vorbis audio and re-encodes video for every source: castingUtils.getVideoInfo cannot parse ffmpeg 7 stream lines

**Stremio version:** 5.1.27 macOS (Apple silicon), also 5.1.26. Streaming server 4.21.0, bundled ffmpeg 7.1.1-Jellyfin, node 16.20.2.
**Renderers:** LG 42LM760S (DLNA) reports "unsupported audio codec" or "invalid file" for every source; Chromecast 3rd gen plays but the Mac re-encodes video with libx264 for nothing. The audio track picker in the cast player is always empty.

**Root cause**
`Casting.prototype.transcode` (`/casting/transcode.mp4`) chooses copy or transcode per stream from `castingUtils.getVideoInfo`, which parses `ffmpeg -i` stderr with a regex written for ffmpeg 4:

```
/#(\d+:\d+)(?:\((\w{3})\)|):\s(\w+):\s(\w+)(?:\s([^,]+),\s(\w+\([^)]+\)|[^,]+),\s([^,]+),\s(.*?)(?:\s(\(default\)))?$)?/m
```

ffmpeg 7 prints a stream id block after the index: `Stream #0:1[0x2](eng): Audio: ac3 (ac-3 / 0x332D6361), 48000 Hz, 5.1(side), fltp, 384 kb/s (default)`. The `[0x2]` part does not match, every line logs `castingUtils: Cannot parse stream "..."`, and `streams` is empty. The transcoder then spawns (captured from the live process):

```
ffmpeg -copyts -ss 0 -i http://localhost:11470/<infohash>/0? -t 3363.55 -f matroska -threads 0 pipe:1
```

No `-map`, no `-c:v copy`, no `-c:a aac`. The matroska muxer defaults apply: h264 via libx264 (full re-encode) and **Vorbis** audio. ffprobe on what the endpoint serves: `video h264, audio vorbis 6ch`. Most TVs do not decode Vorbis. Same result for an h264 + AAC stereo mp4 that should have been a plain `-c copy` remux.

`ChromecastClient.play` and `DLNAClient.play` use the same function to build the audio track list, which is why the picker is empty.

**Fix**
Accept an optional bracket block after the stream index:

```
/#(\d+:\d+)(?:\[[^\]]*\])?(?:\((\w{3})\)|):\s(\w+):\s(\w+)...
```

Capture groups are unchanged. Verified against 122 stream lines generated with the bundled ffmpeg 7.1.1 (mp4, mov, mkv, ts, webm, avi; aac, ac3, eac3, opus, vorbis, flac, mp3, dts, truehd, pcm; h264, hevc, av1, vp9, mpeg2, mjpeg; multi-audio, attached pictures, subtitles): original regex fails 23 lines, patched fails 2 (language tags that are not three letters). After the fix the endpoint serves `h264 (copy) + aac stereo` and the TV plays.

Two related items in the same bundle:
- ffmpeg 7 prints `Audio: ac3, 48000 Hz, ...` without a `(profile)` for ac3/eac3/opus/vorbis/flac, so the optional tail of the regex also fails for those and the `(default)` flag and channel layout are lost. Making the profile part optional fixes default-track selection on multi-audio files: `:\s(\w+):\s(\w+)(?:(?:\s([^,]+))?,\s...`.
- `-vbsf` was removed in ffmpeg 7; `segmentMiddlewareArgs.video.getFilter` still passes it (legacy DLNA MPEG-TS route), ffmpeg exits with code 8. `-bsf:v` works.

Patch script and evidence: https://github.com/WouterP0lman/stremio-macos-cast-patches (patches 2, 4 and 5).
