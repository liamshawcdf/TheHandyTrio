// The calendar: inspection booking (by customers or the office), the week view,
// and a live calendar feed for phones (iPhone, Google, Outlook).
const express = require('express');
const crypto = require('crypto');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day, longWhen, timeOnly, ukDate, ukTime, addDays } = require('../format');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange, notifyOffice } = require('../notify');
const { locate } = require('../estimate');

const router = express.Router();
const staff = requireRole('admin', 'builder');
const N = (x) => Number(x) || 0;
const DAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const BOOKABLE = ['request', 'estimated', 'inspection_required', 'inspection_booked'];
const ACTIVE_WORK = ['scheduled', 'in_progress', 'parts_ordered'];
const validTime = (t, fallback) => (/^([01]\d|2[0-3]):[0-5]\d$/.test(t || '') ? t : fallback);
const weekdayOf = (iso) => new Date(`${iso}T12:00:00Z`).getUTCDay();

// ======================= Inspection slots =======================
async function bookingRules() {
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const days = String(s.inspection_days || '').split(/[\s,]+/).map((d) => DAY_NAMES.findIndex((n) => n.toLowerCase() === d.slice(0, 3).toLowerCase())).filter((i) => i >= 0);
  return {
    s,
    days: days.length ? days : [1, 2, 3, 4, 5],
    start: validTime(s.inspection_start, '09:00'),
    end: validTime(s.inspection_end, '16:00'),
    slot: Math.min(240, Math.max(15, N(s.inspection_slot_minutes) || 60)),
    notice: Math.max(0, N(s.inspection_notice_hours)),
    horizon: Math.min(90, Math.max(1, N(s.inspection_horizon_days) || 21)),
  };
}

// Every open slot from now to the booking horizon, with the builders free for each.
async function openSlots(excludeJobId = 0) {
  const r = await bookingRules();
  const now = Date.now();
  const earliest = now + r.notice * 3600000;
  const today = ukDate(new Date());
  const lastDay = addDays(today, r.horizon);
  const builders = (await query("SELECT id, name, postcode FROM users WHERE role = 'builder' AND active ORDER BY id")).rows;
  const inspections = (await query(
    `SELECT inspection_at, inspection_minutes, inspection_builder_id FROM jobs
     WHERE inspection_at IS NOT NULL AND inspection_at >= now() - interval '1 day' AND id <> $1 AND status NOT IN ('cancelled', 'declined')`, [excludeJobId])).rows;
  const work = (await query(
    `SELECT assigned_builder_id, scheduled_start, coalesce(scheduled_end, scheduled_start) AS scheduled_end FROM jobs
     WHERE status = ANY($1) AND scheduled_start IS NOT NULL AND assigned_builder_id IS NOT NULL`, [ACTIVE_WORK])).rows;
  const busyOnDay = (bid, iso) => work.some((w) => w.assigned_builder_id === bid && ukDate(w.scheduled_start) <= iso && iso <= ukDate(w.scheduled_end));

  const days = [];
  for (let iso = today; iso <= lastDay; iso = addDays(iso, 1)) {
    if (!r.days.includes(weekdayOf(iso))) continue;
    const slots = [];
    const endAt = ukTime(iso, r.end).getTime();
    for (let t = ukTime(iso, r.start).getTime(); t + r.slot * 60000 <= endAt; t += r.slot * 60000) {
      if (t < earliest) continue;
      const tEnd = t + r.slot * 60000;
      const free = builders.filter((b) => !busyOnDay(b.id, iso) && !inspections.some((i) => i.inspection_builder_id === b.id
        && new Date(i.inspection_at).getTime() < tEnd && new Date(i.inspection_at).getTime() + N(i.inspection_minutes) * 60000 > t));
      if (free.length) slots.push({ at: new Date(t), free });
    }
    if (slots.length) days.push({ iso, slots });
  }
  return { rules: r, days };
}

// Of the builders free for a slot, send the one who lives nearest the job.
async function nearestBuilder(free, postcode) {
  const to = await locate(postcode);
  if (!to) return free[0];
  let best = free[0];
  let bestD = Infinity;
  for (const b of free) {
    const from = b.postcode ? await locate(b.postcode) : null;
    if (!from) continue;
    const d = (from.lat - to.lat) ** 2 + ((from.lng - to.lng) * Math.cos((to.lat * Math.PI) / 180)) ** 2;
    if (d < bestD) { bestD = d; best = b; }
  }
  return best;
}

