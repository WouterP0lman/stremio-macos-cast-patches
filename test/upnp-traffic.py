#!/usr/bin/env python3
"""How much a cast talks to the TV, and whether the TV's own messages get an answer.

    source $TMPDIR/stremio-sandbox/env      # after: bash test/sandbox.sh start
    python3 test/upnp-traffic.py before     # or: after

Casts a test film to a fake TV and, for one minute, asks the server for its
status the way Stremio's player and the cast remote do together: once a second
and once every one and a half seconds. The fake TV counts every UPnP action it
receives and sends a status event every five seconds, recording whether the
server answers it.

The film is served from this Mac's network address under a made-up debrid key,
so the run also shows whether that key ends up in the server's log.

Writes evidence/upnp-traffic-<label>.json and prints a summary. Needs a server
to talk to (STREMIO_URL) and its pid (STREMIO_PID), which test/sandbox.sh prints.
"""
import collections, importlib.util, json, os, secrets, socketserver, subprocess, sys
import threading, time, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("e2e", os.path.join(HERE, "cast-e2e.py"))
e2e = importlib.util.module_from_spec(spec); spec.loader.exec_module(e2e)

LABEL = sys.argv[1] if len(sys.argv) > 1 else "run"
MINUTE = int(os.environ.get("TRAFFIC_SECONDS", "60"))
LOG = os.environ.get("STREMIO_SANDBOX_LOG")


def lan_ip():
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1)); return s.getsockname()[0]
    finally:
        s.close()


def main():
    if not os.environ.get("STREMIO_PID"):
        print("  STREMIO_PID is not set; start the sandbox and source its env first"); return 1
    e2e.build_media()
    ip, port = lan_ip(), e2e.free_port()
    httpd = socketserver.ThreadingTCPServer((ip, port), e2e.Range)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    key = "TESTKEY" + secrets.token_hex(6)
    src = "http://%s:%d/resolve/realdebrid/%s/e2e.mkv" % (ip, port, key)

    tag = "traffic-%d" % os.getpid()
    state_file = os.path.join(e2e.CACHE, "tv-traffic.json")
    if os.path.exists(state_file): os.remove(state_file)
    tv = subprocess.Popen([sys.executable, os.path.join(HERE, "fake-dlna-tv.py"), "--state-file", state_file,
                           "--events", "--direct-only"],
                          env=dict(os.environ, PYTHONUNBUFFERED="1", FAKE_TV_ID=tag),
                          stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    dev = None
    polls, slow = [0], []
    try:
        dev = e2e.wait_device(e2e.device_id(tag))
        if not dev:
            print("  the server never discovered the fake TV"); return 1
        e2e.post("/casting/%s/player?%s" % (dev, urllib.parse.urlencode({"source": src, "time": 60000})))
        st = e2e.read_state(state_file, 1, deadline=45)
        if not st or st.get("transport") != "PLAYING":
            print("  the fake TV never started playing"); return 1

        stop = threading.Event()

        def poll(every):
            while not stop.is_set():
                t = time.time()
                try:
                    e2e.get("/casting/%s/player" % dev, timeout=10)
                except Exception:
                    pass
                took = time.time() - t
                polls[0] += 1
                if took > 1.0: slow.append(round(took, 2))
                stop.wait(max(0, every - took))

        threads = [threading.Thread(target=poll, args=(e,), daemon=True) for e in (1.0, 1.5)]
        started = time.time()
        for t in threads: t.start()
        time.sleep(MINUTE)
        stop.set()
        for t in threads: t.join(timeout=12)
        st = json.load(open(state_file))
    finally:
        try:
            if dev: e2e.post("/casting/%s/player?source=" % dev, timeout=15)
        except Exception:
            pass
        tv.terminate()
        try: tv.wait(timeout=5)
        except Exception: tv.kill()
        httpd.shutdown()

    calls = st.get("calls") or []
    play_at = next((t for a, t in calls if a == "Play"), None)
    window = [a for a, t in calls if play_at is not None and play_at <= t <= play_at + MINUTE]
    per_action = collections.Counter(window)
    notify = collections.Counter(str(c) for c, _ in st.get("notify") or [])
    leaked = None
    if LOG and os.path.exists(LOG):
        leaked = open(LOG, encoding="utf-8", errors="replace").read().count(key)
    result = {"label": LABEL, "seconds": MINUTE, "status_requests": polls[0],
              "slow_status_answers": slow, "upnp_actions": dict(per_action),
              "upnp_total": len(window), "notify_answers": dict(notify),
              "key_lines_in_log": leaked}
    out_dir = os.path.join(os.path.dirname(HERE), "evidence")
    os.makedirs(out_dir, exist_ok=True)
    json.dump(result, open(os.path.join(out_dir, "upnp-traffic-%s.json" % LABEL), "w"), indent=1)

    print("\n  %s: %d status requests in %ds" % (LABEL, polls[0], MINUTE))
    print("  UPnP actions the TV received after Play: %d" % len(window))
    for a, n in per_action.most_common():
        print("    %-18s %d" % (a, n))
    print("  status events the TV sent, and the answers: %s" % (dict(notify) or "none"))
    if slow: print("  status answers slower than 1s: %s" % slow)
    if leaked is not None:
        print("  the made-up debrid key appears %d times in the server log" % leaked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
