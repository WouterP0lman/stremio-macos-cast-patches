#!/usr/bin/env python3
"""A fake DLNA TV, so casting can be verified without hardware.

    python3 test/fake-dlna-tv.py

It presents itself as a UPnP MediaRenderer called "Fake Test TV", announces
itself to Stremio, and prints exactly what the server sends it. Cast to it and
you see whether `time` and `subtitles` are populated, which is the whole point:

    [fake tv] SetAVTransportURI
        video          = http://localhost:11470/<infohash>/7?
        time           = 371
        subtitles      = http://127.0.0.1:11470/<infohash>/8
    [fake tv] Play, starting at 00:06:11

Two things it does differently from a textbook UPnP device, both needed in
practice:

  * It announces straight to Stremio's SSDP socket instead of relying on the
    multicast port. Other software (Spotify, printers) often holds port 1900
    exclusively on macOS, and Stremio never listens there anyway: it binds a
    random port and only reads replies to its own searches. Announcing directly
    also avoids taking the port away from Stremio's own discovery, which stops
    real devices from being found.
  * Its service descriptions carry no xmlns. The client parses them with
    findall("./actionList/action"), which does not match namespaced tags, so a
    namespaced description makes every action come back as "not implemented".

Options:
  --broken-xml   echo the cast URL back in an event with unescaped '&' plus a
                 trailing NUL byte, the way an LG 42LM760S does. Without patches
                 1, 3 and 9 that kills the streaming server; with them it survives.
  --relative     report position as time since Play instead of the point in the
                 film, the way some renderers do. The server has to land on the
                 same absolute position either way.
  --state-file F write what the TV was told to F as JSON, for automated tests
  --port N       HTTP port (default 47000)

Each run uses a fresh device id, because Stremio caches a device's service
description for as long as it runs. Ctrl-C stops it.
"""
import http.server, socket, socketserver, struct, sys, threading, time, urllib.parse, uuid

PORT = 47000
BROKEN = "--broken-xml" in sys.argv
RELATIVE = "--relative" in sys.argv          # report time since play, not the absolute point
STATE_FILE = None
if "--state-file" in sys.argv:
    STATE_FILE = sys.argv[sys.argv.index("--state-file") + 1]
if "--port" in sys.argv:
    PORT = int(sys.argv[sys.argv.index("--port") + 1])
import os as _os
UDN = "uuid:" + str(uuid.uuid5(uuid.NAMESPACE_DNS, "stremio-fake-tv-" + _os.environ.get("FAKE_TV_ID", "1")))
SSDP_ADDR, SSDP_PORT = "239.255.255.250", 1900
state = {"uri": "", "meta": "", "transport": "STOPPED", "position": 0, "started": 0.0, "events": []}


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80)); return s.getsockname()[0]
    finally:
        s.close()


IP = local_ip()
BASE = f"http://{IP}:{PORT}"

DESC = f"""<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>
<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>Fake Test TV</friendlyName><manufacturer>stremio-macos-cast-patches</manufacturer>
<modelName>Fake TV 1.0</modelName><UDN>{UDN}</UDN>
<serviceList>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
<controlURL>/upnp/control/AVTransport1</controlURL><eventSubURL>/upnp/event/AVTransport1</eventSubURL>
<SCPDURL>/AVTransport1.xml</SCPDURL></service>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
<serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
<controlURL>/upnp/control/RenderingControl1</controlURL><eventSubURL>/upnp/event/RenderingControl1</eventSubURL>
<SCPDURL>/RenderingControl1.xml</SCPDURL></service>
<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
<controlURL>/upnp/control/ConnectionManager1</controlURL><eventSubURL>/upnp/event/ConnectionManager1</eventSubURL>
<SCPDURL>/ConnectionManager1.xml</SCPDURL></service>
</serviceList></device></root>"""

def _action(name, args):
    """args: list of (name, direction, stateVariable)"""
    a = "".join(f"<argument><name>{n}</name><direction>{d}</direction>"
                f"<relatedStateVariable>{v}</relatedStateVariable></argument>" for n, d, v in args)
    return f"<action><name>{name}</name><argumentList>{a}</argumentList></action>"


