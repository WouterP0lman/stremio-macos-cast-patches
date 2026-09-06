# Before and after, captured on the live server

Source: `Landman S01E01.mp4` via torrent (h264 High 1920x960, AC3 5.1, mov_text subtitles), served at `http://localhost:11470/<infohash>/0`.

## Before (server.js 4.21.0 unpatched, ffmpeg 7.1.1)

Live ffmpeg process spawned by `/casting/transcode.mp4`:

```
/Applications/Stremio.app/Contents/MacOS/ffmpeg -copyts -ss 0 -i http://localhost:11470/d4afec0d.../0? -t 3363.55 -f matroska -threads 0 pipe:1
```

The exact `getVideoInfo` function extracted from the bundle and run standalone against the same source:

```
castingUtils: Cannot parse stream "  Stream #0:0[0x1](eng): Video: h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709, progressive), 1920x960 [SAR 1:1 DAR 2:1], 3360 kb/s, 23.98 fps, 23.98 tbr, 24k tbn (default)"
castingUtils: Cannot parse stream "  Stream #0:1[0x2](eng): Audio: ac3 (ac-3 / 0x332D6361), 48000 Hz, 5.1(side), fltp, 384 kb/s (default)"
castingUtils: Cannot parse stream "  Stream #0:2[0x3](eng): Subtitle: mov_text (tx3g / 0x67337874), 0 kb/s (default)"
duration: 3363.55
streams: []
```

ffprobe on the first 4 MB served to the TV:

```
Content-Type: video/x-mkv
container: matroska,webm
   video | h264 High | 1920x960
   audio | vorbis    | 6 channels
   subtitle | ass
```

The LG 42LM760S shows "unsupported audio codec". `GetTransportInfo` on the TV still reports `PLAYING / OK`, so the failure is not visible over UPnP.

## After (patches applied)

```
container: matroska,webm
   video | h264 High | 1920x960
   audio | aac LC    | 2 stereo
```

The muxer default that caused the Vorbis output:

```
$ ffmpeg -h muxer=matroska
    Default video codec: h264.
    Default audio codec: vorbis.
    Default subtitle codec: ass.
```

The TV's DLNA sink list (`GetProtocolInfo`) contains `video/x-matroska:*`, `video/mp4:*`, `video/mp4:DLNA.ORG_PN=AVC_MP4_BL_CIF15_AAC_520`, MPEG-TS profiles, `audio/mpeg`, `audio/L16`, `audio/x-ms-wma`. No Vorbis anywhere.
