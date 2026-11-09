// Gas and electrical certificates: engineers fill them in on the job, issuing locks them,
// the customer is emailed a PDF copy and the office keeps the record.
const express = require('express');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day } = require('../format');
const { loadJob, notFound, baseUrlOf } = require('../jobs-shared');
const { sendEmail, fill, jobVars } = require('../notify');
const { TYPES, QUAL_KINDS, typeOptions } = require('../certtypes');
const { buildCertificatePdf } = require('../certpdf');

const router = express.Router();
const staff = requireRole('admin', 'builder');
const certNo = (c) => `${TYPES[c.type] ? TYPES[c.type].prefix : 'CERT'}-${String(c.id).padStart(5, '0')}`;
const todayISO = () => new Date().toISOString().slice(0, 10);

// Current (in-date) qualifications for a person, keyed by kind.
async function currentQuals(userId) {
  const rows = (await query('SELECT * FROM staff_qualifications WHERE user_id = $1 AND expires >= current_date ORDER BY expires DESC', [userId])).rows;
  const byKind = {};
  for (const q of rows) if (!byKind[q.kind]) byKind[q.kind] = q;
  return byKind;
}
const qualFor = (type, quals) => TYPES[type].requires.map((k) => quals[k]).find(Boolean) || null;

// ---------- Panel on the job page ----------
async function certificatesPanel(job, user) {
  const certs = (await query(
    `SELECT c.*, u.name AS by_name FROM certificates c JOIN users u ON u.id = c.engineer_id
     WHERE c.job_id = $1 ${user.role === 'customer' ? "AND c.status = 'issued'" : ''} ORDER BY c.id`, [job.id])).rows;
  let start = '';
  if (user.role !== 'customer') {
    const quals = await currentQuals(user.id);
    const allowed = Object.entries(TYPES).filter(([k]) => qualFor(k, quals));
    start = allowed.length
      ? `<form method="post" action="/jobs/${job.id}/certs" class="inline-form">
          <label>New certificate<select name="type">${allowed.map(([k, t]) => `<option value="${k}">${esc(t.name)}</option>`).join('')}</select></label>
          <button class="small">Start</button>
        </form>`
      : `<p class="hint">You need an in-date Gas Safe, electrical or PAT qualification on your profile to fill in certificates. The office adds these on the People page.</p>`;
  }
  if (!certs.length && user.role === 'customer') return '';
  const list = certs.length ? `<ul class="certlist">${certs.map((c) => {
    const t = TYPES[c.type] || { name: c.type, bad: () => false };
    const tag = c.status === 'draft' ? '<span class="tag">Draft</span>' : c.status === 'void' ? '<span class="tag">Cancelled</span>'
      : `<span class="tag ${t.bad(c.outcome || '') ? 'urgent' : 'ok'}">${esc(c.outcome)}</span>`;
    return `<li>
      <a href="/jobs/${job.id}/certs/${c.id}"><strong>${esc(t.name)}</strong> ${certNo(c)}</a> ${tag}
      <span class="muted">${c.status === 'issued' ? `issued ${day(c.issued_at)}` : `started ${day(c.created_at)}`}${user.role !== 'customer' ? ` by ${esc(c.by_name)}` : ''}${c.next_due ? `, next due ${day(c.next_due)}` : ''}</span>
      ${c.status !== 'draft' ? `<a class="button small" href="/jobs/${job.id}/certs/${c.id}/pdf" target="_blank" rel="noopener">PDF</a>` : ''}
    </li>`;
  }).join('')}</ul>` : '<p class="empty">No certificates on this job yet.</p>';
  return `<section class="panel" id="certs"><h2>Certificates</h2>${list}${start}</section>`;
}

// Engineers on the job (beyond the main builder), so a gas engineer or electrician can open it.
async function teamPanel(job, user) {
  if (user.role !== 'admin') return '';
  const team = (await query('SELECT u.id, u.name FROM job_team t JOIN users u ON u.id = t.user_id WHERE t.job_id = $1 ORDER BY u.name', [job.id])).rows;
  const engineers = (await query(
    `SELECT DISTINCT u.id, u.name, string_agg(DISTINCT q.kind, ', ') AS kinds FROM users u JOIN staff_qualifications q ON q.user_id = u.id
     WHERE u.active AND u.role IN ('builder','admin') AND q.expires >= current_date GROUP BY u.id, u.name ORDER BY u.name`)).rows
    .filter((e) => !team.some((t) => t.id === e.id) && e.id !== job.assigned_builder_id);
  return `<section class="panel staffonly"><h2>Engineers on this job <span class="tag">Office only</span></h2>
    ${team.length ? `<ul class="certlist">${team.map((t) => `<li>${esc(t.name)}
      <form method="post" action="/jobs/${job.id}/team/${t.id}/remove" class="inline"><button class="small">Remove</button></form></li>`).join('')}</ul>`
      : '<p class="muted">Only the main builder can see this job. Add a gas engineer or electrician so they can open it and fill in certificates.</p>'}
    ${engineers.length ? `<form method="post" action="/jobs/${job.id}/team" class="inline-form">
      <label>Add engineer<select name="user_id">${engineers.map((e) => `<option value="${e.id}">${esc(e.name)} (${esc(e.kinds)})</option>`).join('')}</select></label>
      <button class="small">Add</button></form>` : ''}
  </section>`;
}

