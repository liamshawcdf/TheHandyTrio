const express = require('express');
const { query } = require('../db');
const { page, esc, icon } = require('../layout');
const { wrap, requireLogin } = require('../auth');
const { STATUSES, CLOSED, label } = require('../statuses');
const { ref, day, ukDate, addDays, TZ } = require('../format');
const { money } = require('../estimate');

const router = express.Router();
const firstName = (n) => String(n || '').trim().split(/\s+/)[0] || 'there';

// The job list as cards: first photo (or a soft placeholder), stage, title and one useful line.
function jobCards(jobs, { who = 'staff' } = {}) {
  if (!jobs.length) return '';
  return `<div class="cards">${jobs.map((j) => {
    const when = j.scheduled_start ? `Booked ${day(j.scheduled_start)}`
      : j.inspection_at && j.status === 'inspection_booked' ? `Visit ${new Date(j.inspection_at).toLocaleDateString('en-GB', { timeZone: TZ, day: 'numeric', month: 'short' })}`
      : `Requested ${day(j.created_at)}`;
    const extra = who === 'staff' ? [j.customer_name, j.postcode].filter(Boolean).join(', ') : j.quote_total ? `Quote ${money(j.quote_total)}` : '';
    return `<a class="jobcard" href="/jobs/${j.id}">
      <div class="pic">${j.photo_id ? `<img src="/jobs/${j.id}/photos/${j.photo_id}" alt="" loading="lazy">` : icon('jobs')}
        <span class="tag ${j.urgent && !CLOSED.includes(j.status) ? 'urgent' : ''}">${esc(label(j.status))}</span></div>
      <div class="txt"><strong>${esc(j.title)}</strong><span>${esc(when)}${extra ? ` · ${esc(extra)}` : ''}</span></div>
    </a>`;
  }).join('')}</div>`;
}

const CARD_SELECT = `SELECT j.*, c.name AS customer_name, b.name AS builder_name,
    (SELECT p.id FROM job_photos p WHERE p.job_id = j.id ORDER BY p.id LIMIT 1) AS photo_id,
    (SELECT q.total FROM quotes q WHERE q.job_id = j.id AND q.status IN ('sent', 'accepted') ORDER BY q.id DESC LIMIT 1) AS quote_total
  FROM jobs j JOIN users c ON c.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id`;

function weekList(events, today) {
  const { eventChip } = require('./calendar');
  return events.length
    ? `<div class="soon">${events.map((e) => `<div><span class="muted">${e.start === today ? 'Today' : day(e.start)}</span>${eventChip(e)}</div>`).join('')}</div>`
    : '';
}