def _scpd(actions, variables):
    v = "".join(f'<stateVariable sendEvents="no"><name>{n}</name><dataType>{t}</dataType></stateVariable>'
                for n, t in variables)
    # no xmlns: the client parses with findall("./actionList/action"), which does
    # not match namespaced tags in this elementtree build
    return ('<?xml version="1.0"?><scpd>'
            "<specVersion><major>1</major><minor>0</minor></specVersion>"
            f"<actionList>{''.join(actions)}</actionList><serviceStateTable>{v}</serviceStateTable></scpd>")


ID = ("InstanceID", "in", "A_ARG_TYPE_InstanceID")
AVT = _scpd([
    _action("SetAVTransportURI", [ID, ("CurrentURI", "in", "AVTransportURI"),
                                  ("CurrentURIMetaData", "in", "AVTransportURIMetaData")]),
    _action("Play", [ID, ("Speed", "in", "TransportPlaySpeed")]),
    _action("Pause", [ID]), _action("Stop", [ID]),
    _action("Seek", [ID, ("Unit", "in", "A_ARG_TYPE_SeekMode"), ("Target", "in", "A_ARG_TYPE_SeekTarget")]),
    _action("GetTransportInfo", [ID, ("CurrentTransportState", "out", "TransportState"),
                                 ("CurrentTransportStatus", "out", "TransportStatus"),
                                 ("CurrentSpeed", "out", "TransportPlaySpeed")]),
    _action("GetPositionInfo", [ID, ("Track", "out", "CurrentTrack"),
                                ("TrackDuration", "out", "CurrentTrackDuration"),
                                ("TrackMetaData", "out", "CurrentTrackMetaData"),
                                ("TrackURI", "out", "CurrentTrackURI"),
                                ("RelTime", "out", "RelativeTimePosition"),
                                ("AbsTime", "out", "AbsoluteTimePosition"),
                                ("RelCount", "out", "RelativeCounterPosition"),
                                ("AbsCount", "out", "AbsoluteCounterPosition")]),
    _action("GetMediaInfo", [ID, ("NrTracks", "out", "NumberOfTracks"),
                             ("MediaDuration", "out", "CurrentMediaDuration"),
                             ("CurrentURI", "out", "AVTransportURI"),
                             ("CurrentURIMetaData", "out", "AVTransportURIMetaData"),
                             ("PlayMedium", "out", "PlaybackStorageMedium"),
                             ("RecordMedium", "out", "RecordStorageMedium"),
                             ("WriteStatus", "out", "RecordMediumWriteStatus")]),
], [("A_ARG_TYPE_InstanceID", "ui4"), ("AVTransportURI", "string"), ("AVTransportURIMetaData", "string"),
    ("TransportState", "string"), ("TransportStatus", "string"), ("TransportPlaySpeed", "string"),
    ("CurrentTrack", "ui4"), ("CurrentTrackDuration", "string"), ("CurrentTrackMetaData", "string"),
    ("CurrentTrackURI", "string"), ("RelativeTimePosition", "string"), ("AbsoluteTimePosition", "string"),
    ("RelativeCounterPosition", "i4"), ("AbsoluteCounterPosition", "i4"), ("NumberOfTracks", "ui4"),
    ("CurrentMediaDuration", "string"), ("PlaybackStorageMedium", "string"),
    ("RecordStorageMedium", "string"), ("RecordMediumWriteStatus", "string"),
    ("A_ARG_TYPE_SeekMode", "string"), ("A_ARG_TYPE_SeekTarget", "string")])

RC = _scpd([
    _action("GetVolume", [ID, ("Channel", "in", "A_ARG_TYPE_Channel"), ("CurrentVolume", "out", "Volume")]),
    _action("SetVolume", [ID, ("Channel", "in", "A_ARG_TYPE_Channel"), ("DesiredVolume", "in", "Volume")]),
], [("A_ARG_TYPE_InstanceID", "ui4"), ("A_ARG_TYPE_Channel", "string"), ("Volume", "ui2")])

