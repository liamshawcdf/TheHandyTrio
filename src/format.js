// Dates and times always show in UK time, whatever time zone the server runs in.
const TZ = 'Europe/London';
const pad = (n) => String(n).padStart(2, '0');

const ref = (id) => 'HT-' + String(id).padStart(5, '0');
const day = (d) => (d ? new Date(d).toLocaleDateString('en-GB', { timeZone: TZ, day: 'numeric', month: 'short', year: 'numeric' }) : '');
const when = (d) => (d ? new Date(d).toLocaleString('en-GB', { timeZone: TZ, day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '');
const longWhen = (d) => (d ? new Date(d).toLocaleString('en-GB', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long', hour: 'numeric', minute: '2-digit', hour12: true }).replace(' at ', ' at ') : '');
const timeOnly = (d) => new Date(d).toLocaleTimeString('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit' });

// The calendar date (YYYY-MM-DD) of an instant, in UK time.
const ukDate = (d) => new Date(d).toLocaleDateString('en-CA', { timeZone: TZ });

// Minutes the UK is ahead of UTC at a given instant (0 in winter, 60 in summer).
function ukOffset(date) {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: TZ, hour12: false, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(date);
  const g = (t) => Number(parts.find((p) => p.type === t).value);
  return (Date.UTC(g('year'), g('month') - 1, g('day'), g('hour') % 24, g('minute'), g('second')) - date.getTime()) / 60000;
}

// The instant of a UK wall-clock time, e.g. ukTime('2026-07-01', '09:30').
function ukTime(dateISO, hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  const guess = new Date(`${dateISO}T${pad(h)}:${pad(m)}:00Z`);
  return new Date(guess.getTime() - ukOffset(guess) * 60000);
}

// Adds whole days to a YYYY-MM-DD date.
function addDays(dateISO, n) {
  const d = new Date(`${dateISO}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

const WORK_TYPES = [
  'Carpentry and joinery',
  'Doors and windows',
  'Plumbing',
  'Electrical',
  'Painting and decorating',
  'Tiling and flooring',
  'Plastering',
  'Fencing, decking and garden',
  'Roofing and guttering',
  'Something else',
];

module.exports = { TZ, ref, day, when, longWhen, timeOnly, ukDate, ukTime, ukOffset, addDays, WORK_TYPES };