router.post('/jobs/:id/team', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const uid = Number(req.body.user_id) || 0;
  if (uid) await query('INSERT INTO job_team (job_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [job.id, uid]);
  res.redirect(`/jobs/${job.id}#certs`);
}));

router.post('/jobs/:id/team/:uid/remove', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  await query('DELETE FROM job_team WHERE job_id = $1 AND user_id = $2', [job.id, Number(req.params.uid) || 0]);
  res.redirect(`/jobs/${job.id}#certs`);
}));

// ---------- Create ----------
router.post('/jobs/:id/certs', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const type = String(req.body.type || '');
  if (!TYPES[type]) return res.redirect(`/jobs/${job.id}#certs`);
  if (!qualFor(type, await currentQuals(req.user.id))) {
    return res.redirect(`/jobs/${job.id}?error=${encodeURIComponent('You don’t have an in-date qualification for that certificate.')}#certs`);
  }
  // Start with what we already know about the customer and site.
  const data = {};
  if (type === 'gas_safety') data.tenant_name = job.customer_name;
  if (type === 'eicr') { data.client_name = job.customer_name; data.occupier = job.customer_name; }
  if (type === 'pat') { data.client_name = job.customer_name; data.site = [job.address_line, job.town, job.postcode].filter(Boolean).join(', '); }
  const { rows } = await query('INSERT INTO certificates (job_id, type, engineer_id, data) VALUES ($1, $2, $3, $4) RETURNING id',
    [job.id, type, req.user.id, JSON.stringify(data)]);
  res.redirect(`/jobs/${job.id}/certs/${rows[0].id}`);
}));

async function loadCert(req, job) {
  return (await query('SELECT * FROM certificates WHERE id = $1 AND job_id = $2', [Number(req.params.cid) || 0, job.id])).rows[0] || null;
}

// ---------- Form ----------
function input(name, f, value) {
  const [, lbl, type] = f;
  const v = value ?? '';
  if (type === 'textarea') return `<label>${esc(lbl)}<textarea name="${name}" rows="2" maxlength="3000">${esc(v)}</textarea></label>`;
  if (['yn', 'pf', 'select'].includes(type)) {
    const opts = typeOptions(f);
    return `<label>${esc(lbl)}<select name="${name}"><option value=""></option>${opts.map((o) => `<option ${o === v ? 'selected' : ''}>${esc(o)}</option>`).join('')}</select></label>`;
  }
  if (type === 'date') return `<label>${esc(lbl)}<input type="date" name="${name}" value="${esc(v)}"></label>`;
  if (type === 'number') return `<label>${esc(lbl)}<input type="text" inputmode="decimal" name="${name}" value="${esc(v)}" maxlength="20"></label>`;
  return `<label>${esc(lbl)}<input name="${name}" value="${esc(v)}" maxlength="300"></label>`;
}

function readForm(t, body) {
  const data = {};
  const clean = (v) => String(v ?? '').trim().slice(0, 3000);
  for (const sec of t.sections) {
    if (!sec.group) {
      for (const [k] of sec.fields) { const v = clean(body[k]); if (v) data[k] = v; }
      continue;
    }
    const count = Math.min(Number(body[`${sec.group}__count`]) || 0, 300);
    const items = [];
    for (let i = 0; i < count; i++) {
      if (body[`${sec.group}__${i}__del`] === 'on') continue;
      const item = {};
      for (const [k] of sec.fields) { const v = clean(body[`${sec.group}__${i}__${k}`]); if (v) item[k] = v; }
      if (Object.keys(item).length) items.push(item);
    }
    data[sec.group] = items;
  }
  return data;
}

