/* Switch a TV on over the network (Wake-on-LAN), for the server side.
 *
 * The MAC address comes from the Mac's own ARP table, which knows it once the TV
 * has been seen on the network. A magic packet is six 0xff bytes and the MAC sixteen
 * times, sent as UDP broadcast to port 9. The TV has to allow it ("switch on with
 * mobile" on a Samsung, "Wake on LAN" elsewhere).
 */
const dgram = require("dgram");

function macFromArp(arpOutput, ip) {
    const line = String(arpOutput).split("\n").find((l) => l.indexOf("(" + ip + ")") >= 0);
    const m = line && line.match(/at ([0-9a-f]{1,2}(?::[0-9a-f]{1,2}){5})/i);
    if (!m) return null;
    return m[1].split(":").map((x) => x.padStart(2, "0")).join(":").toLowerCase();
}

function magicPacket(mac) {
    const hex = String(mac).replace(/[^0-9a-f]/gi, "");
    if (hex.length !== 12) throw new Error("not a MAC address: " + mac);
    const one = Buffer.from(hex, "hex"), out = Buffer.alloc(6 + 16 * 6, 0xff);
    for (let i = 0; i < 16; i++) one.copy(out, 6 + i * 6);
    return out;
}

function wake(mac, opts, cb) {
    opts = opts || {};
    const sock = dgram.createSocket("udp4"), pkt = magicPacket(mac);
    sock.on("error", (e) => { sock.close(); cb && cb(e); });
    sock.bind(() => {
        sock.setBroadcast(true);
        let left = opts.repeat || 3;
        const send = () => sock.send(pkt, opts.port || 9, opts.address || "255.255.255.255", (e) => {
            if (e || --left <= 0) { sock.close(); cb && cb(e || null); } else setTimeout(send, 100);
        });
        send();
    });
}

module.exports = { macFromArp, magicPacket, wake };
