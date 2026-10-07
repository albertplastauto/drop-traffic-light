/* Phase-logic tests. Run:
     <bundled-node> test-logic.mjs

   Drop Traffic Light - Author: Albert Kadantsev

   The logic is extracted straight out of index.html between the
   ==LOGIC-START/END== markers, so what is tested is exactly what the widget
   runs.

   Two zones are involved and the suite keeps them apart:

     * the schedule lives in its home zone (UTC+3, no daylight saving), and
       every expectation below is written in those wall-clock terms;
     * the dial speaks the device's own zone, so anything that checks what the
       widget displays is compared against the device-local rendering of the
       same instant.

   Nothing here therefore depends on the zone the test machine runs in: the
   suite passes in any of them. To prove it, run it with a different zone, e.g.
     TZ=Europe/Berlin node test-logic.mjs
     TZ=Australia/Sydney node test-logic.mjs
   Both must report 0 failures. */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const html = fs.readFileSync(path.join(here, 'index.html'), 'utf8');

const a = html.indexOf('// ==LOGIC-START==');
const b = html.indexOf('// ==LOGIC-END==');
if (a < 0 || b < 0) { console.error('LOGIC markers not found in index.html'); process.exit(2); }

const L = new Function(html.slice(a, b) +
  '\n;return { hhmm, pad2, daySegments, timeline, sample, mixHsl, STATES, BLEND, REF_OFFSET_MIN, dialShift, LEAD_INK_U };')();

const REF = L.REF_OFFSET_MIN;                       // minutes east of UTC
const DAY = 86400000;

/* T(...) - an instant on the schedule's home-zone clock */
const T = (y, mo, d, h = 0, mi = 0, s = 0) =>
  Date.UTC(y, mo - 1, d, h, mi, s) - REF * 60000;
/* home-zone wall clock of an instant (read with getUTC*) */
const hz = (ms) => new Date(ms + REF * 60000);
/* what the dial shows for an instant: device-local HH:MM */
const dial = (ms) => {
  const d = new Date(ms);
  return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
};

let pass = 0, fail = 0;
const ok = (cond, name, extra = '') => {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra ? '  -> ' + extra : '')); }
};
const eq = (got, want, name) => ok(got === want, name, `got ${got}, expected ${want}`);
const near = (got, want, eps, name) =>
  ok(Math.abs(got - want) <= eps, name, `got ${got}, expected ${want}+-${eps}`);
const hd = (ms) => ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][hz(ms).getUTCDay()];

const at = (t) => L.sample(t);

/* ---------------------------------------------------------------- */
console.log('\n[0] Test machine zone: ' + Intl.DateTimeFormat().resolvedOptions().timeZone +
            '   (schedule home zone: UTC+' + (REF / 60) + ')');

console.log('\n[1] Weekday mapping (schedule home zone)');
eq(hd(T(2026, 10, 7)),  'Wed', '2026-10-07 is a Wednesday');
eq(hd(T(2026, 10, 10)), 'Sat', '2026-10-10 is a Saturday');
eq(hd(T(2026, 10, 12)), 'Mon', '2026-10-12 is a Monday');

console.log('\n[2] Phase boundaries (home-zone time)');
const cases = [
  [T(2026, 10, 7, 0, 0),  'green',  '00:00 off-peak'],
  [T(2026, 10, 7, 1, 56), 'green',  '01:56 off-peak'],
  [T(2026, 10, 7, 2, 59, 59), 'green', '02:59:59 still off-peak'],
  [T(2026, 10, 7, 3, 0),  'yellow', '03:00 yellow (hour before the peak)'],
  [T(2026, 10, 7, 3, 59, 59), 'yellow', '03:59:59 still yellow'],
  [T(2026, 10, 7, 4, 0),  'red',    '04:00 peak'],
  [T(2026, 10, 7, 5, 59), 'red',    '05:59 peak'],
  [T(2026, 10, 7, 6, 0),  'aqua',   '06:00 turquoise (hour before the peak ends)'],
  [T(2026, 10, 7, 6, 59, 59), 'aqua', '06:59:59 still turquoise'],
  [T(2026, 10, 7, 7, 0),  'green',  '07:00 off-peak'],
  [T(2026, 10, 7, 7, 59), 'green',  '07:59 off-peak'],
  [T(2026, 10, 7, 8, 0),  'yellow', '08:00 yellow (hour before the peak)'],
  [T(2026, 10, 7, 9, 0),  'red',    '09:00 peak'],
  [T(2026, 10, 7, 11, 59),'red',    '11:59 peak'],
  [T(2026, 10, 7, 12, 0), 'aqua',   '12:00 turquoise'],
  [T(2026, 10, 7, 12, 59, 59), 'aqua', '12:59:59 still turquoise'],
  [T(2026, 10, 7, 13, 0), 'green',  '13:00 off-peak'],
  [T(2026, 10, 7, 23, 59),'green',  '23:59 off-peak'],
];
for (const [t, want, name] of cases) eq(at(t).state, want, name);