router.get('/jobs/:id/certs/:cid', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const c = await loadCert(req, job);
  if (!c || (req.user.role === 'customer' && c.status !== 'issued')) return notFound(req, res);
  const t = TYPES[c.type];
  const d = c.data || {};
  const editable = c.status === 'draft' && c.engineer_id === req.user.id;

  if (!editable) {
    const actions = req.user.role === 'admin' && c.status === 'issued' ? `
      <form method="post" action="/jobs/${job.id}/certs/${c.id}/resend" class="inline"><button class="small">Email the customer again</button></form>
      <details class="recordpay"><summary>Cancel this certificate</summary>
        <form method="post" action="/jobs/${job.id}/certs/${c.id}/void" class="panel">
          <label>Reason<input name="reason" required maxlength="300"></label>
          <button class="small danger">Cancel certificate</button>
        </form></details>` : '';
    const body = `<p class="jobhead"><a href="/jobs/${job.id}#certs">Back to the job</a></p>
      <section class="panel quote">
        <div class="quotehead"><h2>${certNo(c)}</h2><span class="tag ${c.status === 'issued' && !t.bad(c.outcome || '') ? 'ok' : 'urgent'}">${esc(c.status === 'issued' ? c.outcome : c.status === 'void' ? 'Cancelled' : 'Draft')}</span></div>
        <p class="muted">${c.status === 'issued' ? `Issued ${day(c.issued_at)} by ${esc(c.engineer_name)}` : 'Not issued yet'}${c.next_due ? `. Next due ${day(c.next_due)}` : ''}${c.sent_to && req.user.role !== 'customer' ? `. Emailed to ${esc(c.sent_to)} ${day(c.sent_at)}` : ''}</p>
        ${c.status === 'void' ? `<p class="error">Cancelled: ${esc(c.void_reason)}</p>` : ''}
        <div class="buttons">
          <a class="button primary" href="/jobs/${job.id}/certs/${c.id}/pdf" target="_blank" rel="noopener">View or print</a>
          <a class="button" href="/jobs/${job.id}/certs/${c.id}/pdf?download=1">Download PDF</a>
        </div>
        ${actions}
      </section>`;
    return res.send(page({ title: t.name, user: req.user, notice: req.query.issued ? 'Certificate issued and sent.' : req.query.sent ? 'Sent again.' : null, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
  }

  const sections = t.sections.map((sec) => {
    if (!sec.group) {
      return `<fieldset class="panel"><legend>${esc(sec.title)}</legend><div class="certgrid">${sec.fields.map((f) => input(f[0], f, d[f[0]])).join('')}</div></fieldset>`;
    }
    const items = d[sec.group] || [];
    const count = items.length + sec.blank;
    const rows = [];
    for (let i = 0; i < count; i++) {
      const item = items[i] || {};
      rows.push(`<div class="certitem ${items[i] ? '' : 'new'}">
        <p class="fieldlabel">${esc(sec.itemLabel)} ${i + 1}${items[i] ? '' : ' (leave blank if not needed)'}</p>
        <div class="certgrid">${sec.fields.map((f) => input(`${sec.group}__${i}__${f[0]}`, f, item[f[0]])).join('')}</div>
        ${items[i] ? `<label class="check"><input type="checkbox" name="${sec.group}__${i}__del"> Remove</label>` : ''}
      </div>`);
    }
    return `<fieldset class="panel"><legend>${esc(sec.title)}</legend><input type="hidden" name="${sec.group}__count" value="${count}">${rows.join('')}
      <p class="hint">Save to get more blank ${esc(sec.itemLabel.toLowerCase())} rows.</p>${sec.group === 'observations' && t.codesNote ? `<p class="hint">${esc(t.codesNote)}</p>` : ''}</fieldset>`;
  }).join('');

  const body = `<p class="jobhead"><a href="/jobs/${job.id}#certs">Back to the job</a> <span class="ref">${certNo(c)}</span> <span class="tag">Draft</span></p>
    <form method="post" action="/jobs/${job.id}/certs/${c.id}" class="certform">
      ${sections}
      <div class="buttons"><button name="action" value="save" class="small">Save draft</button>
        <a class="button" href="/jobs/${job.id}/certs/${c.id}/pdf" target="_blank" rel="noopener">Preview PDF</a></div>
      <fieldset class="panel issue">
        <legend>Issue the certificate</legend>
        <p>Issuing locks the certificate, emails a PDF copy to the customer (${esc(job.customer_email)}) and keeps the office copy on the system.</p>
        <label class="check"><input type="checkbox" name="declare"> I confirm the inspection and tests recorded were carried out by me and are a true record.</label>
        <label>Your full name<input name="declaration_name" value="${esc(req.user.name)}" maxlength="120"></label>
        <button name="action" value="issue" class="primary">Issue and send</button>
      </fieldset>
      <p><button name="action" value="delete" class="small danger">Delete this draft</button></p>
    </form>`;
  res.send(page({ title: t.name, user: req.user, notice: req.query.saved ? 'Draft saved.' : null, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
}));

async function emailCertificate(req, job, c) {
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const t = TYPES[c.type];
  const cust = (await query('SELECT name, email FROM users WHERE id = $1', [job.customer_id])).rows[0];
  const pdf = await buildCertificatePdf({ cert: c, number: certNo(c), job: { ...job, ref: ref(job.id) }, customer: cust, s });
  const tpl = (await query("SELECT * FROM email_templates WHERE status = 'cert_issued'")).rows[0];
  const data = await jobVars(job.id, job.status, baseUrlOf(req));
  const vars = { ...data.vars, cert_name: t.name, cert_number: certNo(c) };
  const attachments = [{ filename: `${certNo(c)}.pdf`, content: pdf, contentType: 'application/pdf' }];
  let result = { status: 'skipped' };
  if (tpl && tpl.enabled) {
    result = await sendEmail({ to: cust.email, subject: fill(tpl.subject, vars), body: fill(tpl.body, vars), jobId: job.id, attachments });
  }
  // Office copy.
  if (s.business_email) {
    await sendEmail({ to: s.business_email, subject: `[TheHandyTrio] Office copy: ${t.name} ${certNo(c)} (${ref(job.id)})`,
      body: `${t.name} ${certNo(c)} issued by ${c.engineer_name}. Outcome: ${c.outcome}.\n\n${baseUrlOf(req)}/jobs/${job.id}/certs/${c.id}`, jobId: job.id, attachments });
  }
  await query('UPDATE certificates SET sent_to = $1, sent_at = now() WHERE id = $2', [cust.email, c.id]);
  return result;
}

router.post('/jobs/:id/certs/:cid', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const c = await loadCert(req, job);
  if (!c || c.status !== 'draft' || c.engineer_id !== req.user.id) return res.redirect(`/jobs/${job.id}#certs`);
  const t = TYPES[c.type];

  if (req.body.action === 'delete') {
    await query("DELETE FROM certificates WHERE id = $1 AND status = 'draft'", [c.id]);
    return res.redirect(`/jobs/${job.id}#certs`);
  }

  const data = readForm(t, req.body);
  await query('UPDATE certificates SET data = $1, updated_at = now() WHERE id = $2', [JSON.stringify(data), c.id]);
  if (req.body.action !== 'issue') return res.redirect(`/jobs/${job.id}/certs/${c.id}?saved=1`);

  const qual = qualFor(c.type, await currentQuals(req.user.id));
  const name = String(req.body.declaration_name || '').trim().slice(0, 120);
  let error = null;
  if (!qual) error = 'Your qualification for this certificate has expired or is missing, so it can’t be issued.';
  else if (req.body.declare !== 'on' || !name) error = 'Tick the declaration and type your name to issue.';
  else if (t.nextDueField && !data[t.nextDueField]) error = 'Fill in the recommended next inspection date.';
  else if (t.sections.some((sec) => sec.group && sec.blank && ['appliances', 'items'].includes(sec.group) && !(data[sec.group] || []).length)) error = 'Add at least one appliance.';
  if (error) return res.redirect(`/jobs/${job.id}/certs/${c.id}?error=${encodeURIComponent(error)}`);

  let nextDue = null;
  if (t.nextDueField) nextDue = data[t.nextDueField];
  else if (t.nextDueFromItems) {
    const months = Math.min(...(data.items || []).map((i) => Number(i[t.nextDueFromItems]) || 12));
    nextDue = addMonths(Number.isFinite(months) ? months : 12);
  } else if (t.nextDueMonths) nextDue = addMonths(t.nextDueMonths);

  const outcome = t.outcome(data);
  const updated = (await query(
    `UPDATE certificates SET status = 'issued', outcome = $1, issued_at = now(), next_due = $2, declaration_name = $3,
       engineer_name = $4, engineer_scheme = $5, engineer_number = $6, engineer_categories = $7, updated_at = now()
     WHERE id = $8 AND status = 'draft' RETURNING *`,
    [outcome, nextDue, name, req.user.name, qual.scheme || QUAL_KINDS[qual.kind].scheme, qual.number, qual.categories, c.id])).rows[0];
  if (updated) await emailCertificate(req, job, updated);
  res.redirect(`/jobs/${job.id}/certs/${c.id}?issued=1`);
}));

function addMonths(m) {
  const d = new Date();
  d.setMonth(d.getMonth() + m);
  return d.toISOString().slice(0, 10);
}

router.post('/jobs/:id/certs/:cid/resend', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const c = await loadCert(req, job);
  if (c && c.status === 'issued') await emailCertificate(req, job, c);
  res.redirect(`/jobs/${job.id}/certs/${req.params.cid}?sent=1`);
}));

