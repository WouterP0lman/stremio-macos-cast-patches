Title: Notes for PR #1446, from patching the 4.21.0 streaming server

(Ready to post as a comment on https://github.com/Stremio/stremio-web/pull/1446.
Not posted: it is the repository owner's call.)

I have been patching the streaming server that ships with Stremio 5.1.27 on macOS to make
casting behave, and ran into the same three things this PR addresses. Some measurements
that may save time, all against server 4.21.0.

**Sending subtitles after the source is required, and the PR gets this right.**
`DLNAClient.prototype.play` and `ChromecastClient.prototype.play` both set
`mediaStatus.subtitlesSrc = null` unconditionally, so a subtitle sent alongside `source`
is discarded. Worse, `Player.prototype.middleware` evaluates `source` after `subtitlesSrc`
in its method-selection cascade, so a single request carrying both dispatches `play` and
drops the subtitle silently. The two sequential posts in `cast_request` are the only
shape that works against existing servers.

**The start position is dropped by the same servers.**
`play()` takes only `srcURL`; the dispatch never passes `params.time`, and
`mediaStatus.time` is forced to 0. Even after passing it through, it is overwritten before
use: `play()` awaits an ffmpeg probe of the stream, and during that window the previous,
still-playing stream keeps emitting UPnP position events that overwrite `mediaStatus.time`.
Requesting 6:11 landed the device at 18:11 in practice. Chromecast additionally needs
`this.seekTime`, since `playFromStatus` builds its content id from that field rather than
from `mediaStatus.time`. Filed separately as stremio-bugs#2789.

**Two defects worth knowing about while you are in this code.**

1. `castingUtils.getVideoInfo` parses `ffmpeg -i` stderr with a regex written for ffmpeg 4.
   The bundled ffmpeg is 7.1.1, which prints `Stream #0:1[0x2](eng): Audio: ac3 …`. The
   `[0x2]` block breaks the regex on every line, `streams` comes back empty, and the
   transcoder then gets no `-map` and no `-c`, falling back to the matroska muxer defaults:
   libx264 plus **Vorbis** audio. Most TVs cannot decode Vorbis, so every cast fails with an
   audio error, including plain h264+AAC files that should have been a stream copy. Adding
   `(?:\[[^\]]*\])?` after the stream index fixes it. Details in stremio-bugs#2787.

2. `_updateStatusField` computes `this.seekTime + 1e3 * parseInt(value, 10)` for positions
   coming from a DLNA renderer. The cast stream is produced with `-copyts`, so the renderer
   already reports absolute time; after resuming at 14:37 the app showed 29:29 within
   seconds. Chromecast's `_conformStatus` gets this right, DLNA does not.

**One thing that might simplify the subtitle side.**
Season torrents very often ship a subtitle file next to each episode, with the same name
stem. Those are in sync by construction, cost no network round trip, and are already served
at `/<infoHash>/<index>`. Picking that before reaching for an addon covers a large share of
cases; where it is missing, `/opensubHash` plus the addon's `videoHash` extra gives a
frame-accurate match (`m: "h"`) rather than an imdb-level guess.

Working patches for all of the above, plus a fake DLNA renderer for testing without
hardware: https://github.com/WouterP0lman/stremio-macos-cast-patches
