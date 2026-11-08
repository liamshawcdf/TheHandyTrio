const express = require('express');
const bcrypt = require('bcryptjs');
const { query } = require('../db');
const { page, esc, ROLE_LABELS } = require('../layout');
const { wrap, requireRole } = require('../auth');

const router = express.Router();

async function render(req, res, { notice, error, v = {} } = {}) {
  const { rows } = await query('SELECT id, role, name, email, phone, active FROM users ORDER BY role, name');
  const list = rows.map((u) => `<tr class="${u.active ? '' : 'off'}">
    <td>${esc(u.name)}</td><td>${esc(u.email)}</td><td>${esc(u.phone)}</td>
    <td>${esc(ROLE_LABELS[u.role])}</td>
    <td>${u.active ? 'Active' : 'Switched off'}</td>
    <td>${u.id === req.user.id ? '<span class="muted">You</span>' : `<form method="post" action="/admin/users/${u.id}/toggle" class="inline"><button class="small">${u.active ? 'Switch off' : 'Switch on'}</button></form>`}</td>
  </tr>`).join('');
  const roleOpt = (r) => `<option value="${r}" ${v.role === r ? 'selected' : ''}>${ROLE_LABELS[r]}</option>`;
  const body = `
    <div class="scroll"><table>
      <thead><tr><th>Name</th><th>Email</th><th>Phone</th><th>Role</th><th>Status</th><th></th></tr></thead>
      <tbody>${list}</tbody></table></div>
    <h2>Add a person</h2>
    <form method="post" action="/admin/users" class="panel narrow">
      <label>Full name<input name="name" value="${esc(v.name)}" required></label>
      <label>Email<input type="email" name="email" value="${esc(v.email)}" required></label>
      <label>Phone<input type="tel" name="phone" value="${esc(v.phone)}"></label>
      <label>Role<select name="role">${['builder', 'admin', 'customer'].map(roleOpt).join('')}</select></label>
      <label>Starting password (8 characters or more)<input type="password" name="password" required minlength="8" autocomplete="new-password"></label>
      <button class="primary">Add person</button>
    </form>`;
  res.status(error ? 400 : 200).send(page({ title: 'People', user: req.user, notice, error, body }));
}

router.get('/admin/users', requireRole('admin'), wrap(async (req, res) => {
  return render(req, res, { notice: req.query.added ? 'Person added.' : null });
}));

router.post('/admin/users', requireRole('admin'), wrap(async (req, res) => {
  const v = {
    name: String(req.body.name || '').trim(),
    email: String(req.body.email || '').trim().toLowerCase(),
    phone: String(req.body.phone || '').trim(),
    role: String(req.body.role || ''),
  };
  const password = String(req.body.password || '');
  let error = null;
  if (!v.name) error = 'Enter a name.';
  else if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v.email)) error = 'Enter a valid email address.';
  else if (!ROLE_LABELS[v.role]) error = 'Choose a role.';
  else if (password.length < 8) error = 'Starting password must be at least 8 characters.';
  if (error) return render(req, res, { error, v });

  try {
    await query('INSERT INTO users (role, name, email, phone, password_hash) VALUES ($1, $2, $3, $4, $5)',
      [v.role, v.name, v.email, v.phone || null, await bcrypt.hash(password, 12)]);
  } catch (e) {
    if (e.code === '23505') return render(req, res, { error: 'Someone already uses that email.', v });
    throw e;
  }
  res.redirect('/admin/users?added=1');
}));

router.post('/admin/users/:id/toggle', requireRole('admin'), wrap(async (req, res) => {
  const id = Number(req.params.id);
  if (Number.isInteger(id) && id !== req.user.id) {
    await query('UPDATE users SET active = NOT active WHERE id = $1', [id]);
  }
  res.redirect('/admin/users');
}));

module.exports = router;