router.post('/jobs/:id/certs/:cid/void', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const reason = String(req.body.reason || '').trim().slice(0, 300);
  if (reason) await query("UPDATE certificates SET status = 'void', void_reason = $1, updated_at = now() WHERE id = $2 AND job_id = $3 AND status = 'issued'", [reason, Number(req.params.cid) || 0, job.id]);
  res.redirect(`/jobs/${job.id}/certs/${req.params.cid}`);
}));

router.get('/jobs/:id/certs/:cid/pdf', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const c = await loadCert(req, job);
  if (!c || (req.user.role === 'customer' && c.status !== 'issued')) return notFound(req, res);
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const cust = (await query('SELECT name FROM users WHERE id = $1', [job.customer_id])).rows[0];
  let cert = c;
  if (c.status === 'draft') {
    // Preview shows the engineer's details as they will appear.
    const q = qualFor(c.type, await currentQuals(c.engineer_id));
    const eng = (await query('SELECT name FROM users WHERE id = $1', [c.engineer_id])).rows[0];
    cert = { ...c, outcome: TYPES[c.type].outcome(c.data || {}), engineer_name: eng.name, engineer_scheme: q && q.scheme, engineer_number: q && q.number, engineer_categories: q && q.categories };
  }
  const pdf = await buildCertificatePdf({ cert, number: certNo(c), job: { ...job, ref: ref(job.id) }, customer: cust, s });
  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `${req.query.download ? 'attachment' : 'inline'}; filename="${certNo(c)}.pdf"`);
  res.send(pdf);
}));

