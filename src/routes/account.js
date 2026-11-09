const express = require('express');
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const rateLimit = require('express-rate-limit');
const { query, pool } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin } = require('../auth');
const { sendEmail, notifyOffice } = require('../notify');
const { baseUrlOf } = require('../jobs-shared');
const privacyDefault = require('../privacy-default');

const router = express.Router();
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const sha = (t) => crypto.createHash('sha256').update(t).digest('hex');

function loginForm(email = '') {
  return `<form method="post" action="/login" class="panel narrow">
  <label>Email<input type="email" name="email" value="${esc(email)}" required autocomplete="email"></label>
  <label>Password<input type="password" name="password" required autocomplete="current-password"></label>
  <button class="primary">Log in</button>
  <p><a href="/forgot">Forgotten your password?</a></p>
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
  <label class="check"><input type="checkbox" name="privacy" required ${v.privacy ? 'checked' : ''}> I’ve read the <a href="/privacy" target="_blank" rel="noopener">privacy notice</a></label>
  <button class="primary">Create account</button>
</form>
<p class="narrow">Already have an account? <a href="/login">Log in</a></p>`;
}

const limiter = (title, body) => rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 10,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  handler: (req, res) => res.status(429).send(page({ title, error: 'Too many attempts. Wait 15 minutes, then try again.', body: body() })),
});
const loginLimiter = limiter('Log in', () => loginForm());
const forgotLimiter = limiter('Reset your password', () => '<p><a href="/login">Back to log in</a></p>');

function startSession(req, res, next, userId, to = '/dashboard') {
  req.session.regenerate((err) => {
    if (err) return next(err);
    req.session.userId = userId;
    req.session.save((err2) => (err2 ? next(err2) : res.redirect(to)));
  });
}

router.get('/', (req, res) => res.redirect(req.user ? '/dashboard' : '/login'));

