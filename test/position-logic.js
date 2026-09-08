
function make() { return { seekTime: 0, _absTime: undefined, mediaStatus: {} }; }
function report(dev, seconds) {
  var value = String(seconds), field = "time";
  var this_ = dev;
  (function () { var _t = 1e3 * parseInt(value, 10), _s = this.seekTime || 0; if (_s > 3e4 && this._absTime === undefined) this._absTime = _t >= _s - 5e3; this.mediaStatus[field] = this._absTime === false ? _s + _t : (_t >= _s ? _t : _s + _t); }).call(this_);
  return dev.mediaStatus.time;
}
var fail = 0;
function check(name, dev, seek, reports, expected) {
  dev.seekTime = seek * 1000;
  var got = null;
  reports.forEach(function (r) { got = report(dev, r); });
  var ok = Math.round(got / 1000) === expected;
  if (!ok) fail++;
  console.log("  " + (ok ? "ok   " : "FAIL ") + name + ": " + Math.round(got/1000) + "s (verwacht " + expected + ")");
}
// tv die absolute tijd meldt (zoals de LG met -copyts)
check("absolute tv, sprong 877s, dan 892", make(), 877, [877, 892], 892);
// tv die vanaf nul telt, grote sprong: wordt herkend
check("relatieve tv, sprong 877s, dan 15", make(), 877, [0, 15], 892);
// korte sprong bij een tv die al herkend is als relatief
var d = make(); d.seekTime = 877000; report(d, 0); report(d, 15);
d.seekTime = 5000; var got = report(d, 10);
var ok = Math.round(got/1000) === 15;
if (!ok) fail++;
console.log("  " + (ok ? "ok   " : "FAIL ") + "korte sprong na herkenning: " + Math.round(got/1000) + "s (verwacht 15)");
// geen sprong
check("geen sprong, 30s", make(), 0, [30], 30);
console.log(fail ? "  " + fail + " mislukt" : "  PASS: alle gevallen kloppen, ook het randgeval");
process.exit(fail ? 1 : 0);