// ---------- Office register of all certificates ----------
router.get('/admin/certificates', requireRole('admin'), wrap(async (req, res) => {
  const type = TYPES[req.query.type] ? req.query.type : '';
  const due = req.query.due === '1';
  const params = [];
  const where = ["c.status <> 'draft'"];
  if (type) { params.push(type); where.push(`c.type = $${params.length}`); }
  if (due) where.push("c.status = 'issued' AND c.next_due <= current_date + 60");
  const rows = (await query(
    `SELECT c.*, j.title, j.postcode, cu.name AS customer_name FROM certificates c JOIN jobs j ON j.id = c.job_id JOIN users cu ON cu.id = j.customer_id
     WHERE ${where.join(' AND ')} ORDER BY ${due ? 'c.next_due' : 'c.issued_at DESC'} LIMIT 300`, params)).rows;
  const body = `<form method="get" action="/admin/certificates" class="filters">
      <label>Type<select name="type"><option value="">All types</option>${Object.entries(TYPES).map(([k, t]) => `<option value="${k}" ${k === type ? 'selected' : ''}>${esc(t.name)}</option>`).join('')}</select></label>
      <label class="check"><input type="checkbox" name="due" value="1" ${due ? 'checked' : ''}> Due in the next 60 days or overdue</label>
      <button class="small">Show</button>
    </form>
    ${rows.length ? `<div class="scroll"><table>
      <thead><tr><th>Number</th><th>Type</th><th>Customer</th><th>Postcode</th><th>Outcome</th><th>Engineer</th><th>Issued</th><th>Next due</th></tr></thead>
      <tbody>${rows.map((c) => {
        const t = TYPES[c.type];
        const overdue = c.next_due && new Date(c.next_due) < new Date(new Date().toDateString());
        return `<tr class="${c.status === 'void' ? 'off' : ''}">
          <td><a href="/jobs/${c.job_id}/certs/${c.id}">${certNo(c)}</a></td><td>${esc(t ? t.name : c.type)}</td>
          <td><a href="/jobs/${c.job_id}">${esc(c.customer_name)}</a></td><td>${esc(c.postcode)}</td>
          <td>${c.status === 'void' ? 'Cancelled' : `<span class="tag ${t && t.bad(c.outcome || '') ? 'urgent' : 'ok'}">${esc(c.outcome)}</span>`}</td>
          <td>${esc(c.engineer_name)}</td><td>${day(c.issued_at)}</td>
          <td>${c.next_due ? `${overdue ? '<span class="tag urgent">Overdue</span> ' : ''}${day(c.next_due)}` : ''}</td></tr>`;
      }).join('')}</tbody></table></div>` : '<p class="empty">No certificates match.</p>'}`;
  res.send(page({ title: 'Certificates', user: req.user, body }));
}));

module.exports = { router, certificatesPanel, teamPanel, currentQuals };
