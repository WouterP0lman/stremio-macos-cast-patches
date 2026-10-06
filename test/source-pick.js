// Source choice per TV, on stream entries shaped like the ones Torrentio and TPB+ return.
const S = require("../webui/cast-sources.js");
const streams = [
  { name: "TPB+\n1080p", title: "Game.of.Thrones.S06.COMPLETE.1080p.BluRay.10bit.x265\n👤 443 💾 815.59 MB" },
  { name: "TPB+\n1080p", title: "Game.of.Thrones.S06E01.1080p.BluRay.x264-DEMAND\n👤 393 💾 1.41 GB" },
  { name: "TPB+\n720p", title: "GoT.S06E01.720p.HDTV.x264\n👤 63 💾 250.39 MB" },
  { name: "Torrentio\n4k", title: "Game.of.Thrones.S06E01.2160p.UHD.BluRay.HDR.x265\n👤 2 💾 9.8 GB" },
  { name: "TPB+\n1080p", title: "Game.of.Thrones.S06E01.1080p.WEB-DL.x264\n👤 3 💾 1.2 GB" },
];
const checks = [];
const ok = (w, c) => checks.push([w, !!c]);
const p = S.parse(streams[0]);
ok("reads resolution, codec, seeders and size", p.res === 1080 && p.codec === "hevc" && p.seeds === 443 && Math.round(p.bytes / 1e6) === 816);
const lg = S.pick(streams, { hevc: false, maxRes: 1080 }, 3500);
ok("TV without HEVC: the well-seeded x264 1080p wins", lg[0].index === 1);
ok("TV without HEVC: the x265 pack ranks below every playable stream with seeders", lg.findIndex((r) => r.index === 0) > lg.findIndex((r) => r.index === 2));
const sam = S.pick(streams, { hevc: true, maxRes: 2160 }, 3500);
ok("HEVC TV: an x265 source with many seeders is fine too", sam[0].native && sam[0].parsed.seeds >= 300);
ok("a 4K HDR source with 2 seeders never wins", lg[0].index !== 3 && sam[0].index !== 3);
ok("x264 with 3 seeders loses to x264 with 393", lg.findIndex((r) => r.index === 1) < lg.findIndex((r) => r.index === 4));
let bad = 0; for (const [w, c] of checks) { console.error((c ? "ok   " : "FAIL ") + w); if (!c) bad++; }
console.log(bad); process.exit(bad ? 1 : 0);