CM = _scpd([
    _action("GetProtocolInfo", [("Source", "out", "SourceProtocolInfo"), ("Sink", "out", "SinkProtocolInfo")]),
], [("SourceProtocolInfo", "string"), ("SinkProtocolInfo", "string")])

SINK = ",".join([
    "http-get:*:video/mp4:*", "http-get:*:video/x-matroska:*", "http-get:*:video/mpeg:*",
    "http-get:*:video/x-mkv:*", "http-get:*:audio/mpeg:*",
])


def envelope(action, service, inner):
    return (f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            f's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            f'<u:{action}Response xmlns:u="{service}">{inner}</u:{action}Response></s:Body></s:Envelope>')


def _save():
    """Write what the TV has been told, so an automated test can assert on it."""
    if not STATE_FILE:
        return
    import json
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as fh:
            json.dump({"uri": state.get("uri"), "transport": state.get("transport"),
                       "position": state.get("position"),
                       "relative": RELATIVE,
                       "events": [[n, {k: v[0] for k, v in q.items()}] for n, q in state["events"]]},
                      fh, indent=1)
    except Exception:
        pass


def hms(sec):
    sec = int(sec)
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, body, ctype="text/xml; charset=utf-8", code=200, extra=None):
        raw = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        print(f"  [http] GET {self.path} van {self.client_address[0]}")
        if self.path == "/desc.xml":
            return self._send(DESC)
        if self.path == "/AVTransport1.xml":
            return self._send(AVT)
        if self.path == "/RenderingControl1.xml":
            return self._send(RC)
        if self.path == "/ConnectionManager1.xml":
            return self._send(CM)
        self._send("not found", "text/plain", 404)

    def do_SUBSCRIBE(self):
        sid = "uuid:" + str(uuid.uuid4())
        self.send_response(200)
        self.send_header("SID", sid)
        self.send_header("TIMEOUT", "Second-1800")
        self.send_header("Content-Length", "0")
        self.end_headers()
        cb = (self.headers.get("CALLBACK") or "").strip("<>")
        if cb and BROKEN:
            threading.Thread(target=self._send_broken_event, args=(cb, sid), daemon=True).start()

    def do_UNSUBSCRIBE(self):
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()

    def _send_broken_event(self, cb, sid):
        """Reproduce the LG's malformed NOTIFY: unescaped & plus a trailing NUL."""
        time.sleep(2)
        uri = state["uri"] or f"{BASE}/nothing"
        inner = (f'&lt;Event xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/AVT/&quot;&gt;'
                 f'&lt;InstanceID val=&quot;0&quot;&gt;'
                 f'&lt;TransportState val=&quot;PLAYING&quot;/&gt;'
                 f'&lt;CurrentTrackURI val=&quot;{uri}&quot;/&gt;'   # unescaped & lives here
                 f'&lt;CurrentTrackDuration val=&quot;00:54:28&quot;/&gt;'
                 f'&lt;/InstanceID&gt;&lt;/Event&gt;')
        body = (f'<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">\n<e:property>\n'
                f'<LastChange>{inner}</LastChange>\n</e:property>\n</e:propertyset>\x00')
        try:
            u = urllib.parse.urlparse(cb)
            c = http.client.HTTPConnection(u.hostname, u.port, timeout=5)
            c.request("NOTIFY", u.path or "/", body.encode(),
                      {"Content-Type": 'text/xml; charset="utf-8"', "NT": "upnp:event",
                       "NTS": "upnp:propchange", "SID": sid, "SEQ": "0"})
            c.getresponse(); c.close()
            print("  [fake tv] sent a deliberately malformed event (unescaped & plus NUL byte)")
        except Exception as e:
            print("  [fake tv] event failed:", type(e).__name__)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        action = (self.headers.get("SOAPACTION") or "").strip('"').split("#")[-1]
        svc = "urn:schemas-upnp-org:service:AVTransport:1"
        if "RenderingControl" in self.path:
            svc = "urn:schemas-upnp-org:service:RenderingControl:1"
        elif "ConnectionManager" in self.path:
            svc = "urn:schemas-upnp-org:service:ConnectionManager:1"

        if action == "SetAVTransportURI":
            import html, re
            m = re.search(r"<CurrentURI>(.*?)</CurrentURI>", body, re.S)
            uri = html.unescape(m.group(1)) if m else ""
            state["uri"] = uri
            state["transport"] = "STOPPED"
            print("\n  [fake tv] SetAVTransportURI")
            q = urllib.parse.parse_qs(urllib.parse.urlparse(uri).query, keep_blank_values=True)
            for k in ("video", "time", "audioTrack", "subtitles", "subtitlesDelay"):
                if k in q:
                    v = q[k][0]
                    print(f"      {k:15s} = {(v[:70] + '…') if len(v) > 70 else (v or '(empty)')}")
            state["events"].append(("SetAVTransportURI", q))
            _save()
            return self._send(envelope(action, svc, ""))

        if action == "Play":
            state["transport"] = "PLAYING"; state["started"] = time.time()
            q = urllib.parse.parse_qs(urllib.parse.urlparse(state["uri"]).query, keep_blank_values=True)
            state["position"] = float(q.get("time", ["0"])[0] or 0)
            print(f"  [fake tv] Play, starting at {hms(state['position'])}")
            _save()
            return self._send(envelope(action, svc, ""))

        if action in ("Stop", "Pause"):
            state["transport"] = "STOPPED" if action == "Stop" else "PAUSED_PLAYBACK"
            print(f"  [fake tv] {action}")
            return self._send(envelope(action, svc, ""))

        if action == "GetTransportInfo":
            return self._send(envelope(action, svc,
                f"<CurrentTransportState>{state['transport']}</CurrentTransportState>"
                "<CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>"))

        if action == "GetPositionInfo":
            elapsed = time.time() - state["started"] if state["transport"] == "PLAYING" else 0
            # An absolute renderer answers with the point in the film; a relative one
            # answers with how long it has been playing. Both exist in the wild, and
            # the server has to end up at the same place either way.
            pos = elapsed if RELATIVE else state["position"] + elapsed
            return self._send(envelope(action, svc,
                f"<Track>1</Track><TrackDuration>00:54:28</TrackDuration><TrackMetaData></TrackMetaData>"
                f"<TrackURI>{state['uri']}</TrackURI><RelTime>{hms(pos)}</RelTime>"
                f"<AbsTime>{hms(pos)}</AbsTime><RelCount>0</RelCount><AbsCount>0</AbsCount>"))

        if action == "GetMediaInfo":
            import html as h
            return self._send(envelope(action, svc,
                f"<NrTracks>1</NrTracks><MediaDuration>00:54:28</MediaDuration>"
                f"<CurrentURI>{h.escape(state['uri'])}</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
                "<PlayMedium>NETWORK</PlayMedium><RecordMedium>NOT_IMPLEMENTED</RecordMedium>"
                "<WriteStatus>NOT_IMPLEMENTED</WriteStatus>"))

        if action == "GetProtocolInfo":
            return self._send(envelope(action, svc, f"<Source></Source><Sink>{SINK}</Sink>"))

        if action == "GetVolume":
            return self._send(envelope(action, svc, "<CurrentVolume>30</CurrentVolume>"))

        return self._send(envelope(action or "Unknown", svc, ""))

    def log_message(self, *a):
        pass


