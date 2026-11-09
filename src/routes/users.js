const express = require('express');
const bcrypt = require('bcryptjs');
const { query } = require('../db');
const { page, esc, ROLE_LABELS } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { locate } = require('../estimate');
const { QUAL_KINDS } = require('../certtypes');
const { day } = require('../format');

const router = express.Router();
const admin = requireRole('admin');
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const clean = (v, max = 200) => String(v ?? '').trim().slice(0, max);

function personFields(v = {}, { isSelf = false, isNew = false } = {}) {
  const roleOpt = (r) => `<option value="${r}" ${v.role === r ? 'selected' : ''}>${ROLE_LABELS[r]}</option>`;
  return `
    <label>Full name<input name="name" value="${esc(v.name)}" required maxlength="120"></label>
    <label>Email<input type="email" name="email" value="${esc(v.email)}" required></label>
    <label>Phone<input type="tel" name="phone" value="${esc(v.phone)}"></label>
    ${isSelf ? `<input type="hidden" name="role" value="${esc(v.role)}">` : `<label>Role<select name="role">${['builder', 'admin', 'customer'].map(roleOpt).join('')}</select></label>`}
    <label>Address<input name="address_line" value="${esc(v.address_line)}"></label>
    <div class="row">
      <label>Town<input name="town" value="${esc(v.town)}"></label>
      <label>Postcode<input name="postcode" value="${esc(v.postcode)}"></label>
    </div>
    <p class="hint">For builders this is their home postcode. Travel costs are worked out from it.</p>
    ${v.role === 'customer' ? '' : `<label>Pay rate per hour (only used for profit reports)<input name="cost_rate" type="number" step="0.01" min="0" value="${esc(v.cost_rate ?? '')}"></label>`}
    <label>${isNew ? 'Starting password (8 characters or more)' : 'New password (leave blank to keep the current one)'}
      <input type="password" name="password" ${isNew ? 'required' : ''} minlength="8" autocomplete="new-password"></label>`;
}

function readPerson(body) {
  return {
    name: clean(body.name, 120),
    email: clean(body.email).toLowerCase(),
    phone: clean(body.phone, 40),
    role: clean(body.role, 20),
    address_line: clean(body.address_line),
    town: clean(body.town, 80),
    postcode: clean(body.postcode, 10).toUpperCase(),
    password: String(body.password || ''),
    cost_rate: String(body.cost_rate ?? '').trim() === '' ? null : Math.max(0, Number(body.cost_rate) || 0),
  };
}

async function checkPerson(v, { isNew }) {
  if (!v.name) return 'Enter a name.';
  if (!EMAIL.test(v.email)) return 'Enter a valid email address.';
  if (!ROLE_LABELS[v.role]) return 'Choose a role.';
  if ((isNew || v.password) && v.password.length < 8) return 'Passwords must be at least 8 characters.';
  if (v.role === 'builder' && v.postcode && !(await locate(v.postcode))) {
    return `The postcode ${v.postcode} couldn’t be found. Check it, or leave it blank for now.`;
  }
  return null;
}

async function renderList(req, res, { notice, error, v = {} } = {}) {
  const { rows } = await query(
    `SELECT u.id, u.role, u.name, u.email, u.phone, u.postcode, u.active,
       (SELECT json_agg(json_build_object('kind', q.kind, 'expires', q.expires) ORDER BY q.expires) FROM staff_qualifications q WHERE q.user_id = u.id) AS quals
     FROM users u ORDER BY u.role, u.name`);
  const today = new Date(new Date().toDateString());
  const qualTags = (qs) => (qs || []).map((q) => {
    const exp = new Date(q.expires);
    const cls = exp < today ? 'urgent' : exp - today < 30 * 86400000 ? 'urgent' : 'ok';
    const short = q.kind === 'gas' ? 'Gas Safe' : q.kind === 'pat' ? 'PAT' : 'Electrical';
    return `<span class="tag ${cls}" title="Expires ${day(q.expires)}">${short}${exp < today ? ' expired' : ''}</span>`;
  }).join(' ');
  const list = rows.map((u) => `<tr class="${u.active ? '' : 'off'}">
    <td><a href="/admin/users/${u.id}">${esc(u.name)}</a></td><td>${esc(u.email)}</td><td>${esc(u.phone)}</td>
    <td>${esc(ROLE_LABELS[u.role])}</td>
    <td>${u.role === 'builder' && !u.postcode ? '<span class="tag urgent">Needs postcode</span>' : esc(u.postcode)}</td>
    <td>${qualTags(u.quals)}</td>
    <td>${u.active ? 'Active' : 'Switched off'}</td>
    <td>${u.id === req.user.id ? '<span class="muted">You</span>' : `<form method="post" action="/admin/users/${u.id}/toggle" class="inline"><button class="small">${u.active ? 'Switch off' : 'Switch on'}</button></form>`}</td>
  </tr>`).join('');
  const body = `
    <div class="scroll"><table>
      <thead><tr><th>Name</th><th>Email</th><th>Phone</th><th>Role</th><th>Postcode</th><th>Qualifications</th><th>Status</th><th></th></tr></thead>
      <tbody>${list}</tbody></table></div>
    <h2>Add a person</h2>
    <form method="post" action="/admin/users" class="panel narrow">
      ${personFields({ role: 'builder', ...v }, { isNew: true })}
      <button class="primary">Add person</button>
    </form>`;
  res.status(error ? 400 : 200).send(page({ title: 'People', user: req.user, notice, error, body }));
}

