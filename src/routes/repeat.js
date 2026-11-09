// Repeat business: the "book your renewal" link in reminder emails, and the office's reminders page.
const express = require('express');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day, when } = require('../format');
const { setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyOffice, emailReady } = require('../notify');
const { smsReady } = require('../sms');
const { TYPES } = require('../certtypes');
const { runReminders } = require('../scheduler');

const router = express.Router();

async function ownedCert(req) {
  const c = (await query(
    `SELECT c.*, j.customer_id, j.address_line, j.town, j.postcode, j.title FROM certificates c JOIN jobs j ON j.id = c.job_id WHERE c.id = $1 AND c.status = 'issued'`,
    [Number(req.params.cid) || 0])).rows[0];
  if (!c || !TYPES[c.type]) return null;
  if (req.user.role === 'customer' && c.customer_id !== req.user.id) return null;
  return c;
}

router.get('/rebook/:cid', requireLogin, wrap(async (req, res) => {
  const c = await ownedCert(req);
  if (!c) return res.redirect('/dashboard');
  const address = [c.address_line, c.town, c.postcode].filter(Boolean).join(', ');
  const body = `<div class="panel narrow callout">
    <p>Your last ${esc(TYPES[c.type].name.toLowerCase())} at <strong>${esc(address)}</strong> was on ${day(c.issued_at)}${c.next_due ? `, and the next one is due by <strong>${day(c.next_due)}</strong>` : ''}.</p>
    <form method="post" action="/rebook/${c.id}">
      <button class="primary">Book my ${esc(TYPES[c.type].name.toLowerCase())}</button>
    </form>
    <p class="hint">Next you’ll choose a time for the visit.</p>
  </div>`;
  res.send(page({ title: `Book your ${TYPES[c.type].name}`, user: req.user, body }));
}));

router.post('/rebook/:cid', requireLogin, wrap(async (req, res) => {
  const c = await ownedCert(req);
  if (!c) return res.redirect('/dashboard');
  const t = TYPES[c.type];
  // Don't make a second request if one is already open for this renewal.
  const open = (await query(
    `SELECT id FROM jobs WHERE customer_id = $1 AND title = $2 AND postcode IS NOT DISTINCT FROM $3 AND status IN ('request', 'inspection_required', 'inspection_booked') LIMIT 1`,
    [c.customer_id, `${t.name} renewal`, c.postcode])).rows[0];
  if (open) return res.redirect(`/jobs/${open.id}/inspection`);
  const client = await pool.connect();
  let jobId;
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `INSERT INTO jobs (customer_id, title, work_type, description, address_line, town, postcode, preferred_start, status)
       VALUES ($1, $2, 'Something else', $3, $4, $5, $6, current_date + 1, 'request') RETURNING id`,
      [c.customer_id, `${t.name} renewal`, `Renewal of ${t.prefix}-${String(c.id).padStart(5, '0')}, due ${day(c.next_due)}.`, c.address_line, c.town, c.postcode]);
    jobId = rows[0].id;
    await setStatus(client, jobId, null, 'request', req.user.id, 'Renewal booked from a reminder');
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyOffice(`Renewal booked: ${t.name} (${ref(jobId)})`, `A customer has asked to renew their ${t.name}.\n\n${baseUrlOf(req)}/jobs/${jobId}`, jobId);
  res.redirect(`/jobs/${jobId}/inspection`);
}));