const canBook = (user, job) => BOOKABLE.includes(job.status) && (user.role === 'admin' || (user.role === 'customer' && job.customer_id === user.id));

// ======================= Panel on the job page =======================
async function inspectionPanel(job, user) {
  const r = await bookingRules();
  const booked = job.inspection_at && job.status === 'inspection_booked';
  const lateToChange = booked && new Date(job.inspection_at).getTime() - Date.now() < r.notice * 3600000;
  if (booked) {
    const inspector = job.inspection_builder_id ? (await query('SELECT name FROM users WHERE id = $1', [job.inspection_builder_id])).rows[0] : null;
    const mayChange = canBook(user, job) && (user.role === 'admin' || !lateToChange);
    return `<section class="panel callout" id="inspection">
      <h2>Inspection visit</h2>
      <p class="bigprice">${esc(longWhen(job.inspection_at))}</p>
      <p>${inspector ? `${user.role === 'customer' ? 'With' : 'Inspector:'} ${esc(user.role === 'customer' ? inspector.name.split(' ')[0] : inspector.name)}. ` : ''}About ${N(job.inspection_minutes)} minutes.</p>
      ${mayChange ? `<div class="buttons"><a class="button" href="/jobs/${job.id}/inspection">Change time</a>
        <form method="post" action="/jobs/${job.id}/inspection/cancel" class="inline"><button class="small danger">Cancel visit</button></form></div>`
        : user.role === 'customer' ? '<p class="hint">It’s too close to the visit to change it online. Please call us.</p>' : ''}
    </section>`;
  }
  if (!canBook(user, job) || !['inspection_required', 'estimated', 'request'].includes(job.status)) return '';
  return `<section class="panel callout" id="inspection">
    <h2>${user.role === 'customer' ? 'Book your inspection visit' : 'Inspection visit'}</h2>
    <p>${user.role === 'customer' ? 'Pick a time for us to come and look at the job, so we can give you an exact quote.' : 'Not booked yet.'}</p>
    <a class="button primary" href="/jobs/${job.id}/inspection">${user.role === 'customer' ? 'Choose a time' : 'Book an inspection'}</a>
  </section>`;
}

// ======================= Booking pages =======================
router.get('/jobs/:id/inspection', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !canBook(req.user, job)) return notFound(req, res);
  const { rules, days } = await openSlots(job.id);
  const isAdmin = req.user.role === 'admin';
  const picker = days.length ? days.map((d) => `<div class="slotday">
      <h3>${esc(new Date(`${d.iso}T12:00:00Z`).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' }))}</h3>
      <div class="slots">${d.slots.map((s) => `<form method="post" action="/jobs/${job.id}/inspection" class="inline">
        <input type="hidden" name="at" value="${s.at.toISOString()}"><button class="slot">${timeOnly(s.at)}</button></form>`).join('')}</div>
    </div>`).join('')
    : `<p class="empty">No times are free in the next ${rules.horizon} days. ${isAdmin ? 'Book a time by hand below.' : 'Please call us and we’ll fit you in.'}</p>`;
  const builders = isAdmin ? (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows : [];
  const manual = isAdmin ? `<h2>Book a time by hand</h2>
    <form method="post" action="/jobs/${job.id}/inspection" class="panel schedule">
      <label>Date<input type="date" name="date" required></label>
      <label>Time<input type="time" name="time" required step="300"></label>
      <label>Inspector<select name="builder_id">${builders.map((b) => `<option value="${b.id}" ${b.id === job.assigned_builder_id ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}</select></label>
      <button class="primary">Book</button>
    </form>` : '';
  const body = `<p class="jobhead"><a href="/jobs/${job.id}">Back to the job</a></p>
    <p class="lead">Visits take about ${rules.slot} minutes. ${isAdmin ? 'Tapping a time books the nearest free builder.' : 'Tap a time to book it.'}</p>
    ${picker}${manual}`;
  res.send(page({ title: `Book an inspection: ${job.title}`, user: req.user, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
}));

router.post('/jobs/:id/inspection', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !canBook(req.user, job)) return notFound(req, res);
  const { rules, days } = await openSlots(job.id);
  let at = null;
  let builder = null;

  if (req.user.role === 'admin' && req.body.date) {
    // Office booking by hand: any date and time, any builder.
    if (!/^\d{4}-\d{2}-\d{2}$/.test(req.body.date) || !/^\d{2}:\d{2}$/.test(req.body.time || '')) return res.redirect(`/jobs/${job.id}/inspection?error=${encodeURIComponent('Choose a date and time.')}`);
    at = ukTime(req.body.date, req.body.time);
    builder = (await query("SELECT id, name FROM users WHERE id = $1 AND role = 'builder' AND active", [Number(req.body.builder_id) || 0])).rows[0];
    if (!builder) return res.redirect(`/jobs/${job.id}/inspection?error=${encodeURIComponent('Choose an inspector.')}`);
  } else {
    const wanted = new Date(String(req.body.at || '')).getTime();
    const slot = days.flatMap((d) => d.slots).find((s) => s.at.getTime() === wanted);
    if (!slot) return res.redirect(`/jobs/${job.id}/inspection?error=${encodeURIComponent('Sorry, that time has just gone. Please pick another.')}`);
    at = slot.at;
    builder = await nearestBuilder(slot.free, job.postcode);
  }

  const wasBooked = job.status === 'inspection_booked';
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE jobs SET inspection_at = $1, inspection_minutes = $2, inspection_builder_id = $3, updated_at = now() WHERE id = $4',
      [at, rules.slot, builder.id, job.id]);
    // The inspector needs to open the job.
    if (builder.id !== job.assigned_builder_id) {
      await client.query('INSERT INTO job_team (job_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [job.id, builder.id]);
    }
    await setStatus(client, job.id, job.status, 'inspection_booked', req.user.id,
      `Inspection ${wasBooked ? 'moved to' : 'booked for'} ${longWhen(at)} with ${builder.name}${req.user.role === 'customer' ? ' (booked by the customer)' : ''}`);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyStageChange(job.id, 'inspection_booked', baseUrlOf(req));
  if (req.user.role === 'customer') {
    await notifyOffice(`Inspection ${wasBooked ? 'moved' : 'booked'}: ${job.title} (${ref(job.id)})`,
      `${job.customer_name} ${wasBooked ? 'moved their' : 'booked an'} inspection for ${longWhen(at)}. ${builder.name} has been given it as the nearest free builder.\n\n${baseUrlOf(req)}/jobs/${job.id}`, job.id);
  }
  res.redirect(`/jobs/${job.id}?updated=1#inspection`);
}));