router.get('/admin/users', admin, wrap(async (req, res) => {
  return renderList(req, res, { notice: req.query.added ? 'Person added.' : req.query.saved ? 'Changes saved.' : null });
}));

router.post('/admin/users', admin, wrap(async (req, res) => {
  const v = readPerson(req.body);
  const error = await checkPerson(v, { isNew: true });
  if (error) return renderList(req, res, { error, v });
  try {
    await query(
      `INSERT INTO users (role, name, email, phone, address_line, town, postcode, password_hash, cost_rate)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
      [v.role, v.name, v.email, v.phone || null, v.address_line || null, v.town || null, v.postcode || null, await bcrypt.hash(v.password, 12), v.role === 'customer' ? null : v.cost_rate]);
  } catch (e) {
    if (e.code === '23505') return renderList(req, res, { error: 'Someone already uses that email.', v });
    throw e;
  }
  res.redirect('/admin/users?added=1');
}));

router.get('/admin/users/:id', admin, wrap(async (req, res) => {
  const id = Number(req.params.id);
  const u = Number.isInteger(id) && (await query('SELECT * FROM users WHERE id = $1', [id])).rows[0];
  if (!u) return res.redirect('/admin/users');
  const quals = (await query('SELECT * FROM staff_qualifications WHERE user_id = $1 ORDER BY kind, expires DESC', [u.id])).rows;
  const today = new Date(new Date().toDateString());
  const kindSel = (sel) => Object.entries(QUAL_KINDS).map(([k, v]) => `<option value="${k}" ${k === sel ? 'selected' : ''}>${esc(v.label)}</option>`).join('');
  const qualForm = (q, action, button) => `<form method="post" action="${action}" class="panel qualform">
      <div class="row">
        <label>Type<select name="kind">${kindSel(q.kind)}</select></label>
        <label>Scheme or body<input name="scheme" value="${esc(q.scheme)}" maxlength="80" placeholder="Gas Safe Register, NICEIC, NAPIT"></label>
      </div>
      <div class="row">
        <label>Registration or licence number<input name="number" value="${esc(q.number)}" maxlength="40" required></label>
        <label>Expiry or re-certification date<input type="date" name="expires" value="${q.expires ? new Date(q.expires).toLocaleDateString('en-CA') : ''}" required></label>
      </div>
      <label>Categories or qualifications<input name="categories" value="${esc(q.categories)}" maxlength="300" placeholder="CCN1, CENWAT, HTR1 or 18th Edition, 2391"></label>
      <label>Notes<input name="notes" value="${esc(q.notes)}" maxlength="300"></label>
      <button class="small">${button}</button>
    </form>`;
  const qualList = quals.map((q) => {
    const exp = new Date(q.expires);
    const status = exp < today ? '<span class="tag urgent">Expired</span>' : exp - today < 30 * 86400000 ? '<span class="tag urgent">Expires soon</span>' : '<span class="tag ok">In date</span>';
    return `<details class="panel qual"><summary><strong>${esc(QUAL_KINDS[q.kind].label)}</strong> ${esc(q.number)} ${status} <span class="muted">expires ${day(q.expires)}</span></summary>
      ${qualForm(q, `/admin/users/${u.id}/quals/${q.id}`, 'Save')}
      <form method="post" action="/admin/users/${u.id}/quals/${q.id}/delete" class="inline"><button class="small danger">Delete</button></form>
    </details>`;
  }).join('');
  const body = `<div class="twocol">
    <section>
      <form method="post" action="/admin/users/${u.id}" class="panel">
        ${personFields(u, { isSelf: u.id === req.user.id })}
        <button class="primary">Save changes</button>
      </form>
    </section>
    <section>
      <h2>Qualifications</h2>
      <p class="hint">Gas Safe, electrical scheme and PAT qualifications let this person issue certificates, but only while in date.</p>
      ${qualList || '<p class="empty">None added.</p>'}
      <h3>Add a qualification</h3>
      ${qualForm({ kind: 'gas' }, `/admin/users/${u.id}/quals`, 'Add qualification')}
    </section>
    </div>
    <p><a href="/admin/users">Back to people</a></p>`;
  res.send(page({ title: `Edit ${u.name}`, user: req.user, error: req.query.error ? clean(req.query.error) : null, body }));
}));

router.post('/admin/users/:id', admin, wrap(async (req, res) => {
  const id = Number(req.params.id);
  const existing = Number.isInteger(id) && (await query('SELECT id, role FROM users WHERE id = $1', [id])).rows[0];
  if (!existing) return res.redirect('/admin/users');
  const v = readPerson(req.body);
  if (id === req.user.id) v.role = existing.role; // you can't change your own role
  const error = await checkPerson(v, { isNew: false });
  if (error) return res.redirect(`/admin/users/${id}?error=${encodeURIComponent(error)}`);
  try {
    await query(
      `UPDATE users SET name = $1, email = $2, phone = $3, role = $4, address_line = $5, town = $6, postcode = $7, cost_rate = $8 WHERE id = $9`,
      [v.name, v.email, v.phone || null, v.role, v.address_line || null, v.town || null, v.postcode || null, v.role === 'customer' ? null : v.cost_rate, id]);
    if (v.password) await query('UPDATE users SET password_hash = $1 WHERE id = $2', [await bcrypt.hash(v.password, 12), id]);
  } catch (e) {
    if (e.code === '23505') return res.redirect(`/admin/users/${id}?error=${encodeURIComponent('Someone else already uses that email.')}`);
    throw e;
  }
  res.redirect('/admin/users?saved=1');
}));

function readQual(body) {
  const kind = QUAL_KINDS[body.kind] ? body.kind : null;
  const expires = /^\d{4}-\d{2}-\d{2}$/.test(body.expires || '') ? body.expires : null;
  return {
    kind, expires,
    scheme: clean(body.scheme, 80) || (kind ? QUAL_KINDS[kind].scheme : ''),
    number: clean(body.number, 40),
    categories: clean(body.categories, 300) || null,
    notes: clean(body.notes, 300) || null,
  };
}

router.post('/admin/users/:id/quals', admin, wrap(async (req, res) => {
  const id = Number(req.params.id) || 0;
  const q = readQual(req.body);
  if (!q.kind || !q.expires || !q.number) return res.redirect(`/admin/users/${id}?error=${encodeURIComponent('Fill in the type, number and expiry date.')}`);
  await query('INSERT INTO staff_qualifications (user_id, kind, scheme, number, categories, expires, notes) VALUES ($1, $2, $3, $4, $5, $6, $7)',
    [id, q.kind, q.scheme, q.number, q.categories, q.expires, q.notes]);
  res.redirect(`/admin/users/${id}`);
}));

router.post('/admin/users/:id/quals/:qid', admin, wrap(async (req, res) => {
  const id = Number(req.params.id) || 0;
  const q = readQual(req.body);
  if (!q.kind || !q.expires || !q.number) return res.redirect(`/admin/users/${id}?error=${encodeURIComponent('Fill in the type, number and expiry date.')}`);
  await query('UPDATE staff_qualifications SET kind = $1, scheme = $2, number = $3, categories = $4, expires = $5, notes = $6 WHERE id = $7 AND user_id = $8',
    [q.kind, q.scheme, q.number, q.categories, q.expires, q.notes, Number(req.params.qid) || 0, id]);
  res.redirect(`/admin/users/${id}`);
}));

router.post('/admin/users/:id/quals/:qid/delete', admin, wrap(async (req, res) => {
  const id = Number(req.params.id) || 0;
  await query('DELETE FROM staff_qualifications WHERE id = $1 AND user_id = $2', [Number(req.params.qid) || 0, id]);
  res.redirect(`/admin/users/${id}`);
}));

router.post('/admin/users/:id/toggle', admin, wrap(async (req, res) => {
  const id = Number(req.params.id);
  if (Number.isInteger(id) && id !== req.user.id) {
    await query('UPDATE users SET active = NOT active WHERE id = $1', [id]);
  }
  res.redirect('/admin/users');
}));

module.exports = router;
