// "Certify": engineers' own private certificates for side jobs.
// Not linked to any company job, not in company reports or reminders, and branded with
// the engineer's own trading name rather than the business's. Only the engineer can see them.
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { day } = require('../format');
const { sendEmail } = require('../notify');
const { TYPES } = require('../certtypes');
const { buildCertificatePdf } = require('../certpdf');
const { currentQuals, qualFor, certFormSections, readForm, addMonths } = require('./certs');

const router = express.Router();
const staff = requireRole('admin', 'builder');
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const pcertNo = (c) => `${TYPES[c.type].prefix}-P${String(c.id).padStart(5, '0')}`;
const clean = (v, n = 200) => String(v ?? '').trim().slice(0, n);

async function mine(req) {
  const c = (await query('SELECT * FROM certificates WHERE id = $1 AND private AND engineer_id = $2', [Number(req.params.cid) || 0, req.user.id])).rows[0];
  return c && TYPES[c.type] ? c : null;
}

function pdfParts(c, me) {
  return {
    cert: c,
    number: pcertNo(c),
    job: { address_line: c.cust_address, town: '', postcode: c.cust_postcode, ref: '' },
    customer: { name: c.cust_name, phone: c.cust_phone, email: c.cust_email },
    s: { business_name: c.trading_name || me.private_trading_name || me.name, business_address: '', business_phone: c.trading_contact || me.private_trading_contact || '', business_email: '' },
  };
}

router.get('/certify', staff, wrap(async (req, res) => {
  const quals = await currentQuals(req.user.id);
  const allowed = Object.entries(TYPES).filter(([k]) => qualFor(k, quals));
  const list = (await query('SELECT * FROM certificates WHERE private AND engineer_id = $1 ORDER BY id DESC LIMIT 200', [req.user.id])).rows;
  const body = `<p class="lead">Certificates for your own private work, outside ${'the business'}. They carry your own trading name, not the company’s, and only you can see them.</p>
    ${allowed.length ? `<form method="post" action="/certify" class="panel inline-form">
        <label>New certificate<select name="type">${allowed.map(([k, t]) => `<option value="${k}">${esc(t.name)}</option>`).join('')}</select></label>
        <button class="primary">Certify</button>
      </form>`
      : '<div class="error">You need an in-date Gas Safe, electrical or PAT qualification on your profile to certify. Ask the office to add it.</div>'}
    <h2>Your private certificates</h2>
    ${list.length ? `<ul class="certlist">${list.map((c) => `<li>
      <a href="/certify/${c.id}"><strong>${esc(TYPES[c.type] ? TYPES[c.type].name : c.type)}</strong> ${pcertNo(c)}</a>
      ${c.status === 'draft' ? '<span class="tag">Draft</span>' : `<span class="tag ${TYPES[c.type].bad(c.outcome || '') ? 'urgent' : 'ok'}">${esc(c.outcome)}</span>`}
      <span class="muted">${esc(c.cust_name || 'No customer yet')}${c.cust_postcode ? `, ${esc(c.cust_postcode)}` : ''} · ${c.status === 'issued' ? `issued ${day(c.issued_at)}` : `started ${day(c.created_at)}`}${c.next_due ? `, next due ${day(c.next_due)}` : ''}</span>
      ${c.status === 'issued' ? `<a class="button small" href="/certify/${c.id}/pdf" target="_blank" rel="noopener">PDF</a>` : ''}
    </li>`).join('')}</ul>` : '<p class="empty">None yet.</p>'}`;
  res.send(page({ title: 'Certify', user: req.user, body }));
}));

router.post('/certify', staff, wrap(async (req, res) => {
  const type = String(req.body.type || '');
  if (!TYPES[type] || !qualFor(type, await currentQuals(req.user.id))) return res.redirect('/certify');
  const me = (await query('SELECT private_trading_name, private_trading_contact FROM users WHERE id = $1', [req.user.id])).rows[0];
  const { rows } = await query(
    'INSERT INTO certificates (job_id, type, engineer_id, data, private, trading_name, trading_contact) VALUES (NULL, $1, $2, $3, true, $4, $5) RETURNING id',
    [type, req.user.id, '{}', me.private_trading_name, me.private_trading_contact]);
  res.redirect(`/certify/${rows[0].id}`);
}));

