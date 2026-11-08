const express = require('express');
const bcrypt = require('bcryptjs');
const rateLimit = require('express-rate-limit');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap } = require('../auth');

const router = express.Router();

function loginForm(email = '') {
  return `<form method="post" action="/login" class="panel narrow">
  <label>Email<input type="email" name="email" value="${esc(email)}" required autocomplete="email"></label>
  <label>Password<input type="password" name="password" required autocomplete="current-password"></label>
  <button class="primary">Log in</button>
</form>
<p class="narrow">New customer? <a href="/register">Create an account</a> to request a job.</p>`;
}

function registerForm(v = {}) {
  return `<form method="post" action="/register" class="panel narrow">
  <label>Full name<input name="name" value="${esc(v.name)}" required autocomplete="name"></label>
  <label>Email<input type="email" name="email" value="${esc(v.email)}" required autocomplete="email"></label>
  <label>Phone<input type="tel" name="phone" value="${esc(v.phone)}" autocomplete="tel"></label>
  <label>Address<input name="address_line" value="${esc(v.address_line)}" autocomplete="street-address"></label>
  <div class="row">
    <label>Town<input name="town" value="${esc(v.town)}" autocomplete="address-level2"></label>
    <label>Postcode<input name="postcode" value="${esc(v.postcode)}" autocomplete="postal-code"></label>
  </div>
  <label>Password (8 characters or more)<input type="password" name="password" required minlength="8" autocomplete="new-password"></label>
  <label>Confirm password<input type="password" name="confirm" required minlength="8" autocomplete="new-password"></label>
  <button class="primary">Create account</button>
</form>
<p class="narrow">Already have an account? <a href="/login">Log in</a></p>`;
}

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 10,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  handler: (req, res) =>
    res.status(429).send(page({ title: 'Log in', error: 'Too many attempts. Wait 15 minutes, then try again.', body: loginForm() })),
});

function startSession(req, res, next, userId) {
  req.session.regenerate((err) => {
    if (err) return next(err);
    req.session.userId = userId;
    req.session.save((err2) => (err2 ? next(err2) : res.redirect('/dashboard')));
  });
}

router.get('/', (req, res) => res.redirect(req.user ? '/dashboard' : '/login'));

router.get('/login', (req, res) => {
  if (req.user) return res.redirect('/dashboard');
  res.send(page({ title: 'Log in', body: loginForm() }));
});

router.post('/login', loginLimiter, wrap(async (req, res, next) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  const password = String(req.body.password || '');
  const { rows } = await query('SELECT id, password_hash, active FROM users WHERE email = $1', [email]);
  const u = rows[0];
  const ok = u && u.active && (await bcrypt.compare(password, u.password_hash));
  if (!ok) {
    return res.status(401).send(page({ title: 'Log in', error: 'Email or password is incorrect.', body: loginForm(email) }));
  }
  startSession(req, res, next, u.id);
}));

router.get('/register', (req, res) => {
  if (req.user) return res.redirect('/dashboard');
  res.send(page({ title: 'Create your account', body: registerForm() }));
});

router.post('/register', loginLimiter, wrap(async (req, res, next) => {
  const v = {};
  for (const k of ['name', 'email', 'phone', 'address_line', 'town', 'postcode']) v[k] = String(req.body[k] || '').trim();
  v.email = v.email.toLowerCase();
  v.postcode = v.postcode.toUpperCase();
  const password = String(req.body.password || '');
  const confirm = String(req.body.confirm || '');

  let error = null;
  if (!v.name) error = 'Enter your name.';
  else if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v.email)) error = 'Enter a valid email address.';
  else if (password.length < 8) error = 'Password must be at least 8 characters.';
  else if (password !== confirm) error = 'The two passwords don’t match.';
  if (error) return res.status(400).send(page({ title: 'Create your account', error, body: registerForm(v) }));

  const hash = await bcrypt.hash(password, 12);
  try {
    const { rows } = await query(
      `INSERT INTO users (role, name, email, phone, address_line, town, postcode, password_hash)
       VALUES ('customer', $1, $2, $3, $4, $5, $6, $7) RETURNING id`,
      [v.name, v.email, v.phone || null, v.address_line || null, v.town || null, v.postcode || null, hash]
    );
    startSession(req, res, next, rows[0].id);
  } catch (e) {
    if (e.code === '23505') {
      return res.status(400).send(page({ title: 'Create your account', error: 'An account with that email already exists. Log in instead.', body: registerForm(v) }));
    }
    throw e;
  }
}));

router.post('/logout', (req, res, next) => {
  req.session.destroy((err) => {
    if (err) return next(err);
    res.clearCookie('handytrio.sid');
    res.redirect('/login');
  });
});

module.exports = router;