import http.client  # noqa: E402  (needed by _send_broken_event)


def stremio_socket():
    """Stremio's SSDP client binds a random UDP port and never listens on 1900,
    so announcements can be delivered to it directly. That also sidesteps other
    software (Spotify, printers) holding 1900 exclusively.

    Returns (host, port). The host matters: the socket is usually bound to the
    LAN address rather than to every address, and a datagram sent to 127.0.0.1
    then never reaches it."""
    import subprocess
    try:
        pid = subprocess.run(["pgrep", "-f", "MacOS/node /Applications/Stremio.app/Contents/MacOS/server.js"],
                             capture_output=True, text=True).stdout.split()[0]
        out = subprocess.run(["lsof", "-nP", "-p", pid], capture_output=True, text=True).stdout
        for l in out.splitlines():
            if "UDP" not in l:
                continue
            addr = l.split()[-1]
            if ":" not in addr or addr.endswith(":5353"):
                continue
            host, _, port = addr.rpartition(":")
            return ("127.0.0.1" if host in ("*", "") else host), int(port)
    except Exception:
        pass
    return None, None


def direct_announcer(stop):
    """Push our SSDP reply straight at Stremio's discovery socket."""
    types = ["urn:schemas-upnp-org:device:MediaRenderer:1", "upnp:rootdevice", UDN]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    told = None
    while not stop.is_set():
        host, port = stremio_socket()
        if port:
            if told != (host, port):
                print(f"  [ssdp] announcing straight to Stremio on {host}:{port}")
                told = (host, port)
            for t in types:
                msg = (f"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\n"
                       f"LOCATION: {BASE}/desc.xml\r\nST: {t}\r\nUSN: {UDN}::{t}\r\n"
                       f"SERVER: Darwin/1.0 UPnP/1.0 FakeTV/1.0\r\n\r\n")
                try: s.sendto(msg.encode(), (host, port))
                except Exception: pass
        stop.wait(5)
    s.close()


