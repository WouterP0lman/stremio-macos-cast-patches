#!/usr/bin/env node
// A fake Chromecast, so casting to Chromecast can be tested without a TV.
//
//   node test/fake-chromecast.js --state-file /tmp/cc.json [--port 8009]
//
// Speaks the Cast v2 protocol over TLS (CastMessage protobuf, length-prefixed),
// answers the receiver and media namespaces the way a Cast receiver does, and
// actually fetches what it is told to play: the stream (first 2 MB) and any active
// subtitle track. Everything it sees goes to the state file as JSON, so a test can
// count LAUNCH and LOAD messages, every request, and what was fetched.
//
// It is not announced over mDNS. The sandbox server is pointed at it directly
// (FAKE_CC_HOST), so a Stremio that is not under test never lists it.
const tls = require("tls"), http = require("http"), fs = require("fs"), os = require("os"),
      path = require("path"), cp = require("child_process");

const arg = (n, d) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : d; };
const PORT = +arg("--port", 8009), HOST = arg("--host", "127.0.0.1"), STATE = arg("--state-file", null);

// a self-signed certificate, made once
const dir = path.join(os.tmpdir(), "fake-chromecast-cert");
fs.mkdirSync(dir, { recursive: true });
const key = path.join(dir, "key.pem"), crt = path.join(dir, "cert.pem");
if (!fs.existsSync(crt)) cp.execSync(`openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=fakecast -days 3650 -keyout ${key} -out ${crt} 2>/dev/null`);

const state = { requests: [], launches: 0, loads: [], app: null, media: null };
const save = () => { if (STATE) try { fs.writeFileSync(STATE, JSON.stringify(state, null, 1)); } catch (e) {} };
const T0 = Date.now(), now = () => (Date.now() - T0) / 1000;

function vint(n) { const b = []; while (n > 127) { b.push((n & 127) | 128); n >>>= 7; } b.push(n); return Buffer.from(b); }
function str(tag, s) { const v = Buffer.from(s, "utf8"); return Buffer.concat([Buffer.from([tag]), vint(v.length), v]); }
function frame(src, dst, ns, obj) {
  const body = Buffer.concat([Buffer.from([0x08, 0]), str(0x12, src), str(0x1a, dst), str(0x22, ns),
                              Buffer.from([0x28, 0]), str(0x32, JSON.stringify(obj))]);
  const len = Buffer.alloc(4); len.writeUInt32BE(body.length); return Buffer.concat([len, body]);
}
function parse(buf) {
  let i = 0; const out = {};
  while (i < buf.length) {
    const key = buf[i++], f = key >> 3, t = key & 7;
    let v = 0, s = 0, b;
    if (t === 0) { do { b = buf[i++]; v |= (b & 127) << s; s += 7; } while (b & 128); out[f] = v; }
    else if (t === 2) { do { b = buf[i++]; v |= (b & 127) << s; s += 7; } while (b & 128); out[f] = buf.slice(i, i + v).toString("utf8"); i += v; }
    else break;
  }
  return out;
}

function fetchSome(url, max, cb) {
  let got = 0, head = "";
  const req = http.get(url, (res) => {
    res.on("data", (d) => { if (got < 64) head += d.slice(0, 64 - got).toString("utf8"); got += d.length; if (got >= max) req.destroy(); });
    res.on("end", () => cb(got, head)); res.on("close", () => cb(got, head));
  });
  req.on("error", () => cb(got, head));
  req.setTimeout(30000, () => req.destroy());
}

const NS = { conn: "urn:x-cast:com.google.cast.tp.connection", hb: "urn:x-cast:com.google.cast.tp.heartbeat",
             recv: "urn:x-cast:com.google.cast.receiver", media: "urn:x-cast:com.google.cast.media" };