router.get('/certify/:cid', staff, wrap(async (req, res) => {
  const c = await mine(req);
  if (!c) return res.redirect('/certify');
  const t = TYPES[c.type];
  if (c.status !== 'draft') {
    const body = `<p class="jobhead"><a href="/certify">Back to my certificates</a></p>
      <section class="panel quote">
        <div class="quotehead"><h2>${pcertNo(c)}</h2><span class="tag ${t.bad(c.outcome || '') ? 'urgent' : 'ok'}">${esc(c.outcome)}</span></div>
        <p>${esc(c.cust_name)}, ${esc(c.cust_address)} ${esc(c.cust_postcode)}</p>
        <p class="muted">Issued ${day(c.issued_at)}${c.next_due ? `. Next due ${day(c.next_due)}` : ''}${c.sent_to ? `. Emailed to ${esc(c.sent_to)}` : ''}</p>
        <div class="buttons">
          <a class="button primary" href="/certify/${c.id}/pdf" target="_blank" rel="noopener">View or print</a>
          <a class="button" href="/certify/${c.id}/pdf?download=1">Download PDF</a>
          <form method="post" action="/certify/${c.id}/resend" class="inline"><button class="small">Email the customer again</button></form>
        </div>
      </section>`;
    return res.send(page({ title: t.name, user: req.user, notice: req.query.issued ? 'Certificate issued and sent.' : req.query.sent ? 'Sent again.' : null, body }));
  }
  const v = (k) => esc(c[k] ?? '');
  const body = `<p class="jobhead"><a href="/certify">Back to my certificates</a> <span class="ref">${pcertNo(c)}</span> <span class="tag">Draft</span></p>
    <form method="post" action="/certify/${c.id}" class="certform">
      <fieldset class="panel"><legend>Customer</legend>
        <div class="certgrid">
          <label>Full name<input name="cust_name" value="${v('cust_name')}" maxlength="120" autocomplete="off"></label>
          <label>Address<input name="cust_address" value="${v('cust_address')}" maxlength="200" autocomplete="off"></label>
          <label>Postcode<input name="cust_postcode" value="${v('cust_postcode')}" maxlength="10" autocomplete="off"></label>
          <label>Phone<input type="tel" name="cust_phone" value="${v('cust_phone')}" maxlength="40" autocomplete="off"></label>
          <label>Email<input type="email" name="cust_email" value="${v('cust_email')}" maxlength="120" autocomplete="off"></label>
        </div>
        <p class="hint">All five are needed to issue, so the customer can be traced and sent their copy if there’s ever a safety issue.</p>
      </fieldset>
      <fieldset class="panel"><legend>Your business details on the certificate</legend>
        <div class="certgrid">
          <label>Trading name<input name="trading_name" value="${v('trading_name')}" maxlength="120" placeholder="${esc(req.user.name)}"></label>
          <label>Your contact phone or email<input name="trading_contact" value="${v('trading_contact')}" maxlength="120"></label>
        </div>
        <p class="hint">Remembered for next time.</p>
      </fieldset>
      ${certFormSections(t, c.data || {})}
      <div class="buttons"><button name="action" value="save" class="small">Save draft</button>
        <a class="button" href="/certify/${c.id}/pdf" target="_blank" rel="noopener">Preview PDF</a></div>
      <fieldset class="panel issue">
        <legend>Issue the certificate</legend>
        <p>Issuing locks the certificate and emails the PDF to the customer, with a copy to you (${esc(req.user.email)}).</p>
        <label class="check"><input type="checkbox" name="declare"> I confirm the inspection and tests recorded were carried out by me and are a true record.</label>
        <label>Your full name<input name="declaration_name" value="${esc(req.user.name)}" maxlength="120"></label>
        <button name="action" value="issue" class="primary">Issue and send</button>
      </fieldset>
      <p><button name="action" value="delete" class="small danger">Delete this draft</button></p>
    </form>`;
  res.send(page({ title: t.name, user: req.user, notice: req.query.saved ? 'Draft saved.' : null, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
}));

async function emailIt(c, me) {
  const t = TYPES[c.type];
  const parts = pdfParts(c, me);
  const pdf = await buildCertificatePdf(parts);
  const from = parts.s.business_name;
  const attachments = [{ filename: `${pcertNo(c)}.pdf`, content: pdf, contentType: 'application/pdf' }];
  const body = `Hi ${c.cust_name.split(' ')[0]},\n\nPlease find attached your ${t.name}, number ${pcertNo(c)}, for ${c.cust_address}, ${c.cust_postcode}.\n\nPlease keep it somewhere safe.${c.next_due ? ` The next one is due by ${day(c.next_due)}.` : ''}\n\nThanks,\n${from}${parts.s.business_phone ? `\n${parts.s.business_phone}` : ''}`;
  const r = await sendEmail({ to: c.cust_email, subject: `Your ${t.name} (${pcertNo(c)})`, body, attachments });
  await sendEmail({ to: me.email, subject: `Your copy: ${t.name} ${pcertNo(c)} for ${c.cust_name}`, body: `Your copy of ${pcertNo(c)}, issued to ${c.cust_name}, ${c.cust_address}, ${c.cust_postcode}.`, attachments });
  await query('UPDATE certificates SET sent_to = $1, sent_at = now() WHERE id = $2', [c.cust_email, c.id]);
  return r;
}

router.post('/certify/:cid', staff, wrap(async (req, res) => {
  const c = await mine(req);
  if (!c || c.status !== 'draft') return res.redirect('/certify');
  if (req.body.action === 'delete') {
    await query("DELETE FROM certificates WHERE id = $1 AND status = 'draft' AND private", [c.id]);
    return res.redirect('/certify');
  }
  const t = TYPES[c.type];
  const f = {
    cust_name: clean(req.body.cust_name, 120), cust_address: clean(req.body.cust_address), cust_postcode: clean(req.body.cust_postcode, 10).toUpperCase(),
    cust_phone: clean(req.body.cust_phone, 40), cust_email: clean(req.body.cust_email, 120).toLowerCase(),
    trading_name: clean(req.body.trading_name, 120), trading_contact: clean(req.body.trading_contact, 120),
  };
  const data = readForm(t, req.body);
  await query(
    `UPDATE certificates SET data = $1, cust_name = $2, cust_address = $3, cust_postcode = $4, cust_phone = $5, cust_email = $6,
       trading_name = $7, trading_contact = $8, updated_at = now() WHERE id = $9`,
    [JSON.stringify(data), f.cust_name || null, f.cust_address || null, f.cust_postcode || null, f.cust_phone || null, f.cust_email || null, f.trading_name || null, f.trading_contact || null, c.id]);
  await query('UPDATE users SET private_trading_name = $1, private_trading_contact = $2 WHERE id = $3', [f.trading_name || null, f.trading_contact || null, req.user.id]);
  if (req.body.action !== 'issue') return res.redirect(`/certify/${c.id}?saved=1`);

  const qual = qualFor(c.type, await currentQuals(req.user.id));
  const name = clean(req.body.declaration_name, 120);
  let error = null;
  if (!qual) error = 'Your qualification for this certificate has expired or is missing, so it can’t be issued.';
  else if (!f.cust_name || !f.cust_address || !f.cust_postcode || !f.cust_phone || !EMAIL.test(f.cust_email)) error = 'Fill in the customer’s name, address, postcode, phone and a valid email to issue.';
  else if (req.body.declare !== 'on' || !name) error = 'Tick the declaration and type your name to issue.';
  else if (t.nextDueField && !data[t.nextDueField]) error = 'Fill in the recommended next inspection date.';
  else if (t.sections.some((sec) => ['appliances', 'items'].includes(sec.group) && !(data[sec.group] || []).length)) error = 'Add at least one appliance.';
  if (error) return res.redirect(`/certify/${c.id}?error=${encodeURIComponent(error)}`);

  let nextDue = null;
  if (t.nextDueField) nextDue = data[t.nextDueField];
  else if (t.nextDueFromItems) {
    const months = Math.min(...(data.items || []).map((i) => Number(i[t.nextDueFromItems]) || 12));
    nextDue = addMonths(Number.isFinite(months) ? months : 12);
  } else if (t.nextDueMonths) nextDue = addMonths(t.nextDueMonths);

  const updated = (await query(
    `UPDATE certificates SET status = 'issued', outcome = $1, issued_at = now(), next_due = $2, declaration_name = $3,
       engineer_name = $4, engineer_scheme = $5, engineer_number = $6, engineer_categories = $7, updated_at = now()
     WHERE id = $8 AND status = 'draft' RETURNING *`,
    [t.outcome(data), nextDue, name, req.user.name, qual.scheme, qual.number, qual.categories, c.id])).rows[0];
  if (updated) await emailIt(updated, (await query('SELECT * FROM users WHERE id = $1', [req.user.id])).rows[0]);
  res.redirect(`/certify/${c.id}?issued=1`);
}));

router.post('/certify/:cid/resend', staff, wrap(async (req, res) => {
  const c = await mine(req);
  if (c && c.status === 'issued') await emailIt(c, (await query('SELECT * FROM users WHERE id = $1', [req.user.id])).rows[0]);
  res.redirect(`/certify/${req.params.cid}?sent=1`);
}));

router.get('/certify/:cid/pdf', staff, wrap(async (req, res) => {
  const c = await mine(req);
  if (!c) return res.redirect('/certify');
  const me = (await query('SELECT * FROM users WHERE id = $1', [req.user.id])).rows[0];
  let cert = c;
  if (c.status === 'draft') {
    const q = qualFor(c.type, await currentQuals(req.user.id));
    cert = { ...c, outcome: TYPES[c.type].outcome(c.data || {}), engineer_name: me.name, engineer_scheme: q && q.scheme, engineer_number: q && q.number, engineer_categories: q && q.categories };
  }
  const pdf = await buildCertificatePdf(pdfParts(cert, me));
  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `${req.query.download ? 'attachment' : 'inline'}; filename="${pcertNo(c)}.pdf"`);
  res.send(pdf);
}));

module.exports = router;
