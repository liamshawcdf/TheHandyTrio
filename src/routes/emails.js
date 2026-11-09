const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { STATUSES, label } = require('../statuses');
const { when } = require('../format');
const { sendEmail, fill, emailReady, PLACEHOLDERS } = require('../notify');
const { smsReady } = require('../sms');

const router = express.Router();
const admin = requireRole('admin');
const ORDER = [...STATUSES.map(([k]) => k), 'inspection_cancelled', 'cert_issued', 'cert_due', 'review_request'];
const nameOf = (k) => ({ cert_issued: 'Certificate issued (PDF attached)', inspection_cancelled: 'Inspection cancelled', cert_due: 'Renewal reminder', review_request: 'Review request' }[k] || label(k));

const sample = {
  first_name: 'Sam', customer_name: 'Sam Jones', job_ref: 'HT-00042', job_title: 'Hang an internal door',
  stage: 'Quote sent', due_date: '14 Mar 2027', address: '12 High Street, CF10 1AA', landlord_note: ' and keeps you legal as a landlord', book_link: 'https://example.com/rebook/7', review_link: 'https://g.page/r/your-business/review', inspection_time: 'Tuesday 14 January at 10:00 am', booked_dates: '20 Jan 2027 to 22 Jan 2027', cert_name: 'Landlord Gas Safety Record', cert_number: 'GSR-00007', price_guide: '£215.00 to £295.00 including VAT', job_link: 'https://example.com/jobs/42',
};

const tabs = (active) => `<nav class="subnav">
  <a href="/admin/emails" ${active === 'templates' ? 'aria-current="page"' : ''}>Customer emails</a>
  <a href="/admin/emails/texts" ${active === 'texts' ? 'aria-current="page"' : ''}>Text messages</a>
  <a href="/admin/reminders" ${active === 'reminders' ? 'aria-current="page"' : ''}>Reminders</a>
  <a href="/admin/emails/log" ${active === 'log' ? 'aria-current="page"' : ''}>Sent emails</a>
  <a href="/admin/emails/texts/log" ${active === 'textlog' ? 'aria-current="page"' : ''}>Sent texts</a></nav>`;

const setupNote = () => (emailReady() ? '' : `<div class="error">Email sending isn’t set up yet, so emails are only saved under <a href="/admin/emails/log">Sent emails</a>. Add your email account details to the .env file to start sending.</div>`);

router.get('/admin/emails', admin, wrap(async (req, res) => {
  const rows = (await query('SELECT * FROM email_templates')).rows.sort((a, b) => ORDER.indexOf(a.status) - ORDER.indexOf(b.status));
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  const vars = { ...sample, business_name: s.business_name };
  const body = `${tabs('templates')}${setupNote()}
    <p class="lead">The customer gets one of these each time their job moves stage. Office notes are never included.
    You can use: ${PLACEHOLDERS.map((p) => `<code>{${p}}</code>`).join(' ')}</p>
    <form method="post" action="/admin/emails/test" class="filters">
      <label>Send a test of<select name="status">${rows.map((t) => `<option value="${t.status}">${esc(nameOf(t.status))}</option>`).join('')}</select></label>
      <button class="small">Send test to ${esc(req.user.email)}</button>
    </form>
    ${rows.map((t) => `<details class="panel emailtpl" id="${t.status}">
      <summary><strong>${esc(nameOf(t.status))}</strong> <span class="tag">${t.enabled ? 'On' : 'Off'}</span> <span class="muted">${esc(fill(t.subject, vars))}</span></summary>
      <form method="post" action="/admin/emails/${t.status}">
        <label class="check"><input type="checkbox" name="enabled" ${t.enabled ? 'checked' : ''}> Send this email</label>
        <label>Subject<input name="subject" value="${esc(t.subject)}" maxlength="200" required></label>
        <label>Message<textarea name="body" rows="9" maxlength="5000" required>${esc(t.body)}</textarea></label>
        <button class="small">Save</button>
      </form>
      <p class="hint">Preview</p>
      <div class="preview">${esc(fill(t.body, vars))}</div>
    </details>`).join('')}`;
  const notice = req.query.saved ? 'Email saved.' : req.query.test ? `Test ${String(req.query.test).slice(0, 40)}.` : null;
  res.send(page({ title: 'Customer emails', user: req.user, notice, body }));
}));

router.post('/admin/emails/test', admin, wrap(async (req, res) => {
  const t = (await query('SELECT * FROM email_templates WHERE status = $1', [String(req.body.status || '')])).rows[0];
  if (!t) return res.redirect('/admin/emails');
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  const vars = { ...sample, business_name: s.business_name };
  const r = await sendEmail({ to: req.user.email, subject: '[Test] ' + fill(t.subject, vars), body: fill(t.body, vars) });
  res.redirect('/admin/emails?test=' + encodeURIComponent(r.status === 'sent' ? 'sent' : `${r.status}: ${r.error}`));
}));