function receiverStatus() {
  // an idle Chromecast still runs its Backdrop app; senders read applications[0] unguarded
  return { applications: state.app ? [{ appId: state.app, displayName: "Demo", statusText: state.media ? "Now Casting" : "Ready To Cast",
           sessionId: "sess-1", transportId: "web-1", namespaces: [{ name: NS.media }] }]
         : [{ appId: "E8C28D3C", displayName: "Backdrop", statusText: "", sessionId: "idle-1", transportId: "idle-1", namespaces: [] }],
           volume: { level: 1, muted: false } };
}
function mediaStatus() {
  const m = state.media; if (!m) return [];
  const t = m.playing ? m.base + (now() - m.since) : m.base;
  return [{ mediaSessionId: 1, playerState: m.playing ? "PLAYING" : "PAUSED", currentTime: t, media: { contentId: m.contentId },
            activeTrackIds: m.activeTrackIds || [] }];
}

tls.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(crt) }, (sock) => {
  let acc = Buffer.alloc(0);
  const send = (src, dst, ns, obj) => { try { sock.write(frame(src, dst, ns, obj)); } catch (e) {} };
  sock.on("data", (d) => {
    acc = Buffer.concat([acc, d]);
    while (acc.length >= 4) {
      const n = acc.readUInt32BE(0); if (acc.length < 4 + n) break;
      const m = parse(acc.slice(4, 4 + n)); acc = acc.slice(4 + n);
      let p; try { p = JSON.parse(m[6] || "{}"); } catch (e) { continue; }
      const from = m[2], to = m[3], ns = m[4], rid = p.requestId;
      if (ns !== NS.hb) { state.requests.push([now(), ns.split(".").pop(), p.type]); save(); }
      if (p.type === "PING") { send(to, from, ns, { type: "PONG" }); continue; }
      if (ns === NS.recv && p.type === "GET_STATUS") send(to, from, ns, { type: "RECEIVER_STATUS", requestId: rid, status: receiverStatus() });
      else if (ns === NS.recv && p.type === "LAUNCH") {
        state.launches++; state.app = p.appId; state.media = null; save();
        send(to, from, ns, { type: "RECEIVER_STATUS", requestId: rid, status: receiverStatus() });
      } else if (ns === NS.media && p.type === "GET_STATUS") send(to, from, ns, { type: "MEDIA_STATUS", requestId: rid, status: mediaStatus() });
      else if (ns === NS.media && p.type === "LOAD") {
        const media = p.media || {}, cid = String(media.contentId || "");
        const q = new URL(cid).searchParams, start = parseFloat(q.get("time") || "0") || 0;
        const track = (media.tracks || []).find((x) => (p.activeTrackIds || []).indexOf(x.trackId) >= 0);
        const rec = { at: now(), contentId: cid, contentType: media.contentType, activeTrackIds: p.activeTrackIds || [],
                      track: track ? track.trackContentId : null, bytes: 0, subsHead: null };
        state.loads.push(rec);
        state.media = { contentId: cid, base: start, since: now(), playing: true, activeTrackIds: p.activeTrackIds || [] };
        save();
        send(to, from, ns, { type: "MEDIA_STATUS", requestId: rid, status: mediaStatus() });
        fetchSome(cid, 2e6, (bytes) => { rec.bytes = Math.max(rec.bytes, bytes); save(); });
        if (track) fetchSome(track.trackContentId, 4096, (b, head) => { rec.subsHead = head; save(); });
      } else if (ns === NS.media && (p.type === "PAUSE" || p.type === "PLAY" || p.type === "SEEK")) {
        const m2 = state.media;
        if (m2) {
          const t = m2.playing ? m2.base + (now() - m2.since) : m2.base;
          m2.base = p.type === "SEEK" ? (p.currentTime || 0) : t; m2.since = now(); m2.playing = p.type !== "PAUSE";
        }
        save(); send(to, from, ns, { type: "MEDIA_STATUS", requestId: rid, status: mediaStatus() });
      } else if (ns === NS.recv && p.type === "SET_VOLUME") send(to, from, ns, { type: "RECEIVER_STATUS", requestId: rid, status: receiverStatus() });
    }
  });
  sock.on("error", () => {});
}).listen(PORT, HOST, () => { console.log("demo Chromecast on " + HOST + ":" + PORT); save(); });