router.post('/jobs/:id/inspection/cancel', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !canBook(req.user, job) || job.status !== 'inspection_booked') return notFound(req, res);
  const r = await bookingRules();
  if (req.user.role !== 'admin' && new Date(job.inspection_at).getTime() - Date.now() < r.notice * 3600000) return res.redirect(`/jobs/${job.id}#inspection`);
  const back = job.estimate_snapshot ? 'estimated' : 'inspection_required';
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE jobs SET inspection_at = NULL, inspection_builder_id = NULL, updated_at = now() WHERE id = $1', [job.id]);
    await setStatus(client, job.id, job.status, back, req.user.id, `Inspection cancelled${req.user.role === 'customer' ? ' by the customer' : ''}`);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyStageChange(job.id, 'inspection_cancelled', baseUrlOf(req));
  if (req.user.role === 'customer') {
    await notifyOffice(`Inspection cancelled: ${job.title} (${ref(job.id)})`, `${job.customer_name} cancelled their inspection visit.\n\n${baseUrlOf(req)}/jobs/${job.id}`, job.id);
  }
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

// ======================= Week view =======================
const mondayOf = (iso) => addDays(iso, -((weekdayOf(iso) + 6) % 7));

async function eventsBetween(fromISO, toISO, userId = null) {
  const who = userId ? 'AND (j.inspection_builder_id = $3)' : '';
  const inspections = (await query(
    `SELECT j.id, j.title, j.postcode, j.address_line, j.town, j.inspection_at, j.inspection_minutes, j.inspection_builder_id AS builder_id,
       c.name AS customer_name, c.phone AS customer_phone
     FROM jobs j JOIN users c ON c.id = j.customer_id
     WHERE j.status = 'inspection_booked' AND j.inspection_at >= $1 AND j.inspection_at < $2 ${who}`,
    userId ? [ukTime(fromISO, '00:00'), ukTime(addDays(toISO, 1), '00:00'), userId] : [ukTime(fromISO, '00:00'), ukTime(addDays(toISO, 1), '00:00')])).rows
    .map((e) => ({ ...e, kind: 'inspection', start: ukDate(e.inspection_at), end: ukDate(e.inspection_at) }));
  const whoW = userId ? 'AND (j.assigned_builder_id = $3 OR j.id IN (SELECT job_id FROM job_team WHERE user_id = $3))' : '';
  const work = (await query(
    `SELECT j.id, j.title, j.postcode, j.address_line, j.town, j.status, j.scheduled_start, coalesce(j.scheduled_end, j.scheduled_start) AS scheduled_end,
       j.assigned_builder_id AS builder_id, c.name AS customer_name, c.phone AS customer_phone
     FROM jobs j JOIN users c ON c.id = j.customer_id
     WHERE j.scheduled_start IS NOT NULL AND j.status NOT IN ('cancelled', 'declined')
       AND j.scheduled_start <= $2::date AND coalesce(j.scheduled_end, j.scheduled_start) >= $1::date ${whoW}`,
    userId ? [fromISO, toISO, userId] : [fromISO, toISO])).rows
    .map((e) => ({ ...e, kind: 'work', start: ukDate(e.scheduled_start), end: ukDate(e.scheduled_end) }));
  return [...inspections, ...work];
}