console.log('\n[3] Weekends are off-peak all the way through');
eq(at(T(2026, 10, 10, 4, 30)).state, 'green', 'Sat 04:30 off-peak (no peak at all)');
eq(at(T(2026, 10, 10, 10, 0)).state, 'green', 'Sat 10:00 off-peak');
eq(at(T(2026, 10, 11, 12, 30)).state, 'green', 'Sun 12:30 off-peak');
eq(at(T(2026, 10, 11, 3, 30)).state, 'green', 'Sun 03:30 off-peak (no yellow either)');
eq(at(T(2026, 10, 12, 3, 0)).state, 'yellow', 'Mon 03:00 yellow');

console.log('\n[4] Countdown to the next change');
eq(at(T(2026, 10, 7, 1, 56)).cdText, '01:04', '01:56 -> 03:00 = 01:04');
eq(at(T(2026, 10, 7, 4, 0)).cdText,  '02:00', '04:00 -> 06:00 = 02:00');
eq(at(T(2026, 10, 7, 6, 0)).cdText,  '01:00', '06:00 -> 07:00 = 01:00');
eq(at(T(2026, 10, 7, 8, 0)).cdText,  '01:00', '08:00 -> 09:00 = 01:00');
eq(at(T(2026, 10, 7, 12, 0)).cdText, '01:00', '12:00 -> 13:00 = 01:00');
eq(at(T(2026, 10, 7, 13, 0)).cdText, '14:00', 'Wed 13:00 -> Thu 03:00 = 14:00');
eq(at(T(2026, 10, 9, 13, 0)).cdText, '62:00', 'Fri 13:00 -> Mon 03:00 = 62:00');
ok(/^\d{2,3}:\d{2}$/.test(at(T(2026, 10, 9, 13, 0)).cdText), 'HH:MM shape (2-3 digit hours)');
eq(at(T(2026, 10, 7, 1, 56)).name, 'OFF-PEAK', 'current phase is OFF-PEAK');
eq(at(T(2026, 10, 7, 3, 30)).name, 'BEFORE PEAK', 'at 03:30 the phase is BEFORE PEAK');
eq(at(T(2026, 10, 7, 10, 0)).name, 'PEAK \u00b7 RESTRICTED', 'at 10:00 the phase is PEAK');
eq(at(T(2026, 10, 7, 6, 30)).name, 'PEAK ENDING', 'at 06:30 the phase is PEAK ENDING');
ok(Math.abs(at(T(2026, 10, 7, 1, 56)).color.h - 152) < 0.5, 'away from a boundary the colour is pure');

console.log('\n[5] The dial speaks the device zone, whatever it is');
for (const hour of [1, 4, 9, 13, 23]) {
  const t = T(2026, 10, 7, hour, 5);
  eq(at(t).clockText, dial(t), 'clockText at home ' + hour + ':05 is the device-local time');
}
eq(at(T(2026, 10, 7, 1, 56)).nextText, dial(T(2026, 10, 7, 3, 0)),
   'the announced next change is the device-local rendering of it');
eq(L.pad2(7), '07', 'pad2(7) = 07');

console.log('\n[6] Phase progress');
near(at(T(2026, 10, 7, 5, 0)).progress, 0.5, 1e-9, '05:00 inside 04:00-06:00 = 50%');
near(at(T(2026, 10, 7, 4, 0)).progress, 0, 1e-9, 'start of a phase = 0%');
near(at(T(2026, 10, 7, 3, 30)).progress, 0.5, 1e-9, '03:30 inside 03:00-04:00 = 50%');

console.log('\n[7] Colour is continuous across every boundary');
const hueDist = (x, y) => Math.abs(((y - x + 540) % 360) - 180);
let maxStep = 0, worstAt = null;
for (const t0 of [T(2026, 10, 7, 2, 58, 0), T(2026, 10, 7, 3, 58, 0), T(2026, 10, 7, 5, 58, 0),
                  T(2026, 10, 7, 6, 58, 0), T(2026, 10, 7, 8, 58, 0), T(2026, 10, 7, 11, 58, 0),
                  T(2026, 10, 7, 12, 58, 0)]) {
  for (let k = 0; k < 240; k++) {
    const c1 = at(t0 + k * 1000).color, c2 = at(t0 + (k + 1) * 1000).color;
    const d = hueDist(c1.h, c2.h);
    if (d > maxStep) { maxStep = d; worstAt = hz(t0 + k * 1000).toISOString(); }
  }
}
ok(maxStep <= 4, 'hue moves no faster than 4 deg per second (smooth fade)',
   `max ${maxStep.toFixed(2)} deg (${worstAt})`);
