Title: server.js dies on malformed UPnP XML from a DLNA renderer while casting (uncaught sax error in upnp-device-client)

**Stremio version:** 5.1.27 macOS (Apple silicon), also 5.1.26. Streaming server 4.21.0 (bundled), node 16.20.2.
**Renderer:** LG 42LM760S-ZB (2012 NetCast, `urn:schemas-upnp-org:device:MediaRenderer:1`).

**What happens**
Casting to the TV over DLNA works for a moment, then the dialog "Stremio server stopped. The streaming server process stopped unexpectedly" appears with this tail:

```
at error (server.js:90350:18)
at strictFail (server.js:90360:30)
at SAXParser.write (server.js:89717:144)
at XMLParser.feed (server.js:89658:21)
at ElementTree.parse (server.js:23016:16)
at Object.exports.parse (server.js:23120:21)
at server.js:89474:47
at server.js:89489:19
at ConcatStream.<anonymous> (server.js:90492:13)
at ConcatStream.emit (node:events:525:35)
at finishMaybe (server.js:42554:82)
...
```
(line numbers from the 5.1.26 bundle)

**Root cause**
`DeviceClient.prototype.ensureEventingServer` (upnp-device-client) parses every NOTIFY body with `et.parse(buf.toString())` inside a concat-stream callback, with no try/catch. sax runs in strict mode and throws on the first invalid character. Nothing catches it, so the node process exits and all playback stops. The same unguarded `et.parse` exists in `DeviceClient.prototype.callAction` for SOAP responses (Play, Stop, GetPositionInfo, GetVolume).

This is the same crash as #327 (2021) and #383 (2022), both closed. It is still in server 4.21.0.

**Fix**
Wrap both parses in try/catch. Event handler: log and return an empty event list. Action handler: pass the error to the callback with `code = "EUPNP"`. Also `doc.findtext(".//errorDescription").trim()` in callAction throws if the element is missing; use `(... || "").trim()`. Unrelated but nearby: the eventing server never calls `res.end()` for NOTIFY, so renderers never get a 200.

A patch script that applies this to the shipped bundle, with the evidence, is at https://github.com/WouterP0lman/stremio-macos-cast-patches (patches 1 and 3).
