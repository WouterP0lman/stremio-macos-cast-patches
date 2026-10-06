// Wake-on-LAN: MAC from ARP output and a correct magic packet, sent to a demo receiver.
const dgram = require("dgram"), W = require("../webui/cast-wake.js");
const checks = []; const ok = (w, c) => checks.push([w, !!c]);
const arp = "? (192.168.5.1) at 4:5f:a7:d0:11:2 on en0 ifscope [ethernet]\n? (192.168.5.56) at 70:2a:d5:fe:f8:d8 on en0 ifscope [ethernet]\n";
ok("MAC from the ARP table, zero-padded", W.macFromArp(arp, "192.168.5.1") === "04:5f:a7:d0:11:02");
ok("unknown IP gives no MAC", W.macFromArp(arp, "192.168.5.99") === null);
const p = W.magicPacket("70:2a:d5:fe:f8:d8");
ok("magic packet: 102 bytes, 6 x 0xff then the MAC 16 times", p.length === 102 && p.slice(0, 6).every((b) => b === 0xff) && p.slice(6 + 15 * 6).toString("hex") === "702ad5fef8d8");
const rx = dgram.createSocket("udp4"); let got = 0;
rx.on("message", (m) => { if (m.equals(p)) got++; });
rx.bind(0, "127.0.0.1", () => {
  W.wake("70:2a:d5:fe:f8:d8", { address: "127.0.0.1", port: rx.address().port, repeat: 3 }, (e) => {
    setTimeout(() => { ok("three packets arrive at the demo receiver", !e && got === 3); rx.close(); done(); }, 300);
  });
});
function done() { let bad = 0; for (const [w, c] of checks) { console.error((c ? "ok   " : "FAIL ") + w); if (!c) bad++; } console.log(bad); process.exit(bad ? 1 : 0); }
