# Controlling a TV from the desktop app

Casting to a DLNA TV works from Stremio's interface, but nothing after the first
"play this" reaches the TV. Pause, seek, subtitles and volume all keep driving the
local player instead, which is why the desktop shows one position and the TV
another.

This is not a setting and not a bug in the streaming server. It is missing in the
interface. In `stremio-web`, `Player.js` derives its whole notion of casting from
the Google Cast SDK:

```js
const [casting, setCasting] = React.useState(() => {
    return services.chromecast.active &&
        services.chromecast.transport.getCastState() === cast.framework.CastState.CONNECTED;
});
```

A device of type `tv` never sets that. Picking one dispatches `PlayOnDevice` once,
and the `PlayingOnDevice` event then pauses the local video:

```js
if (name === 'PlayingOnDevice') {
    playingOnExternalDevice.current = true;
    onPauseRequested();
}
```

After that the player has no line to the device at all. Chromecast has a transport
for exactly this. A TV has none.

## What is here

- `useCastDevice.ts`: that missing transport, spoken over the streaming server's own
  `/casting/<device>/player` endpoint. It polls the device state twice a second and
  sends play, pause, seek, volume, subtitle and subtitle-delay commands. Changes are
  held for a few seconds after they are sent, because a change restarts the transcode
  and the renderer keeps describing the old stream until it picks up the new one.
- `player-cast-controls.patch`: seven edits to `src/routes/Player/Player.js` that
  remember which TV is playing, feed the control bar from the device instead of the
  local video, and route the buttons to it.

## Trying it

```bash
git clone https://github.com/Stremio/stremio-web.git && cd stremio-web
pnpm install
cp <this repo>/webui/useCastDevice.ts src/routes/Player/
git apply <this repo>/webui/player-cast-controls.patch
pnpm build
python3 -m http.server 11480 --directory build &
/Applications/Stremio.app/Contents/MacOS/Stremio --webui-url=http://127.0.0.1:11480/
```

The shell takes `--webui-url` and loads whatever is there, so this replaces nothing
and starting Stremio normally brings the stock interface back.

One thing to know before you do: the interface stores your session per origin, so a
local build starts logged out and you sign in once. Your library and add-ons come
back with that.

## Status

Built and loaded in the shell on macOS 26.5.1 against Stremio 5.1.27. The commands it
sends are the same ones proven against an LG 42LM760S: pause, resume, seek and
subtitle delay all reach that TV through the streaming server.

Meant for upstream rather than for permanent local use. A fork pinned to one commit
stops getting fixes; the point is the missing transport, not this build.