def ssdp_responder(stop):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    # SO_REUSEADDR only. Adding SO_REUSEPORT makes macOS hand this socket the
    # multicast group exclusively, which stops Stremio's own SSDP client from
    # searching at all, so the fake TV would hide every real device too.
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("", SSDP_PORT))
    except OSError:
        print("  [ssdp] port 1900 is taken by other software; using direct announcements only")
        return
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                 struct.pack("4sl", socket.inet_aton(SSDP_ADDR), socket.INADDR_ANY))
    s.settimeout(1)
    types = ["upnp:rootdevice", "urn:schemas-upnp-org:device:MediaRenderer:1", UDN]

    def announce(nts="ssdp:alive"):
        for t in types:
            msg = (f"NOTIFY * HTTP/1.1\r\nHOST: {SSDP_ADDR}:{SSDP_PORT}\r\n"
                   f"CACHE-CONTROL: max-age=1800\r\nLOCATION: {BASE}/desc.xml\r\n"
                   f"NT: {t}\r\nNTS: {nts}\r\nUSN: {UDN}::{t}\r\n"
                   f"SERVER: Darwin/1.0 UPnP/1.0 FakeTV/1.0\r\n\r\n")
            s.sendto(msg.encode(), (SSDP_ADDR, SSDP_PORT))

    announce()
    last = time.time()
    while not stop.is_set():
        try:
            data, addr = s.recvfrom(2048)
            txt = data.decode("utf-8", "replace")
            if txt.startswith("M-SEARCH"):
                st_line = [l for l in txt.split("\r\n") if l.upper().startswith("ST:")]
                print(f"  [ssdp] M-SEARCH van {addr[0]}:{addr[1]} {st_line[0] if st_line else ''}")
            if txt.startswith("M-SEARCH") and ("MediaRenderer" in txt or "ssdp:all" in txt or "rootdevice" in txt):
                print(f"  [ssdp] -> antwoord naar {addr[0]}:{addr[1]}")
                for t in types:
                    reply = (f"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\n"
                             f"EXT:\r\nLOCATION: {BASE}/desc.xml\r\nST: {t}\r\n"
                             f"USN: {UDN}::{t}\r\nSERVER: Darwin/1.0 UPnP/1.0 FakeTV/1.0\r\n\r\n")
                    s.sendto(reply.encode(), addr)
        except socket.timeout:
            pass
        except Exception:
            pass
        if time.time() - last > 120:
            announce(); last = time.time()
    announce("ssdp:byebye")
    s.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    if "-h" in sys.argv or "--help" in sys.argv:
        print(__doc__); sys.exit(0)
    httpd = Server(("", PORT), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    stop = threading.Event()
    threading.Thread(target=ssdp_responder, args=(stop,), daemon=True).start()
    threading.Thread(target=direct_announcer, args=(stop,), daemon=True).start()
    print(f"Fake Test TV on {BASE}/desc.xml" + ("   [malformed events on]" if BROKEN else ""))
    print("It should appear in Stremio's cast list within a few seconds. Ctrl-C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        stop.set(); time.sleep(1.2); print("\nwithdrawn")
