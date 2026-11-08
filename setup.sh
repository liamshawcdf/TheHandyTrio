#!/usr/bin/env bash
# TheHandyTrio stage 1 setup. Run once in a fresh Codespace: bash setup.sh
set -e
mkdir -p src/routes scripts db public

cat > package.json <<'HANDYTRIO_EOF'
{
  "name": "thehandytrio",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "db": "bash scripts/db.sh",
    "migrate": "node scripts/migrate.js",
    "dev": "bash scripts/db.sh && node scripts/migrate.js && node --watch src/server.js",
    "start": "node scripts/migrate.js && node src/server.js",
    "create-admin": "node scripts/create-admin.js"
  }
}
HANDYTRIO_EOF

cat > .gitignore <<'HANDYTRIO_EOF'
node_modules
.env
HANDYTRIO_EOF

cat > save.sh <<'HANDYTRIO_EOF'
#!/usr/bin/env bash
git add -A
git commit -m "${1:-update}"
git push
HANDYTRIO_EOF

cat > db/schema.sql <<'HANDYTRIO_EOF'
-- TheHandyTrio schema. Safe to run repeatedly.

CREATE TABLE IF NOT EXISTS users (
  id            serial PRIMARY KEY,
  role          text NOT NULL CHECK (role IN ('customer','builder','admin')),
  name          text NOT NULL,
  email         text NOT NULL UNIQUE,
  phone         text,
  address_line  text,
  town          text,
  postcode      text,
  password_hash text NOT NULL,
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS settings (
  id                   int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  business_name        text    NOT NULL DEFAULT 'TheHandyTrio',
  currency             text    NOT NULL DEFAULT '£',
  base_postcode        text    NOT NULL DEFAULT '',
  service_radius_miles numeric NOT NULL DEFAULT 25,
  vat_registered       boolean NOT NULL DEFAULT true,
  vat_rate             numeric NOT NULL DEFAULT 20,
  hourly_rate          numeric NOT NULL DEFAULT 35,
  day_rate             numeric NOT NULL DEFAULT 250,
  hours_per_day        numeric NOT NULL DEFAULT 8,
  default_crew         int     NOT NULL DEFAULT 1,
  minimum_charge       numeric NOT NULL DEFAULT 80,
  markup_pct           numeric NOT NULL DEFAULT 15,
  waste_pct            numeric NOT NULL DEFAULT 10,
  mileage_rate         numeric NOT NULL DEFAULT 0.45,
  charge_travel_time   boolean NOT NULL DEFAULT true,
  travel_hourly_rate   numeric NOT NULL DEFAULT 35,
  contingency_pct      numeric NOT NULL DEFAULT 10,
  range_low_pct        numeric NOT NULL DEFAULT 10,
  range_high_pct       numeric NOT NULL DEFAULT 20,
  urgent_premium_pct   numeric NOT NULL DEFAULT 25,
  urgent_within_hours  int     NOT NULL DEFAULT 48,
  deposit_pct          numeric NOT NULL DEFAULT 30,
  payment_terms_days   int     NOT NULL DEFAULT 14,
  updated_at           timestamptz NOT NULL DEFAULT now()
);
INSERT INTO settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS jobs (
  id                  serial PRIMARY KEY,
  customer_id         int NOT NULL REFERENCES users(id),
  assigned_builder_id int REFERENCES users(id),
  title               text NOT NULL,
  description         text,
  address_line        text,
  town                text,
  postcode            text,
  access_info         text,
  preferred_start     date,
  preferred_end       date,
  urgent              boolean NOT NULL DEFAULT false,
  status              text NOT NULL DEFAULT 'request' CHECK (status IN (
                        'request','inspection_required','estimated','inspection_booked',
                        'inspected','quoted','accepted','declined','deposit_requested',
                        'deposit_paid','parts_ordered','scheduled','in_progress',
                        'complete','invoiced','paid','cancelled')),
  estimate_low        numeric,
  estimate_high       numeric,
  estimate_snapshot   jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS jobs_customer_idx ON jobs (customer_id);
CREATE INDEX IF NOT EXISTS jobs_builder_idx  ON jobs (assigned_builder_id);
CREATE INDEX IF NOT EXISTS jobs_status_idx   ON jobs (status);

CREATE TABLE IF NOT EXISTS job_status_history (
  id          serial PRIMARY KEY,
  job_id      int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  from_status text,
  to_status   text NOT NULL,
  changed_by  int REFERENCES users(id),
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
HANDYTRIO_EOF

cat > scripts/db.sh <<'HANDYTRIO_EOF'
#!/usr/bin/env bash
set -e
if docker ps -a --format '{{.Names}}' | grep -q '^handytrio-db$'; then
  docker start handytrio-db >/dev/null
else
  docker run -d --name handytrio-db \
    -e POSTGRES_USER=handy -e POSTGRES_PASSWORD=handy -e POSTGRES_DB=handytrio \
    -p 5433:5432 -v handytrio-data:/var/lib/postgresql/data postgres:16 >/dev/null
fi
echo "Waiting for database..."
until docker exec handytrio-db pg_isready -U handy -d handytrio >/dev/null 2>&1; do sleep 1; done
echo "Database ready"
HANDYTRIO_EOF

cat > scripts/migrate.js <<'HANDYTRIO_EOF'
require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { Client } = require('pg');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const sql = fs.readFileSync(path.join(__dirname, '..', 'db', 'schema.sql'), 'utf8');
  let client;
  for (let attempt = 1; attempt <= 30; attempt++) {
    client = new Client({ connectionString: process.env.DATABASE_URL });
    try {
      await client.connect();
      break;
    } catch (e) {
      await client.end().catch(() => {});
      if (attempt === 30) {
        console.error('Could not connect to the database:', e.message);
        process.exit(1);
      }
      await sleep(1000);
    }
  }
  try {
    await client.query(sql);
    console.log('Database schema up to date');
  } catch (e) {
    console.error('Schema error:', e.message);
    process.exitCode = 1;
  } finally {
    await client.end();
  }
})();
HANDYTRIO_EOF

cat > scripts/create-admin.js <<'HANDYTRIO_EOF'
require('dotenv').config();
const bcrypt = require('bcryptjs');
const { Client } = require('pg');

(async () => {
  const [email, name, password] = process.argv.slice(2);
  if (!email || !name || !password) {
    console.log('Usage: npm run create-admin -- you@example.com "Your Name" "a-strong-password"');
    process.exit(1);
  }
  if (password.length < 8) {
    console.log('Password must be at least 8 characters.');
    process.exit(1);
  }
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  const hash = await bcrypt.hash(password, 12);
  await client.query(
    `INSERT INTO users (role, name, email, password_hash)
     VALUES ('admin', $1, $2, $3)
     ON CONFLICT (email) DO UPDATE
       SET role = 'admin', name = EXCLUDED.name, password_hash = EXCLUDED.password_hash, active = true`,
    [name.trim(), email.trim().toLowerCase(), hash]
  );
  await client.end();
  console.log(`Admin account ready for ${email.trim().toLowerCase()}`);
})().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
HANDYTRIO_EOF

cat > src/db.js <<'HANDYTRIO_EOF'
const { Pool } = require('pg');

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

module.exports = {
  pool,
  query: (text, params) => pool.query(text, params),
};
HANDYTRIO_EOF

cat > src/statuses.js <<'HANDYTRIO_EOF'
// The job lifecycle, in order. Keys must match the CHECK list in db/schema.sql.
const STATUSES = [
  ['request', 'New request'],
  ['inspection_required', 'Inspection required'],
  ['estimated', 'Estimate sent'],
  ['inspection_booked', 'Inspection booked'],
  ['inspected', 'Inspected'],
  ['quoted', 'Quote sent'],
  ['accepted', 'Quote accepted'],
  ['declined', 'Declined'],
  ['deposit_requested', 'Deposit requested'],
  ['deposit_paid', 'Deposit paid'],
  ['parts_ordered', 'Parts ordered'],
  ['scheduled', 'Scheduled'],
  ['in_progress', 'In progress'],
  ['complete', 'Work complete'],
  ['invoiced', 'Invoiced'],
  ['paid', 'Paid'],
  ['cancelled', 'Cancelled'],
];

const LABELS = Object.fromEntries(STATUSES);
const CLOSED = ['paid', 'declined', 'cancelled'];

module.exports = {
  STATUSES,
  CLOSED,
  label: (key) => LABELS[key] || key,
};
HANDYTRIO_EOF

cat > src/layout.js <<'HANDYTRIO_EOF'
const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin' };

function nav(user) {
  if (!user) return '<a href="/login">Log in</a><a href="/register">Create account</a>';
  const links = ['<a href="/dashboard">Dashboard</a>'];
  if (user.role === 'admin') {
    links.push('<a href="/admin/users">People</a>', '<a href="/admin/settings">Rates &amp; settings</a>');
  }
  links.push('<form method="post" action="/logout" class="inline"><button class="linkish">Log out</button></form>');
  return links.join('');
}

function page({ title, user, body, notice, error }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} | TheHandyTrio</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow:wght@400;500;600&family=Barlow+Condensed:wght@600;700&display=swap">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<header class="top">
  <a class="brand" href="/">TheHandyTrio</a>
  <nav>${nav(user)}</nav>
</header>
<div class="stripe" aria-hidden="true"></div>
<main>
  ${user ? `<p class="who">Signed in as ${esc(user.name)} (${esc(ROLE_LABELS[user.role] || user.role)})</p>` : ''}
  <h1>${esc(title)}</h1>
  ${notice ? `<div class="notice" role="status">${esc(notice)}</div>` : ''}
  ${error ? `<div class="error" role="alert">${esc(error)}</div>` : ''}
  ${body}
</main>
</body>
</html>`;
}

module.exports = { esc, page, ROLE_LABELS };
HANDYTRIO_EOF

cat > src/auth.js <<'HANDYTRIO_EOF'
const { page } = require('./layout');

// Lets async route handlers pass errors to Express's error handler.
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function requireLogin(req, res, next) {
  if (!req.user) return res.redirect('/login');
  next();
}

function requireRole(...roles) {
  return (req, res, next) => {
    if (!req.user) return res.redirect('/login');
    if (!roles.includes(req.user.role)) {
      return res.status(403).send(page({
        title: 'No access',
        user: req.user,
        body: '<p>Your account can’t open this page.</p><p><a href="/dashboard">Back to your dashboard</a></p>',
      }));
    }
    next();
  };
}

module.exports = { wrap, requireLogin, requireRole };
HANDYTRIO_EOF

cat > src/server.js <<'HANDYTRIO_EOF'
require('dotenv').config();
const path = require('path');
const express = require('express');
const session = require('express-session');
const PgSession = require('connect-pg-simple')(session);
const helmet = require('helmet');
const { pool, query } = require('./db');
const { page } = require('./layout');
const { wrap } = require('./auth');

if (!process.env.SESSION_SECRET || !process.env.DATABASE_URL) {
  console.error('Missing SESSION_SECRET or DATABASE_URL in .env');
  process.exit(1);
}

const app = express();
app.set('trust proxy', 1);
app.disable('x-powered-by');

app.use(helmet());
app.use(express.urlencoded({ extended: false, limit: '100kb' }));
app.use(express.static(path.join(__dirname, '..', 'public')));

app.use(session({
  name: 'handytrio.sid',
  store: new PgSession({ pool, createTableIfMissing: true }),
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, sameSite: 'lax', secure: 'auto', maxAge: 1000 * 60 * 60 * 24 * 7 },
}));

// Load the logged-in person on every request.
app.use(wrap(async (req, res, next) => {
  req.user = null;
  if (req.session.userId) {
    const { rows } = await query('SELECT id, role, name, email FROM users WHERE id = $1 AND active', [req.session.userId]);
    req.user = rows[0] || null;
    if (!req.user) delete req.session.userId;
  }
  next();
}));

app.use(require('./routes/account'));
app.use(require('./routes/dashboard'));
app.use(require('./routes/settings'));
app.use(require('./routes/users'));

app.use((req, res) => {
  res.status(404).send(page({ title: 'Page not found', user: req.user, body: '<p>That page doesn’t exist.</p><p><a href="/">Go to the start</a></p>' }));
});

app.use((err, req, res, next) => {
  console.error(err);
  if (res.headersSent) return next(err);
  res.status(500).send(page({ title: 'Something went wrong', user: req.user, body: '<p>The app hit an error. It has been logged. Go back and try again.</p><p><a href="/">Go to the start</a></p>' }));
});

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`TheHandyTrio running on port ${port}`));
HANDYTRIO_EOF

cat > src/routes/account.js <<'HANDYTRIO_EOF'
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
HANDYTRIO_EOF

cat > src/routes/dashboard.js <<'HANDYTRIO_EOF'
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin } = require('../auth');
const { STATUSES, CLOSED, label } = require('../statuses');

const router = express.Router();

const ref = (id) => 'HT-' + String(id).padStart(5, '0');
const day = (d) => (d ? new Date(d).toLocaleDateString('en-GB') : '');

function jobsTable(jobs, { showCustomer = false, showBuilder = false } = {}) {
  if (!jobs.length) return '';
  const rows = jobs.map((j) => `<tr>
    <td>${ref(j.id)}</td>
    <td>${esc(j.title)}${j.urgent ? ' <span class="tag urgent">Urgent</span>' : ''}</td>
    ${showCustomer ? `<td>${esc(j.customer_name)}</td>` : ''}
    <td>${esc(j.postcode)}</td>
    <td><span class="tag s-${esc(j.status)}">${esc(label(j.status))}</span></td>
    ${showBuilder ? `<td>${esc(j.builder_name || 'Not assigned')}</td>` : ''}
    <td>${day(j.created_at)}</td>
  </tr>`).join('');
  return `<div class="scroll"><table>
    <thead><tr><th>Job</th><th>Work</th>${showCustomer ? '<th>Customer</th>' : ''}<th>Postcode</th><th>Stage</th>${showBuilder ? '<th>Builder</th>' : ''}<th>Requested</th></tr></thead>
    <tbody>${rows}</tbody></table></div>`;
}

const JOB_SELECT = `SELECT j.*, c.name AS customer_name, b.name AS builder_name
  FROM jobs j JOIN users c ON c.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id`;

router.get('/dashboard', requireLogin, wrap(async (req, res) => {
  const user = req.user;

  if (user.role === 'customer') {
    const { rows } = await query(`${JOB_SELECT} WHERE j.customer_id = $1 ORDER BY j.created_at DESC`, [user.id]);
    const body = `
      <section class="panel callout">
        <h2>Need something done?</h2>
        <p>Job requests open in the next update. You’ll be able to describe the work, add photos and pick when you’d like it done.</p>
      </section>
      <h2>Your jobs</h2>
      ${jobsTable(rows) || '<p class="empty">You haven’t requested any jobs yet.</p>'}`;
    return res.send(page({ title: 'Your dashboard', user, body }));
  }

  if (user.role === 'builder') {
    const { rows } = await query(
      `${JOB_SELECT} WHERE j.assigned_builder_id = $1 AND j.status <> ALL($2) ORDER BY j.preferred_start NULLS LAST, j.created_at`,
      [user.id, CLOSED]
    );
    const body = `<h2>Your jobs</h2>
      ${jobsTable(rows, { showCustomer: true }) || '<p class="empty">No jobs assigned to you yet. The office will assign them here.</p>'}`;
    return res.send(page({ title: 'Builder dashboard', user, body }));
  }

  // Admin
  const counts = await query('SELECT status, count(*)::int AS n FROM jobs GROUP BY status');
  const byStatus = Object.fromEntries(counts.rows.map((r) => [r.status, r.n]));
  const pipeline = STATUSES.filter(([k]) => !CLOSED.includes(k))
    .map(([k, l]) => `<li class="${byStatus[k] ? 'has' : ''}"><span class="n">${byStatus[k] || 0}</span><span>${esc(l)}</span></li>`)
    .join('');
  const open = await query(`${JOB_SELECT} WHERE j.status <> ALL($1) ORDER BY j.created_at DESC LIMIT 50`, [CLOSED]);
  const s = (await query('SELECT base_postcode FROM settings WHERE id = 1')).rows[0];

  const body = `
    ${!s.base_postcode ? '<div class="error">Add your base postcode in <a href="/admin/settings">Rates &amp; settings</a> so travel costs can be worked out.</div>' : ''}
    <h2>Job pipeline</h2>
    <ol class="pipeline">${pipeline}</ol>
    <h2>Open jobs</h2>
    ${jobsTable(open.rows, { showCustomer: true, showBuilder: true }) || '<p class="empty">No open jobs. New customer requests will appear here.</p>'}`;
  res.send(page({ title: 'Office dashboard', user, body }));
}));

module.exports = router;
HANDYTRIO_EOF

cat > src/routes/settings.js <<'HANDYTRIO_EOF'
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');

const router = express.Router();

// One list drives both the form and the save, so adding a setting is one line here plus a column in schema.sql.
const GROUPS = [
  ['Business', [
    ['business_name', 'Business name', 'text'],
    ['currency', 'Currency symbol', 'text'],
    ['base_postcode', 'Base postcode (travel is measured from here)', 'text'],
    ['service_radius_miles', 'Service area (miles)', 'number', '1'],
    ['vat_registered', 'VAT registered', 'bool'],
    ['vat_rate', 'VAT rate (%)', 'number', '0.1'],
  ]],
  ['Labour', [
    ['hourly_rate', 'Hourly rate per person', 'number', '0.01'],
    ['day_rate', 'Day rate per person', 'number', '0.01'],
    ['hours_per_day', 'Hours in a working day', 'number', '0.5'],
    ['default_crew', 'Default crew size', 'int', '1'],
    ['minimum_charge', 'Minimum charge per job', 'number', '0.01'],
  ]],
  ['Materials', [
    ['markup_pct', 'Markup on supplier prices (%)', 'number', '0.1'],
    ['waste_pct', 'Waste allowance on cut materials (%)', 'number', '0.1'],
  ]],
  ['Travel', [
    ['mileage_rate', 'Rate per mile', 'number', '0.01'],
    ['charge_travel_time', 'Charge for travel time', 'bool'],
    ['travel_hourly_rate', 'Travel time hourly rate', 'number', '0.01'],
  ]],
  ['Estimates', [
    ['contingency_pct', 'Contingency (%)', 'number', '0.1'],
    ['range_low_pct', 'Range shown below estimate (%)', 'number', '0.1'],
    ['range_high_pct', 'Range shown above estimate (%)', 'number', '0.1'],
    ['urgent_premium_pct', 'Urgent job premium (%)', 'number', '0.1'],
    ['urgent_within_hours', 'Counts as urgent if needed within (hours)', 'int', '1'],
  ]],
  ['Payments', [
    ['deposit_pct', 'Deposit on accepted quotes (%)', 'number', '0.1'],
    ['payment_terms_days', 'Invoice payment terms (days)', 'int', '1'],
  ]],
];
const FIELDS = GROUPS.flatMap(([, f]) => f);

function form(s) {
  const groups = GROUPS.map(([name, fields]) => `<fieldset class="panel"><legend>${esc(name)}</legend>
    ${fields.map(([key, lbl, type, step]) => type === 'bool'
      ? `<label class="check"><input type="checkbox" name="${key}" ${s[key] ? 'checked' : ''}> ${esc(lbl)}</label>`
      : `<label>${esc(lbl)}<input name="${key}" value="${esc(s[key])}" ${type === 'text' ? '' : `type="number" min="0" step="${step}" required`}></label>`
    ).join('')}
  </fieldset>`).join('');
  return `<form method="post" action="/admin/settings" class="settings">${groups}<button class="primary">Save settings</button></form>`;
}

router.get('/admin/settings', requireRole('admin'), wrap(async (req, res) => {
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  res.send(page({ title: 'Rates & settings', user: req.user, notice: req.query.saved ? 'Settings saved.' : null, body: form(s) }));
}));

router.post('/admin/settings', requireRole('admin'), wrap(async (req, res) => {
  const values = [];
  for (const [key, lbl, type] of FIELDS) {
    const raw = req.body[key];
    if (type === 'bool') values.push(raw === 'on');
    else if (type === 'text') values.push(String(raw || '').trim());
    else {
      const n = Number(raw);
      if (raw === '' || raw === undefined || !Number.isFinite(n) || n < 0 || (type === 'int' && !Number.isInteger(n))) {
        const s = { ...(await query('SELECT * FROM settings WHERE id = 1')).rows[0], ...req.body };
        return res.status(400).send(page({ title: 'Rates & settings', user: req.user, error: `Check “${lbl}”: it needs to be a number of 0 or more.`, body: form(s) }));
      }
      values.push(n);
    }
  }
  const pc = FIELDS.findIndex(([k]) => k === 'base_postcode');
  values[pc] = values[pc].toUpperCase();
  const sets = FIELDS.map(([key], i) => `${key} = $${i + 1}`).join(', ');
  await query(`UPDATE settings SET ${sets}, updated_at = now() WHERE id = 1`, values);
  res.redirect('/admin/settings?saved=1');
}));

module.exports = router;
HANDYTRIO_EOF

cat > src/routes/users.js <<'HANDYTRIO_EOF'
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
HANDYTRIO_EOF

cat > public/style.css <<'HANDYTRIO_EOF'
:root {
  --bg: #e9ecea;          /* site concrete */
  --surface: #ffffff;
  --ink: #1d2529;
  --muted: #5d6a70;
  --line: #c9d0cd;
  --slate: #24414f;       /* van livery */
  --hivis: #f2c300;       /* hi-vis yellow */
  --hivis-ink: #1d2529;
  --ok-bg: #e2f1e4; --ok-ink: #1f5a2a;
  --bad-bg: #fbe4e1; --bad-ink: #8a2418;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14191c; --surface: #1d2428; --ink: #e5eaec; --muted: #9aa8ae; --line: #33403f;
    --slate: #10232c; --ok-bg: #1d3a24; --ok-ink: #b6e3bf; --bad-bg: #4a1f1a; --bad-ink: #ffc9c1;
    color-scheme: dark;
  }
}

* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.5 Barlow, "Segoe UI", system-ui, sans-serif; }
a { color: inherit; text-underline-offset: 3px; }
:focus-visible { outline: 3px solid var(--hivis); outline-offset: 2px; }

.top { background: var(--slate); color: #fff; display: flex; flex-wrap: wrap; gap: .5rem 1.5rem; align-items: center; justify-content: space-between; padding: .75rem 1.25rem; }
.brand { font: 700 1.6rem/1 "Barlow Condensed", Barlow, sans-serif; text-decoration: none; letter-spacing: .01em; }
.top nav { display: flex; flex-wrap: wrap; gap: 1rem; align-items: center; }
.top nav a { text-decoration: none; opacity: .9; }
.top nav a:hover { opacity: 1; text-decoration: underline; }
.stripe { height: 8px; background: repeating-linear-gradient(-45deg, var(--hivis) 0 14px, var(--slate) 14px 28px); }

main { max-width: 1100px; margin: 0 auto; padding: 1.25rem; }
h1 { font: 700 2.2rem/1.1 "Barlow Condensed", Barlow, sans-serif; margin: .25rem 0 1rem; }
h2 { font: 600 1.4rem/1.2 "Barlow Condensed", Barlow, sans-serif; margin: 1.75rem 0 .75rem; }
.who { color: var(--muted); margin: 0; font-size: .9rem; }
.muted, .empty { color: var(--muted); }

.panel { background: var(--surface); border: 1px solid var(--line); border-radius: 6px; padding: 1rem 1.25rem; margin: 0 0 1rem; }
.narrow { max-width: 480px; }
.callout { border-left: 6px solid var(--hivis); }
.callout h2 { margin-top: 0; }

label { display: block; font-weight: 500; margin: 0 0 .85rem; }
input, select { display: block; width: 100%; margin-top: .3rem; padding: .6rem .7rem; font: inherit; color: var(--ink); background: var(--bg); border: 1px solid var(--line); border-radius: 4px; }
label.check { display: flex; gap: .6rem; align-items: center; }
label.check input { width: auto; margin: 0; }
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 0 1rem; }

button { font: inherit; cursor: pointer; }
button.primary { background: var(--hivis); color: var(--hivis-ink); border: 0; border-radius: 4px; padding: .7rem 1.4rem; font-weight: 600; }
button.primary:hover { filter: brightness(.95); }
button.small { background: transparent; color: var(--ink); border: 1px solid var(--line); border-radius: 4px; padding: .25rem .6rem; font-size: .85rem; }
button.linkish { background: none; border: 0; color: inherit; padding: 0; opacity: .9; }
button.linkish:hover { text-decoration: underline; opacity: 1; }
form.inline { display: inline; }

.notice, .error { padding: .7rem 1rem; border-radius: 4px; margin: 0 0 1rem; }
.notice { background: var(--ok-bg); color: var(--ok-ink); }
.error { background: var(--bad-bg); color: var(--bad-ink); }

.settings { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1rem; align-items: start; }
.settings .panel { margin: 0; }
.settings legend { font: 600 1.2rem "Barlow Condensed", Barlow, sans-serif; padding: 0 .3rem; }
.settings > button { justify-self: start; }

.scroll { overflow-x: auto; background: var(--surface); border: 1px solid var(--line); border-radius: 6px; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: .6rem .8rem; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { font-weight: 600; color: var(--muted); font-size: .9rem; }
tr:last-child td { border-bottom: 0; }
tr.off td { color: var(--muted); }

.tag { display: inline-block; padding: .1rem .5rem; border-radius: 3px; font-size: .85rem; background: var(--bg); border: 1px solid var(--line); }
.tag.urgent { background: var(--hivis); color: var(--hivis-ink); border-color: transparent; }

.pipeline { list-style: none; padding: 0; margin: 0; display: flex; overflow-x: auto; gap: 2px; }
.pipeline li { flex: 1 0 110px; background: var(--surface); padding: .7rem .6rem; display: flex; flex-direction: column; gap: .2rem; font-size: .85rem; color: var(--muted); border-top: 4px solid var(--line); }
.pipeline li.has { color: var(--ink); border-top-color: var(--hivis); }
.pipeline .n { font: 700 1.8rem/1 "Barlow Condensed", Barlow, sans-serif; }

@media (max-width: 560px) {
  .row { grid-template-columns: 1fr; }
  h1 { font-size: 1.9rem; }
}
HANDYTRIO_EOF

chmod +x save.sh scripts/db.sh

if [ ! -f .env ]; then
  SECRET=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
  printf "DATABASE_URL=postgres://handy:handy@localhost:5433/handytrio\nSESSION_SECRET=%s\nPORT=3000\n" "$SECRET" > .env
  echo "Created .env"
fi

echo "Installing packages..."
npm install express@4 express-session@1 connect-pg-simple@9 pg@8 bcryptjs@2 dotenv@16 helmet@7 express-rate-limit@7

echo ""
echo "Done. Next:"
echo "  1) npm run dev"
echo "  2) In a second terminal: npm run create-admin -- you@example.com \"Your Name\" \"your-password\""
echo "  3) Open port 3000 and log in"