const c3 = at(T(2026, 10, 7, 3, 0, 0)).color;
ok(hueDist(c3.h, 45) > 5 && hueDist(c3.h, 152) > 5, 'at 03:00 the colour is between green and yellow', 'h=' + c3.h.toFixed(1));
const c4 = at(T(2026, 10, 7, 4, 0, 0)).color;
ok(hueDist(c4.h, 45) > 5 && hueDist(c4.h, 354) > 5, 'at 04:00 the colour is between yellow and red', 'h=' + c4.h.toFixed(1));

console.log('\n[8] The phase track has no gaps and no overlaps');
{
  let bad = 0;
  for (let d = 0; d < 8; d++) {
    const segs = L.timeline(T(2026, 10, 5) + d * DAY);
    for (let i = 1; i < segs.length; i++) if (segs[i].start !== segs[i - 1].end) bad++;
    for (const s of segs) if (s.end <= s.start) bad++;
  }
  eq(bad, 0, 'slices join exactly across 8 days');
}

console.log('\n[9] Full week sweep, one minute per step (home-zone table)');
{
  const counts = { green: 0, yellow: 0, red: 0, aqua: 0 };
  const wrong = [];
  const expect = (wd, h, m) => {
    if (wd === 0 || wd === 6) return 'green';
    const x = h * 60 + m;
    if (x >= 180 && x < 240) return 'yellow';
    if (x >= 240 && x < 360) return 'red';
    if (x >= 360 && x < 420) return 'aqua';
    if (x >= 420 && x < 480) return 'green';
    if (x >= 480 && x < 540) return 'yellow';
    if (x >= 540 && x < 720) return 'red';
    if (x >= 720 && x < 780) return 'aqua';
    return 'green';
  };
  let t = T(2026, 10, 5);
  for (let k = 0; k < 7 * 24 * 60; k++, t += 60000) {
    const d = hz(t);
    const want = expect(d.getUTCDay(), d.getUTCHours(), d.getUTCMinutes());
    const got = at(t).state;
    counts[got]++;
    if (got !== want && wrong.length < 3) wrong.push(`${d.toISOString()} want ${want} got ${got}`);
  }
  eq(wrong.length, 0, 'all 10080 minutes of the week match the table', wrong.join('; '));
  console.log('       minutes per phase: ' + JSON.stringify(counts));
}

console.log('\n[10] The schedule is converted to the device zone, not copied from it');
eq(T(2026, 10, 7, 4, 0), Date.UTC(2026, 9, 7, 1, 0), 'peak start 04:00 home zone = 01:00 UTC');
eq(at(Date.UTC(2026, 9, 7, 1, 0)).state, 'red', 'that same instant is the peak');
eq(at(Date.UTC(2026, 9, 7, 0, 59, 59)).state, 'yellow', 'one second earlier it is still yellow');
eq(T(2026, 10, 7, 13, 0) - T(2026, 10, 7, 9, 0), 4 * 3600 * 1000, 'the 09:00-13:00 window lasts four hours');
eq(T(2026, 10, 10, 4, 0) - T(2026, 10, 7, 13, 0), 63 * 3600 * 1000, 'off-peak runs 63 hours to Monday 04:00');
{
  const marks = [4, 6, 7, 9, 13];
  let ok2 = true;
  for (const h of marks) {
    const t = T(2026, 10, 7, h, 0);
    if (at(t - 1).state === at(t).state) ok2 = false;
  }
  ok(ok2, 'every home-zone hour mark really is a state change');
}

console.log('\n[11] The dial keeps equal visible margins for every leading digit');
{
  /* The row is centred, so nudging it left by s takes s off the left margin and
     adds s to the right one. Equal margins therefore need s = -ink / 2. */
  let bad = 0;
  for (let d = 0; d <= 9; d++) {
    const lead = String(d);
    const s = L.dialShift(lead + '0:00');
    const left = L.LEAD_INK_U[lead] + s;     // margins relative to the cell edge
    const right = -s;
    if (Math.abs(left - right) > 1e-9) { bad++; console.log('       leading ' + lead + ' off by ' + (left - right)); }
  }
  eq(bad, 0, 'left margin equals right margin for all ten leading digits');
  near(L.dialShift('14:30'), -3.175, 1e-9, 'a leading "1" is nudged left by half its ink offset');
  eq(L.dialShift('20:00'), 0, 'a leading "2" needs no nudge');
  eq(L.dialShift('13:51'), -3.175, 'the nudge follows the digit, not the value');
}

console.log(`\nResult: ${pass} ok, ${fail} fail\n`);
process.exit(fail ? 1 : 0);
