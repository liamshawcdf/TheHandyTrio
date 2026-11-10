// Builders set their own working hours, days off and holidays. The office can do it for anyone.
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { day, ukDate, addDays } = require('../format');
const { loadAvailability, dayStatus, validTime } = require('../availability');
const { notifyOffice } = require('../notify');
const { baseUrlOf } = require('../jobs-shared');

const router = express.Router();
const staff = requireRole('admin', 'builder');
const isDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d || '');
const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const weekday = (iso) => new Date(`${iso}T12:00:00Z`).getUTCDay();
const dayLabel = (iso) => new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' });

// Builders manage their own; the office can pick anyone on the team.
async function whoFor(req, raw) {
  if (req.user.role !== 'admin') return { id: req.user.id, name: req.user.name };
  const id = Number(raw) || req.user.id;
  return (await query("SELECT id, name FROM users WHERE id = $1 AND role IN ('builder', 'admin', 'manager')", [id])).rows[0] || { id: req.user.id, name: req.user.name };
}
const backTo = (who, month, extra = '') => `/availability?user=${who.id}${month ? `&month=${month}` : ''}${extra}`;

router.get('/availability', staff, wrap(async (req, res) => {
  const who = await whoFor(req, req.query.user);
  const today = ukDate(new Date());
  const month = /^\d{4}-\d{2}$/.test(req.query.month || '') ? req.query.month : today.slice(0, 7);
  const first = `${month}-01`;
  const next = addDays(addDays(first, 32).slice(0, 7) + '-01', 0);
  const last = addDays(next, -1);
  const prev = addDays(first, -1).slice(0, 7);
  const av = await loadAvailability([who.id], first, last);
  const holidays = (await query(
    `SELECT id, to_char(start_date, 'YYYY-MM-DD') AS s, to_char(end_date, 'YYYY-MM-DD') AS e, note FROM staff_time_off
     WHERE user_id = $1 AND end_date >= current_date - 30 ORDER BY start_date`, [who.id])).rows;

  const staffPick = req.user.role === 'admin' ? `<form method="get" action="/availability" class="filters">
      <label>Person<select name="user">${(await query("SELECT id, name FROM users WHERE role IN ('builder', 'admin', 'manager') AND active ORDER BY name")).rows
        .map((u) => `<option value="${u.id}" ${u.id === who.id ? 'selected' : ''}>${esc(u.name)}</option>`).join('')}</select></label>
      <input type="hidden" name="month" value="${month}"><button class="small">Show</button></form>` : '';

  const days = [];
  for (let d = first; d <= last; d = addDays(d, 1)) days.push(d);
  const rows = days.map((d) => {
    const st = dayStatus(av, who.id, d);
    const past = d < today;
    if (st.state === 'holiday') {
      return `<div class="avrow holiday ${past ? 'past' : ''}"><span class="avday">${dayLabel(d)}</span><span class="tag urgent">Holiday</span><span class="muted">${esc(st.note || '')}</span></div>`;
    }
    const kind = st.state === 'hours' ? 'hours' : st.state === 'off' ? 'off' : 'any';
    return `<div class="avrow ${kind} ${past ? 'past' : ''} ${weekday(d) === 0 || weekday(d) === 6 ? 'weekend' : ''}">
      <span class="avday">${dayLabel(d)}</span>
      <select name="k_${d}" ${past ? 'disabled' : ''}>
        <option value="any" ${kind === 'any' ? 'selected' : ''}>Any time</option>
        <option value="hours" ${kind === 'hours' ? 'selected' : ''}>Set hours</option>
        <option value="off" ${kind === 'off' ? 'selected' : ''}>Not working</option>
      </select>
      <input type="time" name="s_${d}" value="${esc(st.start || '')}" step="900" ${past ? 'disabled' : ''} aria-label="Start">
      <input type="time" name="e_${d}" value="${esc(st.end || '')}" step="900" ${past ? 'disabled' : ''} aria-label="Finish">
    </div>`;
  }).join('');

  const body = `${staffPick}
    <p class="lead">${req.user.role === 'admin' && who.id !== req.user.id ? esc(who.name) + ' is' : 'You’re'} treated as available any time, day or night, unless a day is set otherwise here. Inspection bookings and job bookings respect this.</p>
    <div class="twocol">
      <section>
        <nav class="weeknav">
          <a class="button" href="${backTo(who, prev)}">Previous month</a>
          <a class="button" href="${backTo(who, today.slice(0, 7))}">This month</a>
          <a class="button" href="${backTo(who, next.slice(0, 7))}">Next month</a>
        </nav>
        <h2>${new Date(`${first}T12:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })}</h2>
        <form method="post" action="/availability" class="avmonth">
          <input type="hidden" name="user" value="${who.id}"><input type="hidden" name="month" value="${month}">
          ${rows}
          <button class="primary">Save this month</button>
        </form>
      </section>
      <section>
        <h2>Fill lots of days at once</h2>
        <form method="post" action="/availability/fill" class="panel">
          <input type="hidden" name="user" value="${who.id}"><input type="hidden" name="month" value="${month}">
          <div class="row"><label>From<input type="date" name="from" value="${today}" required></label><label>To<input type="date" name="to" value="${addDays(today, 27)}" required></label></div>
          <p class="fieldlabel">On these days</p>
          <div class="dows">${[1, 2, 3, 4, 5, 6, 0].map((i) => `<label class="check"><input type="checkbox" name="dow" value="${i}" ${i >= 1 && i <= 5 ? 'checked' : ''}> ${DOW[i]}</label>`).join('')}</div>
          <label>Set to<select name="kind"><option value="hours">Working hours</option><option value="off">Not working</option><option value="any">Any time (clear)</option></select></label>
          <div class="row"><label>Start<input type="time" name="start" value="08:00" step="900"></label><label>Finish<input type="time" name="end" value="17:00" step="900"></label></div>
          <p class="hint">For example: full time Mon to Fri 06:00 to 21:00, or part time Tue and Thu 09:00 to 14:00, for the next 4 weeks.</p>
          <button class="primary">Apply</button>
        </form>

        <h2>Holidays</h2>
        <form method="post" action="/availability/holiday" class="panel">
          <input type="hidden" name="user" value="${who.id}"><input type="hidden" name="month" value="${month}">
          <div class="row"><label>First day off<input type="date" name="from" required></label><label>Last day off<input type="date" name="to" required></label></div>
          <label>Note (optional)<input name="note" maxlength="100" placeholder="Holiday, training, appointment"></label>
          <button class="primary">Book time off</button>
        </form>
        ${holidays.length ? `<ul class="certlist">${holidays.map((h) => `<li><strong>${day(h.s)}${h.e !== h.s ? ` to ${day(h.e)}` : ''}</strong> <span class="muted">${esc(h.note || '')}</span>
          <form method="post" action="/availability/holiday/${h.id}/delete" class="inline"><input type="hidden" name="user" value="${who.id}"><input type="hidden" name="month" value="${month}"><button class="small">Remove</button></form></li>`).join('')}</ul>`
          : '<p class="empty">No time off booked.</p>'}
      </section>
    </div>`;
  const notice = req.query.saved ? 'Saved.' : req.query.clash ? 'Time off booked. It clashes with some bookings, so the office has been told.' : null;
  res.send(page({ title: who.id === req.user.id ? 'My availability' : `Availability: ${who.name}`, user: req.user, notice, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
}));

async function setDay(userId, iso, kind, start, end) {
  if (kind === 'any') return query('DELETE FROM staff_availability WHERE user_id = $1 AND date = $2', [userId, iso]);
  return query(
    `INSERT INTO staff_availability (user_id, date, kind, start_time, end_time) VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (user_id, date) DO UPDATE SET kind = EXCLUDED.kind, start_time = EXCLUDED.start_time, end_time = EXCLUDED.end_time`,
    [userId, iso, kind, kind === 'hours' ? start : null, kind === 'hours' ? end : null]);
}
const hoursOk = (s, e) => validTime(s) && validTime(e) && s < e;

router.post('/availability', staff, wrap(async (req, res) => {
  const who = await whoFor(req, req.body.user);
  const month = /^\d{4}-\d{2}$/.test(req.body.month || '') ? req.body.month : '';
  const today = ukDate(new Date());
  let bad = 0;
  for (const [k, v] of Object.entries(req.body)) {
    const m = k.match(/^k_(\d{4}-\d{2}-\d{2})$/);
    if (!m || m[1] < today || (month && !m[1].startsWith(month))) continue;
    const iso = m[1];
    const kind = ['any', 'hours', 'off'].includes(v) ? v : 'any';
    const s = req.body[`s_${iso}`];
    const e = req.body[`e_${iso}`];
    if (kind === 'hours' && !hoursOk(s, e)) { bad++; continue; }
    await setDay(who.id, iso, kind, s, e);
  }
  res.redirect(backTo(who, month, bad ? `&error=${encodeURIComponent(`${bad} day${bad === 1 ? '' : 's'} with set hours need a start before the finish, so weren’t changed.`)}` : '&saved=1'));
}));

router.post('/availability/fill', staff, wrap(async (req, res) => {
  const who = await whoFor(req, req.body.user);
  const { from, to, kind, start, end } = req.body;
  const dows = [].concat(req.body.dow || []).map(Number);
  if (!isDate(from) || !isDate(to) || from > to) return res.redirect(backTo(who, req.body.month, `&error=${encodeURIComponent('Choose a from and to date.')}`));
  if (!['any', 'hours', 'off'].includes(kind)) return res.redirect(backTo(who, req.body.month));
  if (kind === 'hours' && !hoursOk(start, end)) return res.redirect(backTo(who, req.body.month, `&error=${encodeURIComponent('The start time must be before the finish time.')}`));
  const today = ukDate(new Date());
  let n = 0;
  for (let d = from < today ? today : from; d <= to && n < 400; d = addDays(d, 1)) {
    if (!dows.includes(weekday(d))) continue;
    await setDay(who.id, d, kind, start, end);
    n++;
  }
  res.redirect(backTo(who, from.slice(0, 7), '&saved=1'));
}));

router.post('/availability/holiday', staff, wrap(async (req, res) => {
  const who = await whoFor(req, req.body.user);
  const { from, to } = req.body;
  if (!isDate(from) || !isDate(to) || from > to) return res.redirect(backTo(who, req.body.month, `&error=${encodeURIComponent('Choose the first and last day off.')}`));
  const note = String(req.body.note || '').trim().slice(0, 100) || null;
  await query('INSERT INTO staff_time_off (user_id, start_date, end_date, note) VALUES ($1, $2, $3, $4)', [who.id, from, to, note]);

  // Tell the office about anything already booked in those dates.
  const clashes = (await query(
    `SELECT id, title, 'job' AS what FROM jobs WHERE status IN ('scheduled', 'in_progress', 'parts_ordered') AND assigned_builder_id = $1
       AND scheduled_start <= $3::date AND coalesce(scheduled_end, scheduled_start) >= $2::date
     UNION ALL
     SELECT id, title, 'inspection' FROM jobs WHERE status = 'inspection_booked' AND inspection_builder_id = $1
       AND (inspection_at AT TIME ZONE 'Europe/London')::date BETWEEN $2::date AND $3::date`, [who.id, from, to])).rows;
  await notifyOffice(`${who.name} has booked time off: ${day(from)}${to !== from ? ` to ${day(to)}` : ''}`,
    `${who.name} won’t be working ${day(from)}${to !== from ? ` to ${day(to)}` : ''}${note ? ` (${note})` : ''}.${clashes.length
      ? `\n\nThese bookings clash and need moving:\n${clashes.map((c) => `- ${c.what === 'job' ? 'Job' : 'Inspection'}: ${c.title} ${baseUrlOf(req)}/jobs/${c.id}`).join('\n')}`
      : '\n\nNothing already booked clashes.'}`);
  res.redirect(backTo(who, from.slice(0, 7), clashes.length ? '&clash=1' : '&saved=1'));
}));

router.post('/availability/holiday/:id/delete', staff, wrap(async (req, res) => {
  const who = await whoFor(req, req.body.user);
  await query('DELETE FROM staff_time_off WHERE id = $1 AND user_id = $2', [Number(req.params.id) || 0, who.id]);
  res.redirect(backTo(who, req.body.month, '&saved=1'));
}));

module.exports = router;