router.get('/dashboard', requireLogin, wrap(async (req, res) => {
  const user = req.user;
  const today = ukDate(new Date());
  const { eventsBetween } = require('./calendar');

  // ---------------- Customers ----------------
  if (user.role === 'customer') {
    const jobs = (await query(`${CARD_SELECT} WHERE j.customer_id = $1 ORDER BY j.updated_at DESC`, [user.id])).rows;
    const active = jobs.filter((j) => !CLOSED.includes(j.status));
    const past = jobs.filter((j) => CLOSED.includes(j.status));
    const invoices = (await query(
      `SELECT i.*, j.title, i.amount_due - coalesce((SELECT sum(amount) FROM payments p WHERE p.invoice_id = i.id), 0) AS left_to_pay
       FROM invoices i JOIN jobs j ON j.id = i.job_id WHERE j.customer_id = $1 AND i.status = 'issued' ORDER BY i.created_at`, [user.id])).rows
      .filter((i) => Number(i.left_to_pay) > 0.004);
    const certs = (await query(
      `SELECT c.id, c.job_id, c.type, c.issued_at, c.next_due FROM certificates c JOIN jobs j ON j.id = c.job_id
       WHERE j.customer_id = $1 AND c.status = 'issued' AND NOT c.private ORDER BY c.issued_at DESC LIMIT 10`, [user.id])).rows;
    const { TYPES } = require('../certtypes');

    const body = `
      <h2>Active jobs</h2>
      ${jobCards(active, { who: 'customer' }) || `<div class="panel callout"><p><strong>No jobs on the go.</strong> Tell us what you need, add a few photos, and we’ll get back to you with a price.</p><a class="button primary" href="/jobs/new">Request a job</a></div>`}

      ${invoices.length ? `<h2>Open invoices</h2>
      <div class="scroll"><table>
        <thead><tr><th>Invoice</th><th>Job</th><th class="num">Left to pay</th><th>Invoiced</th><th>Due</th><th></th></tr></thead>
        <tbody>${invoices.map((i) => `<tr>
          <td>INV-${String(i.id).padStart(5, '0')}</td><td>${esc(i.title)}</td><td class="num">${money(i.left_to_pay)}</td>
          <td>${day(i.created_at)}</td><td>${i.due_date ? day(i.due_date) : 'On receipt'}</td>
          <td><a href="/jobs/${i.job_id}#invoices">View and pay</a></td></tr>`).join('')}</tbody></table></div>` : ''}

      ${certs.length ? `<h2>Your certificates</h2>
      <div class="scroll"><table>
        <thead><tr><th>Certificate</th><th>Issued</th><th>Next due</th><th></th></tr></thead>
        <tbody>${certs.map((c) => `<tr><td>${esc(TYPES[c.type] ? TYPES[c.type].name : c.type)}</td><td>${day(c.issued_at)}</td><td>${c.next_due ? day(c.next_due) : ''}</td>
          <td><a href="/jobs/${c.job_id}/certs/${c.id}/pdf" target="_blank" rel="noopener">PDF</a></td></tr>`).join('')}</tbody></table></div>` : ''}

      ${past.length ? `<h2>Past jobs</h2>
      <div class="scroll"><table>
        <thead><tr><th>Job</th><th>Stage</th><th>Last update</th></tr></thead>
        <tbody>${past.map((j) => `<tr><td><a href="/jobs/${j.id}">${esc(j.title)}</a></td><td><span class="tag ${j.status === 'paid' ? 'ok' : ''}">${esc(label(j.status))}</span></td><td>${day(j.updated_at)}</td></tr>`).join('')}</tbody></table></div>` : ''}`;
    return res.send(page({
      title: `Welcome back, ${firstName(user.name)}!`, subtitle: 'This is your private portal.', user, body,
      actions: '<a class="button primary" href="/jobs/new">Request a job</a>',
    }));
  }

  // ---------------- Builders ----------------
  if (user.role === 'builder') {
    const jobs = (await query(
      `${CARD_SELECT} WHERE (j.assigned_builder_id = $1 OR j.id IN (SELECT job_id FROM job_team WHERE user_id = $1)) AND j.status <> ALL($2)
       ORDER BY coalesce(j.scheduled_start, j.preferred_start) NULLS LAST, j.created_at`, [user.id, CLOSED])).rows;
    const clocked = (await query(
      `SELECT t.job_id, t.started_at, j.title FROM job_time_entries t JOIN jobs j ON j.id = t.job_id
       WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
    const myQuals = (await query(
      `SELECT kind, expires FROM staff_qualifications WHERE user_id = $1 AND expires <= current_date + 30 ORDER BY expires`, [user.id])).rows;
    const qualWarn = myQuals.map((q) => `<div class="error">Your ${esc(q.kind === 'gas' ? 'Gas Safe' : q.kind === 'pat' ? 'PAT' : 'electrical scheme')} qualification ${new Date(q.expires) < new Date(new Date().toDateString()) ? 'has expired' : 'expires'} on ${day(q.expires)}. Send the office your renewal.</div>`).join('');
    const soon = (await eventsBetween(today, addDays(today, 6), user.id)).sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));

    const body = `${qualWarn}
      ${clocked ? `<div class="notice">You’re clocked on to <a href="/jobs/${clocked.job_id}#time">${esc(clocked.title)}</a> since ${new Date(clocked.started_at).toLocaleTimeString('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit' })}.</div>` : ''}
      <h2>This week</h2>
      ${weekList(soon, today) || '<p class="empty">Nothing booked in the next 7 days.</p>'}
      <h2>Your jobs</h2>
      ${jobCards(jobs) || '<p class="empty">No jobs assigned to you yet. The office will add them here.</p>'}
      <p><a class="button" href="/jobs?show=finished">See my past jobs</a></p>`;
    return res.send(page({ title: `Welcome back, ${firstName(user.name)}!`, subtitle: 'Here’s your week.', user, body, actions: '<a class="button" href="/calendar">Open my diary</a>' }));
  }

  // ---------------- Office (admins and managers) ----------------
  const counts = await query('SELECT status, count(*)::int AS n FROM jobs GROUP BY status');
  const byStatus = Object.fromEntries(counts.rows.map((r) => [r.status, r.n]));
  const openCount = STATUSES.filter(([k]) => !CLOSED.includes(k)).reduce((a, [k]) => a + (byStatus[k] || 0), 0);
  const pipeline = STATUSES.filter(([k]) => !CLOSED.includes(k))
    .map(([k, l]) => `<li class="${byStatus[k] ? 'has' : ''}"><span class="n">${byStatus[k] || 0}</span><span>${esc(l)}</span></li>`).join('');
  const recent = (await query(`${CARD_SELECT} WHERE j.status <> ALL($1) ORDER BY j.urgent DESC, j.updated_at DESC LIMIT 8`, [CLOSED])).rows;
  const s = (await query(
    `SELECT base_postcode, (SELECT count(*)::int FROM users WHERE role IN ('builder', 'manager') AND active AND coalesce(postcode, '') <> '') AS builder_postcodes
     FROM settings WHERE id = 1`)).rows[0];
  const owed = (await query(
    `SELECT coalesce(sum(i.amount_due - coalesce((SELECT sum(amount) FROM payments p WHERE p.invoice_id = i.id), 0)), 0) AS n
     FROM invoices i WHERE i.status = 'issued'`)).rows[0].n;

  const ACTIONS = [
    ['request', 'Check the price guide'],
    ['inspection_required', 'Book an inspection'],
    ['inspected', 'Send the quote'],
    ['accepted', 'Request the deposit'],
    ['deposit_paid', 'Order parts and book the job in'],
    ['parts_ordered', 'Book the job in'],
    ['complete', 'Send the final invoice'],
  ];
  const actionRows = (await query(`SELECT id, title, status, urgent FROM jobs WHERE status = ANY($1) ORDER BY urgent DESC, updated_at`, [ACTIONS.map((a) => a[0])])).rows;
  const overdue = (await query(
    `SELECT i.id, i.job_id, j.title FROM invoices i JOIN jobs j ON j.id = i.job_id WHERE i.status = 'issued' AND i.due_date < current_date ORDER BY i.due_date`)).rows;
  const quals = (await query(
    `SELECT q.kind, q.expires, u.id AS user_id, u.name FROM staff_qualifications q JOIN users u ON u.id = q.user_id
     WHERE u.active AND q.expires <= current_date + 30 ORDER BY q.expires`)).rows;
  const certsDue = (await query(`SELECT count(*)::int AS n FROM certificates WHERE status = 'issued' AND NOT private AND next_due <= current_date + 30`)).rows[0].n;
  const lastBackup = (await query('SELECT max(created_at) AS t FROM backup_log')).rows[0].t;
  const backupDue = !lastBackup || Date.now() - new Date(lastBackup) > 7 * 86400000;
  const todoItems = [
    ...actionRows.map((j) => `<li><a href="/jobs/${j.id}"><strong>${esc(ACTIONS.find((a) => a[0] === j.status)[1])}</strong> · ${esc(j.title)} <span class="muted">${ref(j.id)}</span></a>${j.urgent ? ' <span class="tag urgent">Urgent</span>' : ''}</li>`),
    ...overdue.map((i) => `<li><a href="/jobs/${i.job_id}#invoices"><strong>Chase overdue invoice</strong> · ${esc(i.title)} <span class="muted">${ref(i.job_id)}</span></a></li>`),
    ...quals.map((q) => `<li><a href="/admin/users/${q.user_id}"><strong>${new Date(q.expires) < new Date(new Date().toDateString()) ? 'Qualification expired' : 'Qualification expiring'}</strong> · ${esc(q.name)}, ${esc(q.kind === 'gas' ? 'Gas Safe' : q.kind === 'pat' ? 'PAT' : 'electrical scheme')}, ${day(q.expires)}</a></li>`),
    ...(certsDue ? [`<li><a href="/admin/certificates?due=1"><strong>Certificates due for renewal</strong> · ${certsDue} in the next 30 days or overdue</a></li>`] : []),
    ...(backupDue ? [`<li><a href="/admin/backups"><strong>Download a backup</strong> · ${lastBackup ? `last one was ${day(lastBackup)}` : 'you haven’t made one yet'}</a></li>`] : []),
  ];

  const todays = await eventsBetween(today, today);
  const { loadAvailability, dayStatus, statusLabel } = require('../availability');
  const staffRows = (await query("SELECT id, name FROM users WHERE role IN ('builder', 'manager') AND active ORDER BY name")).rows;
  const avToday = await loadAvailability(staffRows.map((b) => b.id), today, today);
  const notAny = staffRows.map((b) => ({ b, st: dayStatus(avToday, b.id, today) })).filter((x) => x.st.state !== 'any');
  const whoOff = notAny.length ? `<p class="muted">${notAny.map((x) => `${esc(x.b.name)}: ${esc(statusLabel(x.st))}`).join(' · ')}</p>` : '';

  let myWeek = '';
  if (user.isManager) {
    const mine = (await eventsBetween(today, addDays(today, 6), user.id)).sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));
    const clockedOn = (await query(
      `SELECT t.job_id, j.title FROM job_time_entries t JOIN jobs j ON j.id = t.job_id WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
    myWeek = `${clockedOn ? `<div class="notice">You’re clocked on to <a href="/jobs/${clockedOn.job_id}#time">${esc(clockedOn.title)}</a>.</div>` : ''}
      <h2>My jobs this week</h2>${weekList(mine, today) || '<p class="empty">Nothing booked for you in the next 7 days.</p>'}`;
  }

  const dateLine = new Date().toLocaleDateString('en-GB', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long' });
  const body = `
    ${!s.base_postcode && !s.builder_postcodes ? '<div class="error">Add your builders’ home postcodes on the <a href="/admin/users">People</a> page so travel costs can be worked out.</div>' : ''}
    <div class="stats">
      <a class="stat" href="#attention"><span class="muted">Needs your attention</span><strong>${todoItems.length}</strong></a>
      <a class="stat" href="/calendar"><span class="muted">Booked today</span><strong>${todays.length}</strong></a>
      <a class="stat" href="/jobs?show=open"><span class="muted">Open jobs</span><strong>${openCount}</strong></a>
      <a class="stat" href="/admin/reports"><span class="muted">Owed to you</span><strong>${money(owed)}</strong></a>
    </div>
    ${myWeek}
    <h2>Today</h2>${whoOff}
    ${todays.length ? `<div class="soon">${todays.map((e) => require('./calendar').eventChip(e)).join('')}</div>` : '<p class="empty">Nothing booked today.</p>'}
    <h2 id="attention">Needs your attention</h2>
    ${todoItems.length ? `<ul class="todo">${todoItems.join('')}</ul>` : '<p class="empty">Nothing waiting on you right now.</p>'}
    <h2>Active jobs</h2>
    ${jobCards(recent) || '<p class="empty">No open jobs. New customer requests will appear here.</p>'}
    <p class="buttons"><a class="button" href="/jobs?show=open">All open jobs</a><a class="button" href="/jobs?show=finished">Finished and closed</a></p>
    <h2>Job pipeline</h2>
    <ol class="pipeline">${pipeline}</ol>`;
  res.send(page({ title: `Welcome back, ${firstName(user.name)}!`, subtitle: dateLine, user, body, actions: '<a class="button" href="/calendar">Open the calendar</a>' }));
}));

module.exports = router;
