// Voorgestelde patch 4: profiel-haakjes na de codecnaam optioneel maken
var re = /#(\d+:\d+)(?:\[[^\]]*\])?(?:\((\w{3})\)|):\s(\w+):\s(\w+)(?:(?:\s([^,]+))?,\s(\w+\([^)]+\)|[^,]+),\s([^,]+),\s(.*?)(?:\s(\(default\)))?$)?/m;
var cases = [
  ["ff7 mp4 video h264 (High)",  "  Stream #0:0[0x1](eng): Video: h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709, progressive), 1920x960 [SAR 1:1 DAR 2:1], 3360 kb/s, 23.98 fps, 23.98 tbr, 24k tbn (default)", {type:"Video",codec:"h264",lang:"eng",def:true,pixfmt:"yuv420p(tv, bt709, progressive)",fmt:"1920x960 [SAR 1:1 DAR 2:1]"}],
  ["ff7 mp4 audio ac3 ZONDER profiel", "  Stream #0:1[0x2](eng): Audio: ac3 (ac-3 / 0x332D6361), 48000 Hz, 5.1(side), fltp, 384 kb/s (default)", {type:"Audio",codec:"ac3",lang:"eng",def:true,pixfmt:"48000 Hz",fmt:"5.1(side)"}],
  ["ff7 mkv audio ac3 komma direct", "  Stream #0:1(eng): Audio: ac3, 48000 Hz, 5.1(side), fltp, 448 kb/s (default)", {type:"Audio",codec:"ac3",lang:"eng",def:true,pixfmt:"48000 Hz",fmt:"5.1(side)"}],
  ["ff7 mkv audio eac3 komma direct", "  Stream #0:2(nld): Audio: eac3, 48000 Hz, 5.1(side), fltp", {type:"Audio",codec:"eac3",lang:"nld",def:false,pixfmt:"48000 Hz",fmt:"5.1(side)"}],
  ["ff7 mkv audio opus komma direct", "  Stream #0:1(eng): Audio: opus, 48000 Hz, stereo, fltp (default)", {type:"Audio",codec:"opus",lang:"eng",def:true,pixfmt:"48000 Hz",fmt:"stereo"}],
  ["ff7 aac stereo (LC)",     "  Stream #0:1[0x2](eng): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 161 kb/s (default)", {type:"Audio",codec:"aac",lang:"eng",def:true,pixfmt:"48000 Hz",fmt:"stereo"}],
  ["ff7 mkv video zonder profiel", "  Stream #0:0: Video: h264, yuv420p(progressive), 1280x720, SAR 1:1 DAR 16:9, 23.98 fps, 23.98 tbr, 1k tbn (default)", {type:"Video",codec:"h264",lang:"und",def:true,pixfmt:"yuv420p(progressive)",fmt:"1280x720"}],
  ["ff7 hevc main10 hdr",     "  Stream #0:0[0x1]: Video: hevc (Main 10) (hev1 / 0x31766568), yuv420p10le(tv, bt2020nc/bt2020/smpte2084), 3840x1600 [SAR 1:1 DAR 12:5], 8000 kb/s, 23.98 fps (default)", {type:"Video",codec:"hevc",lang:"und",def:true,pixfmt:"yuv420p10le(tv, bt2020nc/bt2020/smpte2084)",fmt:"3840x1600 [SAR 1:1 DAR 12:5]"}],
  ["ff7 subtitle",            "  Stream #0:2[0x3](eng): Subtitle: mov_text (tx3g / 0x67337874), 0 kb/s (default)", {type:"Subtitle",codec:"mov_text",lang:"eng"}],
  ["ff7 mkv subtitle srt",    "  Stream #0:3(eng): Subtitle: subrip (default)", {type:"Subtitle",codec:"subrip",lang:"eng"}],
  ["ff7 dts geen default",    "  Stream #0:2(fre): Audio: dts (DTS), 48000 Hz, 5.1(side), fltp, 1536 kb/s", {type:"Audio",codec:"dts",lang:"fre",def:false,pixfmt:"48000 Hz",fmt:"5.1(side)"}],
  ["ff4 oud formaat",         "    Stream #0:1(eng): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 128 kb/s (default)", {type:"Audio",codec:"aac",lang:"eng",def:true,pixfmt:"48000 Hz",fmt:"stereo"}],
  ["ff7 ts aac zonder lang",  "  Stream #0:1[0x101]: Audio: aac (LC) ([15][0][0][0] / 0x000F), 48000 Hz, stereo, fltp, 128 kb/s", {type:"Audio",codec:"aac",lang:"und",def:false,pixfmt:"48000 Hz",fmt:"stereo"}],
];
var fail = 0;
cases.forEach(function (c) {
  var m = c[1].match(re), e = c[2], g = m && {lang:m[2]||"und", type:m[3], codec:m[4], def:!!m[9], pixfmt:m[6], fmt:m[7]};
  var bad = !m || Object.keys(e).some(function (k) { return String(g[k]) !== String(e[k]); });
  if (bad) fail++;
  console.log((bad ? "FAIL " : "ok   ") + c[0] + (bad ? "  -> " + JSON.stringify(g) : ""));
});
console.log(fail ? "FOUT: " + fail : "ALLE " + cases.length + " CASES OK");
process.exit(fail ? 1 : 0);