router.get('/login', (req, res) => {
  if (req.user) return res.redirect('/dashboard');
  res.send(page({ title: 'Log in', notice: req.query.reset ? 'Password changed. Log in with your new password.' : null, body: loginForm() }));
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
  for (const k of ['name', 'email', 'phone', 'address_line', 'town', 'postcode']) v[k] = String(req.body[k] || '').trim().slice(0, 200);
  v.email = v.email.toLowerCase();
  v.postcode = v.postcode.toUpperCase();
  v.privacy = req.body.privacy === 'on';
  const password = String(req.body.password || '');
  const confirm = String(req.body.confirm || '');

  let error = null;
  if (!v.name) error = 'Enter your name.';
  else if (!EMAIL.test(v.email)) error = 'Enter a valid email address.';
  else if (password.length < 8) error = 'Password must be at least 8 characters.';
  else if (password !== confirm) error = 'The two passwords don’t match.';
  else if (!v.privacy) error = 'Please confirm you’ve read the privacy notice.';
  if (error) return res.status(400).send(page({ title: 'Create your account', error, body: registerForm(v) }));

  const hash = await bcrypt.hash(password, 12);
  try {
    const { rows } = await query(
      `INSERT INTO users (role, name, email, phone, address_line, town, postcode, password_hash, privacy_accepted_at)
       VALUES ('customer', $1, $2, $3, $4, $5, $6, $7, now()) RETURNING id`,
      [v.name, v.email, v.phone || null, v.address_line || null, v.town || null, v.postcode || null, hash]
    );
    startSession(req, res, next, rows[0].id);
  } catch (e) {
    if (e.code === '23505') {
      return res.status(400).send(page({ title: 'Create your account', error: 'An account with that email already exists. Log in, or reset your password.', body: registerForm(v) }));
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

// ---------- Forgotten password ----------
router.get('/forgot', (req, res) => {
  res.send(page({ title: 'Reset your password', user: req.user, body: `<form method="post" action="/forgot" class="panel narrow">
    <p>Enter the email you use to log in and we’ll send you a link to set a new password.</p>
    <label>Email<input type="email" name="email" required autocomplete="email"></label>
    <button class="primary">Send reset link</button>
  </form><p><a href="/login">Back to log in</a></p>` }));
});

router.post('/forgot', forgotLimiter, wrap(async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  const u = (await query('SELECT id, name, email FROM users WHERE email = $1 AND active', [email])).rows[0];
  if (u) {
    const token = crypto.randomBytes(32).toString('hex');
    await query("INSERT INTO password_resets (user_id, token_hash, expires_at) VALUES ($1, $2, now() + interval '1 hour')", [u.id, sha(token)]);
    const link = `${baseUrlOf(req)}/reset/${token}`;
    const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
    const body = (l) => `Hi ${u.name.split(' ')[0]},\n\nSomeone asked to reset the password for your ${s.business_name} account. To choose a new password, open this link within the next hour:\n\n${l}\n\nIf this wasn’t you, ignore this email and your password stays the same.\n\n${s.business_name}`;
    const r = await sendEmail({ to: u.email, subject: `Reset your ${s.business_name} password`, body: body(link), logBody: body('[reset link hidden for security]') });
    // While email sending isn't set up, show the link in the terminal so it can be tested.
    if (r.status !== 'sent') console.log(`Password reset link for ${u.email}: ${link}`);
  }
  // Same answer either way, so nobody can use this page to find out who has an account.
  res.send(page({ title: 'Check your email', body: `<div class="panel narrow"><p>If <strong>${esc(email)}</strong> has an account, we’ve sent a link to reset the password. It works for one hour.</p><p>Not arrived? Check your junk folder, or <a href="/forgot">try again</a>.</p></div>` }));
}));

async function validReset(token) {
  if (!/^[a-f0-9]{64}$/.test(token || '')) return null;
  return (await query('SELECT * FROM password_resets WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now()', [sha(token)])).rows[0] || null;
}

const resetForm = (token) => `<form method="post" action="/reset/${esc(token)}" class="panel narrow">
  <label>New password (8 characters or more)<input type="password" name="password" required minlength="8" autocomplete="new-password"></label>
  <label>Confirm new password<input type="password" name="confirm" required minlength="8" autocomplete="new-password"></label>
  <button class="primary">Save new password</button></form>`;

const expired = () => page({ title: 'Link expired', body: '<div class="panel narrow"><p>This reset link has expired or has already been used.</p><p><a class="button primary" href="/forgot">Send a new link</a></p></div>' });

router.get('/reset/:token', wrap(async (req, res) => {
  if (!(await validReset(req.params.token))) return res.status(400).send(expired());
  res.send(page({ title: 'Choose a new password', body: resetForm(req.params.token) }));
}));

router.post('/reset/:token', forgotLimiter, wrap(async (req, res) => {
  const r = await validReset(req.params.token);
  if (!r) return res.status(400).send(expired());
  const password = String(req.body.password || '');
  if (password.length < 8 || password !== String(req.body.confirm || '')) {
    return res.status(400).send(page({ title: 'Choose a new password', error: password.length < 8 ? 'Password must be at least 8 characters.' : 'The two passwords don’t match.', body: resetForm(req.params.token) }));
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE users SET password_hash = $1 WHERE id = $2', [await bcrypt.hash(password, 12), r.user_id]);
    await client.query('UPDATE password_resets SET used_at = now() WHERE user_id = $1 AND used_at IS NULL', [r.user_id]);
    // Log the account out everywhere else.
    await client.query("DELETE FROM session WHERE (sess::jsonb ->> 'userId') = $1", [String(r.user_id)]);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  res.redirect('/login?reset=1');
}));

// ---------- My account ----------
router.get('/account', requireLogin, wrap(async (req, res) => {
  const u = (await query('SELECT * FROM users WHERE id = $1', [req.user.id])).rows[0];
  const body = `<div class="twocol">
    <section>
      <h2>Your details</h2>
      <form method="post" action="/account" class="panel">
        <label>Full name<input name="name" value="${esc(u.name)}" required maxlength="120"></label>
        <label>Phone<input type="tel" name="phone" value="${esc(u.phone)}"></label>
        <label>Address<input name="address_line" value="${esc(u.address_line)}"></label>
        <div class="row">
          <label>Town<input name="town" value="${esc(u.town)}"></label>
          <label>Postcode<input name="postcode" value="${esc(u.postcode)}"></label>
        </div>
        <p class="hint">Email: ${esc(u.email)}. To change it, contact us.</p>
        <button class="primary">Save details</button>
      </form>
    </section>
    <section>
      <h2>Change password</h2>
      <form method="post" action="/account/password" class="panel">
        <label>Current password<input type="password" name="current" required autocomplete="current-password"></label>
        <label>New password (8 characters or more)<input type="password" name="password" required minlength="8" autocomplete="new-password"></label>
        <label>Confirm new password<input type="password" name="confirm" required minlength="8" autocomplete="new-password"></label>
        <button class="primary">Change password</button>
      </form>
      ${u.role === 'customer' ? `<h2>Your data</h2>
      <div class="panel">
        <p><a class="button" href="/account/data">Download my data</a></p>
        <details><summary>Ask us to delete my account</summary>
          <form method="post" action="/account/delete-request">
            <p class="hint">We’ll remove what we can. By law we keep invoices for 6 years and safety certificates as long as required.</p>
            <label>Anything we should know? (optional)<textarea name="note" rows="2" maxlength="500"></textarea></label>
            <button class="small danger">Send request</button>
          </form>
        </details>
      </div>` : ''}
    </section>
  </div>`;
  const notice = req.query.saved ? 'Details saved.' : req.query.pw ? 'Password changed.' : req.query.asked ? 'Request sent. We’ll be in touch.' : null;
  res.send(page({ title: 'My account', user: req.user, notice, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
}));

router.post('/account', requireLogin, wrap(async (req, res) => {
  const t = (k, n = 200) => String(req.body[k] || '').trim().slice(0, n);
  if (!t('name')) return res.redirect('/account?error=' + encodeURIComponent('Enter your name.'));
  await query('UPDATE users SET name = $1, phone = $2, address_line = $3, town = $4, postcode = $5 WHERE id = $6',
    [t('name', 120), t('phone', 40) || null, t('address_line') || null, t('town', 80) || null, t('postcode', 10).toUpperCase() || null, req.user.id]);
  res.redirect('/account?saved=1');
}));

router.post('/account/password', requireLogin, loginLimiter, wrap(async (req, res) => {
  const u = (await query('SELECT password_hash FROM users WHERE id = $1', [req.user.id])).rows[0];
  const password = String(req.body.password || '');
  let error = null;
  if (!(await bcrypt.compare(String(req.body.current || ''), u.password_hash))) error = 'Your current password is wrong.';
  else if (password.length < 8) error = 'New password must be at least 8 characters.';
  else if (password !== String(req.body.confirm || '')) error = 'The two new passwords don’t match.';
  if (error) return res.redirect('/account?error=' + encodeURIComponent(error));
  await query('UPDATE users SET password_hash = $1 WHERE id = $2', [await bcrypt.hash(password, 12), req.user.id]);
  res.redirect('/account?pw=1');
}));

router.get('/account/data', requireLogin, wrap(async (req, res) => {
  const id = req.user.id;
  const one = async (sql) => (await query(sql, [id])).rows;
  const data = {
    exported_at: new Date().toISOString(),
    account: (await one('SELECT name, email, phone, address_line, town, postcode, created_at, privacy_accepted_at FROM users WHERE id = $1'))[0],
    jobs: await one(`SELECT id, title, work_type, description, address_line, town, postcode, access_info, preferred_start, preferred_end,
      status, scheduled_start, scheduled_end, created_at FROM jobs WHERE customer_id = $1 ORDER BY id`),
    quotes: await one(`SELECT q.id, q.job_id, q.scope, q.net, q.vat, q.total, q.status, q.created_at FROM quotes q JOIN jobs j ON j.id = q.job_id WHERE j.customer_id = $1 AND q.status <> 'superseded'`),
    invoices: await one(`SELECT i.id, i.job_id, i.kind, i.total, i.amount_due, i.status, i.created_at FROM invoices i JOIN jobs j ON j.id = i.job_id WHERE j.customer_id = $1 AND i.status <> 'void'`),
    payments: await one('SELECT p.amount, p.method, p.received_at, p.job_id FROM payments p JOIN jobs j ON j.id = p.job_id WHERE j.customer_id = $1'),
    certificates: await one(`SELECT c.id, c.job_id, c.type, c.outcome, c.issued_at, c.next_due FROM certificates c JOIN jobs j ON j.id = c.job_id WHERE j.customer_id = $1 AND c.status = 'issued'`),
    emails_sent_to_you: await one('SELECT subject, created_at FROM email_log WHERE to_address = (SELECT email FROM users WHERE id = $1) ORDER BY created_at'),
  };
  res.setHeader('Content-Disposition', 'attachment; filename="my-data.json"');
  res.json(data);
}));

router.post('/account/delete-request', requireLogin, wrap(async (req, res) => {
  const note = String(req.body.note || '').trim().slice(0, 500);
  await notifyOffice(`Account deletion request from ${req.user.name}`,
    `${req.user.name} (${req.user.email}) has asked for their account to be deleted.${note ? `\n\nTheir note: ${note}` : ''}\n\nYou must reply within one month. Keep invoices (6 years) and certificates; remove the rest.\n${baseUrlOf(req)}/admin/users`);
  res.redirect('/account?asked=1');
}));

// ---------- Privacy notice ----------
router.get('/privacy', wrap(async (req, res) => {
  const s = (await query('SELECT business_name, business_email, privacy_notice FROM settings WHERE id = 1')).rows[0];
  const text = s.privacy_notice || privacyDefault(s);
  res.send(page({ title: 'Privacy notice', user: req.user, body: `<div class="panel prose pre">${esc(text)}</div>` }));
}));

module.exports = router;