// ---------- Office: reminders ----------
router.get('/admin/reminders', requireRole('admin'), wrap(async (req, res) => {
  const s = (await query('SELECT reminder_days_before, review_link, texts_enabled FROM settings WHERE id = 1')).rows[0];
  const upcoming = (await query(
    `SELECT c.id, c.type, c.next_due, c.job_id, u.name, j.postcode,
       (SELECT r.sent_at FROM reminders_sent r WHERE r.kind = 'cert_due' AND r.ref_id = c.id) AS reminded
     FROM certificates c JOIN jobs j ON j.id = c.job_id JOIN users u ON u.id = j.customer_id
     WHERE c.status = 'issued' AND c.next_due IS NOT NULL AND c.next_due <= current_date + 90 AND c.next_due >= current_date - 30
     ORDER BY c.next_due`)).rows;
  const log = (await query(
    `SELECT r.*, CASE WHEN r.kind = 'cert_due' THEN (SELECT job_id FROM certificates WHERE id = r.ref_id) ELSE r.ref_id END AS job_id
     FROM reminders_sent r ORDER BY r.sent_at DESC LIMIT 50`)).rows;
  const KIND = { cert_due: 'Renewal reminder email', inspection_text: 'Visit reminder text', job_text: 'Start-day reminder text', review: 'Review request email' };
  const setup = [
    emailReady() ? '' : '<li>Email sending isn’t set up, so emails are saved but not sent.</li>',
    smsReady() ? '' : '<li>Text messages aren’t set up, so texts are saved but not sent. Add your Twilio details to .env.</li>',
    s.review_link ? '' : '<li>No review link is set, so review requests are off. Add your Google review link in Settings.</li>',
    s.texts_enabled ? '' : '<li>Texts are switched off in Settings.</li>',
  ].join('');
  const tabs = `<nav class="subnav"><a href="/admin/emails">Customer emails</a><a href="/admin/emails/texts">Text messages</a><a href="/admin/reminders" aria-current="page">Reminders</a><a href="/admin/emails/log">Sent emails</a><a href="/admin/emails/texts/log">Sent texts</a></nav>`;
  const body = `${tabs}
    ${setup ? `<ul class="error">${setup}</ul>` : ''}
    <p class="lead">These go out by themselves every hour: renewal emails ${Number(s.reminder_days_before)} days before a certificate is due, a text the day before a visit or start date (between 9am and 8pm), and a review request a few days after a job is paid.</p>
    <form method="post" action="/admin/reminders/run" class="inline"><button class="small">Check and send now</button></form>
    <h2>Certificates due in the next 90 days</h2>
    ${upcoming.length ? `<div class="scroll"><table><thead><tr><th>Certificate</th><th>Customer</th><th>Postcode</th><th>Due</th><th>Reminder</th></tr></thead><tbody>
      ${upcoming.map((c) => `<tr><td><a href="/jobs/${c.job_id}/certs/${c.id}">${esc(TYPES[c.type] ? TYPES[c.type].name : c.type)}</a></td><td>${esc(c.name)}</td><td>${esc(c.postcode)}</td>
        <td>${new Date(c.next_due) < new Date(new Date().toDateString()) ? '<span class="tag urgent">Overdue</span> ' : ''}${day(c.next_due)}</td>
        <td>${c.reminded ? `Sent ${day(c.reminded)}` : '<span class="muted">Not yet</span>'}</td></tr>`).join('')}
    </tbody></table></div>` : '<p class="empty">Nothing due in the next 90 days.</p>'}
    <h2>Recently sent</h2>
    ${log.length ? `<ul class="certlist">${log.map((r) => `<li>${when(r.sent_at)} <strong>${esc(KIND[r.kind] || r.kind)}</strong> ${r.job_id ? `<a href="/jobs/${r.job_id}">${ref(r.job_id)}</a>` : ''} <span class="tag ${r.status === 'sent' ? 'ok' : ''}">${esc(r.status || 'pending')}</span></li>`).join('')}</ul>` : '<p class="empty">Nothing sent yet.</p>'}`;
  const ran = req.query.ran ? String(req.query.ran).slice(0, 120) : null;
  res.send(page({ title: 'Reminders', user: req.user, notice: ran, body }));
}));

router.post('/admin/reminders/run', requireRole('admin'), wrap(async (req, res) => {
  const r = await runReminders();
  const msg = r ? `Checked: ${r.certificates} renewal email${r.certificates === 1 ? '' : 's'}, ${r.texts} text${r.texts === 1 ? '' : 's'}, ${r.reviews} review request${r.reviews === 1 ? '' : 's'} sent.` : 'Already running, try again in a minute.';
  res.redirect('/admin/reminders?ran=' + encodeURIComponent(msg));
}));

module.exports = router;