function eventChip(e) {
  return e.kind === 'inspection'
    ? `<a class="ev insp" href="/jobs/${e.id}"><strong>${timeOnly(e.inspection_at)} Inspection</strong><span>${esc(e.title)}</span><span class="muted">${esc(e.postcode)}</span></a>`
    : `<a class="ev work ${e.status === 'in_progress' ? 'live' : ''}" href="/jobs/${e.id}"><strong>${e.status === 'complete' || e.status === 'invoiced' || e.status === 'paid' ? 'Done' : 'Job'}</strong><span>${esc(e.title)}</span><span class="muted">${esc(e.postcode)}</span></a>`;
}

router.get('/calendar', staff, wrap(async (req, res) => {
  const user = req.user;
  const isAdmin = user.role === 'admin';
  const today = ukDate(new Date());
  const start = mondayOf(/^\d{4}-\d{2}-\d{2}$/.test(req.query.week || '') ? req.query.week : today);
  const days = Array.from({ length: 7 }, (_, i) => addDays(start, i));
  const events = await eventsBetween(days[0], days[6], isAdmin ? null : user.id);
  const sortEv = (a, b) => (a.kind === b.kind ? 0 : a.kind === 'inspection' ? 1 : -1) || (a.inspection_at && b.inspection_at ? new Date(a.inspection_at) - new Date(b.inspection_at) : 0);
  const on = (list, iso) => list.filter((e) => e.start <= iso && iso <= e.end).sort(sortEv);
  const dayHead = (iso) => `${new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' })}`;
  const nav = `<nav class="weeknav">
    <a class="button" href="/calendar?week=${addDays(start, -7)}">Previous week</a>
    <a class="button" href="/calendar">This week</a>
    <a class="button" href="/calendar?week=${addDays(start, 7)}">Next week</a>
  </nav>`;

  let grid;
  if (isAdmin) {
    const builders = (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows;
    grid = `<div class="scroll"><table class="week">
      <thead><tr><th>Builder</th>${days.map((d) => `<th class="${d === today ? 'today' : ''}">${dayHead(d)}</th>`).join('')}</tr></thead>
      <tbody>${builders.map((b) => `<tr><th>${esc(b.name)}</th>${days.map((d) => `<td class="${d === today ? 'today' : ''}">${on(events.filter((e) => e.builder_id === b.id), d).map(eventChip).join('')}</td>`).join('')}</tr>`).join('')}
      </tbody></table></div>`;
  } else {
    grid = `<div class="agenda">${days.map((d) => {
      const list = on(events, d);
      return `<section class="aday ${d === today ? 'today' : ''}"><h3>${dayHead(d)}${d === today ? ' <span class="tag">Today</span>' : ''}</h3>
        ${list.length ? list.map(eventChip).join('') : '<p class="muted">Nothing booked</p>'}</section>`;
    }).join('')}</div>`;
  }

  // Live calendar feed link.
  let token = (await query('SELECT calendar_token FROM users WHERE id = $1', [user.id])).rows[0].calendar_token;
  if (!token) {
    token = crypto.randomBytes(24).toString('hex');
    await query('UPDATE users SET calendar_token = $1 WHERE id = $2', [token, user.id]);
  }
  const httpsUrl = `${baseUrlOf(req)}/calendar/feed/${token}.ics`;
  const webcal = httpsUrl.replace(/^https?:/, 'webcal:');
  const feed = `<details class="panel feed"><summary><strong>Show this in my phone’s calendar</strong></summary>
    <p>Subscribing adds ${isAdmin ? 'every booked job and inspection' : 'your booked jobs and inspections'} to your phone’s calendar, and keeps it up to date automatically.</p>
    <p><a class="button primary" href="${esc(webcal)}">Subscribe on iPhone or Mac</a></p>
    <p class="hint">For Google Calendar or Outlook, choose “Add calendar from URL” and paste this link:</p>
    <input readonly value="${esc(httpsUrl)}">
    <p class="hint">Keep this link private: anyone with it can see the diary. If it gets shared by mistake, make a new one.</p>
    <form method="post" action="/calendar/new-link" class="inline"><button class="small">Make a new link</button></form>
  </details>`;

  const body = `${nav}<h2>Week of ${day(start)}</h2>${grid}${feed}`;
  res.send(page({ title: isAdmin ? 'Calendar' : 'My diary', user, body }));
}));

router.post('/calendar/new-link', staff, wrap(async (req, res) => {
  await query('UPDATE users SET calendar_token = $1 WHERE id = $2', [crypto.randomBytes(24).toString('hex'), req.user.id]);
  res.redirect('/calendar');
}));

// ======================= Calendar feed (.ics) =======================
const icsEscape = (s) => String(s ?? '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
const icsStamp = (d) => new Date(d).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
const icsDate = (iso) => iso.replace(/-/g, '');
function fold(line) {
  const out = [];
  let rest = line;
  while (Buffer.byteLength(rest) > 74) {
    let cut = 74;
    while (Buffer.byteLength(rest.slice(0, cut)) > 74) cut--;
    out.push(rest.slice(0, cut));
    rest = ' ' + rest.slice(cut);
  }
  out.push(rest);
  return out.join('\r\n');
}

router.get('/calendar/feed/:token.ics', wrap(async (req, res) => {
  const token = String(req.params.token || '');
  const u = /^[a-f0-9]{48}$/.test(token) ? (await query("SELECT id, role, name FROM users WHERE calendar_token = $1 AND active AND role IN ('admin', 'builder')", [token])).rows[0] : null;
  if (!u) return res.sendStatus(404);
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  const today = ukDate(new Date());
  const events = await eventsBetween(addDays(today, -30), addDays(today, 180), u.role === 'admin' ? null : u.id);
  const base = baseUrlOf(req);
  const names = Object.fromEntries((await query("SELECT id, name FROM users WHERE role = 'builder'")).rows.map((b) => [b.id, b.name]));
  const now = icsStamp(new Date());
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', `PRODID:-//${s.business_name}//TheHandyTrio//EN`, 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    `X-WR-CALNAME:${icsEscape(`${s.business_name}${u.role === 'admin' ? '' : `: ${u.name}`}`)}`, 'X-PUBLISHED-TTL:PT1H', 'REFRESH-INTERVAL;VALUE=DURATION:PT1H'];
  for (const e of events) {
    const address = [e.address_line, e.town, e.postcode].filter(Boolean).join(', ');
    const desc = `${e.customer_name}${e.customer_phone ? `, ${e.customer_phone}` : ''}${u.role === 'admin' && names[e.builder_id] ? `\nBuilder: ${names[e.builder_id]}` : ''}\n${base}/jobs/${e.id}`;
    lines.push('BEGIN:VEVENT', `UID:job-${e.id}-${e.kind}@thehandytrio`, `DTSTAMP:${now}`);
    if (e.kind === 'inspection') {
      lines.push(`DTSTART:${icsStamp(e.inspection_at)}`, `DTEND:${icsStamp(new Date(new Date(e.inspection_at).getTime() + N(e.inspection_minutes) * 60000))}`,
        `SUMMARY:${icsEscape(`Inspection: ${e.title}${u.role === 'admin' && names[e.builder_id] ? ` (${names[e.builder_id]})` : ''}`)}`);
    } else {
      lines.push(`DTSTART;VALUE=DATE:${icsDate(e.start)}`, `DTEND;VALUE=DATE:${icsDate(addDays(e.end, 1))}`,
        `SUMMARY:${icsEscape(`Job: ${e.title}${u.role === 'admin' && names[e.builder_id] ? ` (${names[e.builder_id]})` : ''}`)}`, 'TRANSP:TRANSPARENT');
    }
    lines.push(`LOCATION:${icsEscape(address)}`, `DESCRIPTION:${icsEscape(desc)}`, `URL:${base}/jobs/${e.id}`, 'END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  res.setHeader('Content-Type', 'text/calendar; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  res.send(lines.map(fold).join('\r\n') + '\r\n');
}));

module.exports = { router, inspectionPanel, openSlots, eventsBetween, eventChip };