router.post('/admin/emails/:status', admin, wrap(async (req, res) => {
  const subject = String(req.body.subject || '').trim().slice(0, 200);
  const body = String(req.body.body || '').replace(/\r\n/g, '\n').trim().slice(0, 5000);
  if (subject && body) {
    await query('UPDATE email_templates SET subject = $1, body = $2, enabled = $3 WHERE status = $4',
      [subject, body, req.body.enabled === 'on', req.params.status]);
  }
  res.redirect(`/admin/emails?saved=1#${encodeURIComponent(req.params.status)}`);
}));

router.get('/admin/emails/log', admin, wrap(async (req, res) => {
  const rows = (await query('SELECT * FROM email_log ORDER BY created_at DESC LIMIT 100')).rows;
  const body = `${tabs('log')}${setupNote()}
    ${rows.length ? rows.map((e) => `<details class="panel emailtpl">
      <summary>${when(e.created_at)} <span class="tag ${e.status === 'sent' ? '' : 'urgent'}">${esc(e.status)}</span> ${esc(e.to_address)} <span class="muted">${esc(e.subject)}</span></summary>
      ${e.job_id ? `<p><a href="/jobs/${e.job_id}">Open job</a></p>` : ''}
      ${e.error ? `<p class="muted">${esc(e.error)}</p>` : ''}
      <div class="preview">${esc(e.body)}</div>
    </details>`).join('') : '<p class="empty">No emails yet. They appear here as jobs move stage.</p>'}`;
  res.send(page({ title: 'Sent emails', user: req.user, body }));
}));

// ---------- Text messages ----------
const SMS_NAMES = { inspection_reminder: 'Day before an inspection visit', job_reminder: 'Day before a job starts' };

router.get('/admin/emails/texts', admin, wrap(async (req, res) => {
  const rows = (await query('SELECT * FROM sms_templates ORDER BY key')).rows;
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  const vars = { ...sample, business_name: s.business_name };
  const body = `${tabs('texts')}
    ${smsReady() ? '' : '<div class="error">Text messages aren’t set up yet, so texts are only saved under Sent texts. Add your Twilio details to the .env file to start sending.</div>'}
    <p class="lead">Sent automatically the day before, between 9am and 8pm, to customers with a UK mobile number. Customers can turn texts off in their account.
    Keep them short: one text is 160 characters, and longer messages cost more. You can use: ${['first_name', 'job_title', 'inspection_time', 'booked_dates', 'job_link', 'business_name'].map((p) => `<code>{${p}}</code>`).join(' ')}</p>
    ${rows.map((t) => {
      const preview = fill(t.body, vars);
      return `<form method="post" action="/admin/emails/texts/${t.key}" class="panel">
        <h3>${esc(SMS_NAMES[t.key] || t.key)}</h3>
        <label class="check"><input type="checkbox" name="enabled" ${t.enabled ? 'checked' : ''}> Send this text</label>
        <label>Message<textarea name="body" rows="3" maxlength="640" required>${esc(t.body)}</textarea></label>
        <p class="hint">Preview (${preview.length} characters, about ${Math.max(1, Math.ceil(preview.length / 153))} text${preview.length > 160 ? 's' : ''}):</p>
        <div class="preview">${esc(preview)}</div>
        <button class="small">Save</button>
      </form>`;
    }).join('')}`;
  res.send(page({ title: 'Text messages', user: req.user, notice: req.query.saved ? 'Saved.' : null, body }));
}));

router.post('/admin/emails/texts/:key', admin, wrap(async (req, res) => {
  const body = String(req.body.body || '').replace(/\r?\n/g, ' ').trim().slice(0, 640);
  if (body) await query('UPDATE sms_templates SET body = $1, enabled = $2 WHERE key = $3', [body, req.body.enabled === 'on', req.params.key]);
  res.redirect('/admin/emails/texts?saved=1');
}));

router.get('/admin/emails/texts/log', admin, wrap(async (req, res) => {
  const rows = (await query('SELECT * FROM sms_log ORDER BY created_at DESC LIMIT 100')).rows;
  const body = `${tabs('textlog')}
    ${rows.length ? `<ul class="certlist">${rows.map((t) => `<li>${when(t.created_at)} <span class="tag ${t.status === 'sent' ? 'ok' : 'urgent'}">${esc(t.status)}</span> ${esc(t.to_number)}
      ${t.job_id ? `<a href="/jobs/${t.job_id}">Job</a>` : ''}<br><span class="muted">${esc(t.body)}</span>${t.error ? `<br><span class="muted small">${esc(t.error)}</span>` : ''}</li>`).join('')}</ul>` : '<p class="empty">No texts yet.</p>'}`;
  res.send(page({ title: 'Sent texts', user: req.user, body }));
}));

module.exports = router;
