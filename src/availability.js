// Staff availability. Everyone is available 24/7 unless they've set working hours,
// a day off, or a holiday for that date.
const { query } = require('./db');
const { ukDate, ukTime, addDays } = require('./format');

const isoOf = (d) => (typeof d === 'string' ? d.slice(0, 10) : ukDate(d));
const validTime = (t) => /^([01]\d|2[0-3]):[0-5]\d$/.test(t || '') || t === '24:00';

async function loadAvailability(userIds, fromISO, toISO) {
  const ids = [...new Set(userIds.map(Number).filter(Boolean))];
  const out = Object.fromEntries(ids.map((id) => [id, { days: {}, off: [] }]));
  if (!ids.length) return out;
  const days = (await query(
    `SELECT user_id, to_char(date, 'YYYY-MM-DD') AS date, kind, start_time, end_time FROM staff_availability
     WHERE user_id = ANY($1) AND date BETWEEN $2::date AND $3::date`, [ids, fromISO, toISO])).rows;
  for (const d of days) out[d.user_id].days[d.date] = d;
  const off = (await query(
    `SELECT id, user_id, to_char(start_date, 'YYYY-MM-DD') AS start_date, to_char(end_date, 'YYYY-MM-DD') AS end_date, note FROM staff_time_off
     WHERE user_id = ANY($1) AND end_date >= $2::date AND start_date <= $3::date`, [ids, fromISO, toISO])).rows;
  for (const o of off) out[o.user_id].off.push(o);
  return out;
}

// What a person's day looks like: any time, set hours, a day off, or holiday.
function dayStatus(av, userId, iso) {
  const a = av[userId];
  if (!a) return { state: 'any' };
  const hol = a.off.find((o) => o.start_date <= iso && iso <= o.end_date);
  if (hol) return { state: 'holiday', note: hol.note };
  const d = a.days[iso];
  if (!d) return { state: 'any' };
  if (d.kind === 'off') return { state: 'off' };
  return { state: 'hours', start: d.start_time, end: d.end_time };
}

// Is the person working for the whole of [start, end)? Both are Date instants.
function freeBetween(av, userId, start, end) {
  const iso = ukDate(start);
  const st = dayStatus(av, userId, iso);
  if (st.state === 'any') return true;
  if (st.state !== 'hours') return false;
  const from = ukTime(iso, st.start).getTime();
  const to = st.end === '24:00' ? ukTime(addDays(iso, 1), '00:00').getTime() : ukTime(iso, st.end).getTime();
  return start.getTime() >= from && end.getTime() <= to;
}

// Dates in a range the person is on holiday or not working.
function blockedDates(av, userId, fromISO, toISO) {
  const out = [];
  for (let d = fromISO; d <= toISO; d = addDays(d, 1)) {
    const st = dayStatus(av, userId, d);
    if (st.state === 'holiday' || st.state === 'off') out.push({ date: d, state: st.state });
  }
  return out;
}

const statusLabel = (st) => (st.state === 'holiday' ? `Holiday${st.note ? `: ${st.note}` : ''}`
  : st.state === 'off' ? 'Not working' : st.state === 'hours' ? `${st.start} to ${st.end}` : '');

module.exports = { loadAvailability, dayStatus, freeBetween, blockedDates, statusLabel, validTime, isoOf };
