#!/usr/bin/env bash
# TheHandyTrio stage 3: price list, job templates and automatic estimates. Run with: bash stage3.sh
set -e
if [ ! -f package.json ]; then echo "Run this inside the TheHandyTrio folder"; exit 1; fi
mkdir -p src/routes scripts db public

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

-- Stage 2: job requests and photos
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS work_type text;

CREATE TABLE IF NOT EXISTS job_photos (
  id            serial PRIMARY KEY,
  job_id        int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  stored_name   text NOT NULL UNIQUE,
  original_name text,
  mime_type     text NOT NULL,
  size_bytes    int NOT NULL,
  uploaded_by   int REFERENCES users(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS job_photos_job_idx ON job_photos (job_id);

-- Stage 3: price list, job templates and estimates
CREATE TABLE IF NOT EXISTS suppliers (
  id         serial PRIMARY KEY,
  name       text NOT NULL UNIQUE,
  phone      text,
  email      text,
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS price_items (
  id           serial PRIMARY KEY,
  supplier_id  int REFERENCES suppliers(id) ON DELETE SET NULL,
  code         text,
  name         text NOT NULL,
  unit         text NOT NULL DEFAULT 'each',
  price        numeric NOT NULL CHECK (price >= 0),
  cut_material boolean NOT NULL DEFAULT false,
  active       boolean NOT NULL DEFAULT true,
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS price_items_supplier_idx ON price_items (supplier_id);

CREATE TABLE IF NOT EXISTS job_templates (
  id                 serial PRIMARY KEY,
  name               text NOT NULL,
  work_type          text,
  description        text,
  pricing_method     text NOT NULL DEFAULT 'hourly' CHECK (pricing_method IN ('hourly','day','fixed')),
  labour_setup       numeric NOT NULL DEFAULT 0,
  labour_per_unit    numeric NOT NULL DEFAULT 0,
  crew               int,
  quantity_question  text,
  quantity_unit      text,
  max_quantity       numeric NOT NULL DEFAULT 50,
  range_low_pct      numeric,
  range_high_pct     numeric,
  materials_included boolean NOT NULL DEFAULT false,
  active             boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS template_materials (
  id            serial PRIMARY KEY,
  template_id   int NOT NULL REFERENCES job_templates(id) ON DELETE CASCADE,
  price_item_id int NOT NULL REFERENCES price_items(id),
  qty_per_unit  numeric NOT NULL DEFAULT 1 CHECK (qty_per_unit >= 0)
);
CREATE INDEX IF NOT EXISTS template_materials_template_idx ON template_materials (template_id);

CREATE TABLE IF NOT EXISTS access_options (
  id         serial PRIMARY KEY,
  label      text NOT NULL,
  multiplier numeric NOT NULL DEFAULT 1 CHECK (multiplier > 0),
  active     boolean NOT NULL DEFAULT true
);
INSERT INTO access_options (label, multiplier)
SELECT * FROM (VALUES
  ('Stairs up to the work area', 1.1),
  ('No parking close by', 1.1),
  ('Tight or awkward space', 1.2),
  ('Work at height (ladders or above)', 1.2)
) AS v(label, multiplier)
WHERE NOT EXISTS (SELECT 1 FROM access_options);

CREATE TABLE IF NOT EXISTS postcode_locations (
  postcode   text PRIMARY KEY,
  lat        double precision NOT NULL,
  lng        double precision NOT NULL,
  fetched_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE jobs ADD COLUMN IF NOT EXISTS template_id int REFERENCES job_templates(id);
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS quantity numeric;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS access_option_ids int[] NOT NULL DEFAULT '{}';
HANDYTRIO_EOF

cat > src/estimate.js <<'HANDYTRIO_EOF'
// Works out a job estimate from a template, the price list and the rates in settings.
const { query } = require('./db');
const { esc } = require('./layout');

const ROAD_FACTOR = 1.3; // straight-line miles to rough road miles
const AVG_MPH = 30;      // average driving speed for travel time

const N = (x) => Number(x) || 0;
const pct = (x) => N(x) / 100;
const r2 = (n) => Math.round(n * 100) / 100;
const money = (n, cur = '£') =>
  cur + N(n).toLocaleString('en-GB', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const normPostcode = (pc) => String(pc || '').toUpperCase().replace(/\s+/g, '');

// Finds a UK postcode's location using postcodes.io (free, no key), cached in the database.
async function locate(postcode) {
  const key = normPostcode(postcode);
  if (!/^[A-Z]{1,2}\d[A-Z\d]?\d[A-Z]{2}$/.test(key)) return null;
  const cached = await query('SELECT lat, lng FROM postcode_locations WHERE postcode = $1', [key]);
  if (cached.rows[0]) return { lat: N(cached.rows[0].lat), lng: N(cached.rows[0].lng) };
  try {
    const res = await fetch('https://api.postcodes.io/postcodes/' + encodeURIComponent(key), { signal: AbortSignal.timeout(5000) });
    if (!res.ok) return null;
    const data = await res.json();
    const lat = data && data.result && data.result.latitude;
    const lng = data && data.result && data.result.longitude;
    if (typeof lat !== 'number' || typeof lng !== 'number') return null;
    await query(
      `INSERT INTO postcode_locations (postcode, lat, lng) VALUES ($1, $2, $3)
       ON CONFLICT (postcode) DO UPDATE SET lat = EXCLUDED.lat, lng = EXCLUDED.lng, fetched_at = now()`,
      [key, lat, lng]
    );
    return { lat, lng };
  } catch (e) {
    return null;
  }
}

function milesBetween(a, b) {
  const R = 3958.8;
  const rad = (x) => (x * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

async function calculateEstimate({ templateId, quantity, accessIds = [], postcode, urgent = false, skipTravel = false }) {
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const t = (await query('SELECT * FROM job_templates WHERE id = $1', [templateId])).rows[0];
  if (!t) return null;
  const warnings = [];

  const mats = (await query(
    `SELECT tm.qty_per_unit, p.name, p.unit, p.price, p.cut_material, p.active, sp.name AS supplier
     FROM template_materials tm JOIN price_items p ON p.id = tm.price_item_id
     LEFT JOIN suppliers sp ON sp.id = p.supplier_id
     WHERE tm.template_id = $1 ORDER BY tm.id`, [t.id])).rows;
  const ids = (accessIds || []).map(Number).filter(Number.isInteger);
  const access = ids.length
    ? (await query('SELECT id, label, multiplier FROM access_options WHERE id = ANY($1::int[]) AND active ORDER BY id', [ids])).rows
    : [];

  const qty = t.quantity_question ? Math.max(N(quantity), 0) : 1;

  // Materials
  const lines = mats.map((m) => {
    const base = N(m.qty_per_unit) * qty;
    const q = m.cut_material ? base * (1 + pct(s.waste_pct)) : base;
    if (!m.active) warnings.push(`${m.name} is switched off in the price list but is still in this template.`);
    return { name: m.name, supplier: m.supplier, unit: m.unit, qty: r2(q), price: N(m.price), cost: r2(q * N(m.price)), cut: m.cut_material };
  });
  const materialsCost = r2(lines.reduce((a, l) => a + l.cost, 0));
  const markup = t.materials_included ? 0 : r2(materialsCost * pct(s.markup_pct));
  const materialsCharge = t.materials_included ? 0 : r2(materialsCost + markup);

  // Labour
  const crew = t.crew ? N(t.crew) : N(s.default_crew) || 1;
  const units = N(t.labour_setup) + N(t.labour_per_unit) * qty;
  const accessFactor = access.reduce((f, a) => f * N(a.multiplier), 1);
  let labourBase;
  let labourText;
  let visits;
  if (t.pricing_method === 'day') {
    const days = Math.max(0.5, Math.ceil(units * accessFactor * 2) / 2);
    labourBase = days * crew * N(s.day_rate);
    labourText = `${days} day${days === 1 ? '' : 's'} × ${crew} ${crew === 1 ? 'person' : 'people'} × ${money(s.day_rate, s.currency)}`;
    visits = Math.ceil(days);
  } else if (t.pricing_method === 'fixed') {
    labourBase = units * accessFactor;
    labourText = 'Fixed price' + (accessFactor !== 1 ? ` × access ${r2(accessFactor)}` : '');
    visits = 1;
  } else {
    const hours = r2(units * accessFactor);
    labourBase = hours * crew * N(s.hourly_rate);
    labourText = `${hours} hr${hours === 1 ? '' : 's'} × ${crew} ${crew === 1 ? 'person' : 'people'} × ${money(s.hourly_rate, s.currency)}`;
    visits = Math.max(1, Math.ceil(hours / (N(s.hours_per_day) || 8)));
  }
  labourBase = r2(labourBase);
  const urgentPremium = urgent ? r2(labourBase * pct(s.urgent_premium_pct)) : 0;
  const labour = r2(labourBase + urgentPremium);

  // Travel
  const travel = { oneWayMiles: null, visits, mileage: 0, time: 0, total: 0 };
  if (!skipTravel) {
    if (!s.base_postcode) {
      warnings.push('No base postcode is set, so travel isn’t included.');
    } else {
      const from = await locate(s.base_postcode);
      const to = await locate(postcode);
      if (!from || !to) {
        warnings.push('The distance to this postcode couldn’t be found, so travel isn’t included.');
      } else {
        const oneWay = milesBetween(from, to) * ROAD_FACTOR;
        const roundTrips = oneWay * 2 * visits;
        travel.oneWayMiles = r2(oneWay);
        travel.mileage = r2(roundTrips * N(s.mileage_rate));
        travel.time = s.charge_travel_time ? r2((roundTrips / AVG_MPH) * N(s.travel_hourly_rate)) : 0;
        travel.total = r2(travel.mileage + travel.time);
        if (oneWay > N(s.service_radius_miles)) {
          warnings.push(`About ${Math.round(oneWay)} miles away, outside the ${N(s.service_radius_miles)}-mile service area.`);
        }
      }
    }
  }

  // Totals
  const subtotal = r2(materialsCharge + labour + travel.total);
  const contingency = r2(subtotal * pct(s.contingency_pct));
  let net = r2(subtotal + contingency);
  let minimumApplied = false;
  if (net < N(s.minimum_charge)) {
    net = N(s.minimum_charge);
    minimumApplied = true;
  }
  const vat = s.vat_registered ? r2(net * pct(s.vat_rate)) : 0;
  const total = r2(net + vat);
  const lowPct = t.range_low_pct !== null ? N(t.range_low_pct) : N(s.range_low_pct);
  const highPct = t.range_high_pct !== null ? N(t.range_high_pct) : N(s.range_high_pct);
  const low = Math.max(0, Math.floor((total * (1 - lowPct / 100)) / 5) * 5);
  const high = Math.ceil((total * (1 + highPct / 100)) / 5) * 5;

  return {
    template: { id: t.id, name: t.name, pricing_method: t.pricing_method },
    quantity: qty,
    quantity_unit: t.quantity_unit,
    access: access.map((a) => ({ label: a.label, multiplier: N(a.multiplier) })),
    urgent,
    crew,
    materials: { lines, cost: materialsCost, markup, markupPct: N(s.markup_pct), included: t.materials_included, charge: materialsCharge },
    labour: { text: labourText, accessFactor: r2(accessFactor), base: labourBase, urgentPremium, total: labour },
    travel,
    subtotal,
    contingency,
    contingencyPct: N(s.contingency_pct),
    minimumApplied,
    minimumCharge: N(s.minimum_charge),
    net,
    vat,
    vatRate: s.vat_registered ? N(s.vat_rate) : 0,
    total,
    low,
    high,
    currency: s.currency,
    warnings,
    generated_at: new Date().toISOString(),
  };
}

function customerSummary(e) {
  return `${money(e.low, e.currency)} to ${money(e.high, e.currency)}${e.vat ? ' including VAT' : ''}`;
}

// Full working, for the office and builders.
function renderBreakdown(e) {
  const m = (n) => money(n, e.currency);
  const matRows = e.materials.lines.map((l) =>
    `<tr><td>${esc(l.name)}${l.supplier ? ` <span class="muted">(${esc(l.supplier)})</span>` : ''}</td><td>${l.qty} ${esc(l.unit)}${l.cut ? ' incl. waste' : ''}</td><td class="num">${m(l.cost)}</td></tr>`
  ).join('');
  const row = (label, value, cls = '') => `<tr class="${cls}"><td colspan="2">${label}</td><td class="num">${value}</td></tr>`;
  return `<div class="scroll"><table class="breakdown">
    <tbody>
      <tr class="group"><th colspan="3">Materials${e.materials.included ? ' (included in fixed price)' : ''}</th></tr>
      ${matRows || '<tr><td colspan="3" class="muted">No materials in this template</td></tr>'}
      ${e.materials.included ? '' : row(`Markup ${e.materials.markupPct}%`, m(e.materials.markup))}
      ${row('Materials total', m(e.materials.charge), 'sum')}
      <tr class="group"><th colspan="3">Labour</th></tr>
      ${row(esc(e.labour.text), m(e.labour.base))}
      ${e.access.length ? row(`Access: ${esc(e.access.map((a) => `${a.label} ×${a.multiplier}`).join(', '))}`, 'included above') : ''}
      ${e.labour.urgentPremium ? row('Urgent premium', m(e.labour.urgentPremium)) : ''}
      ${row('Labour total', m(e.labour.total), 'sum')}
      <tr class="group"><th colspan="3">Travel</th></tr>
      ${e.travel.oneWayMiles === null
        ? row('<span class="muted">Not included</span>', m(0))
        : `${row(`${e.travel.oneWayMiles} miles each way × ${e.travel.visits} visit${e.travel.visits === 1 ? '' : 's'}, mileage`, m(e.travel.mileage))}
           ${e.travel.time ? row('Travel time', m(e.travel.time)) : ''}`}
      ${row('Travel total', m(e.travel.total), 'sum')}
      <tr class="group"><th colspan="3">Totals</th></tr>
      ${row('Subtotal', m(e.subtotal))}
      ${row(`Contingency ${e.contingencyPct}%`, m(e.contingency))}
      ${e.minimumApplied ? row(`Raised to minimum charge`, m(e.minimumCharge)) : ''}
      ${row('Net', m(e.net), 'sum')}
      ${e.vat ? row(`VAT ${e.vatRate}%`, m(e.vat)) : ''}
      ${row('Estimate', m(e.total), 'grand')}
      ${row('Range shown to customer', `${m(e.low)} to ${m(e.high)}`)}
    </tbody></table></div>
    ${e.warnings.length ? `<ul class="warnings">${e.warnings.map((w) => `<li>${esc(w)}</li>`).join('')}</ul>` : ''}`;
}

module.exports = { calculateEstimate, customerSummary, renderBreakdown, money, locate };
HANDYTRIO_EOF

cat > src/layout.js <<'HANDYTRIO_EOF'
const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin' };

function nav(user) {
  if (!user) return '<a href="/login">Log in</a><a href="/register">Create account</a>';
  const links = ['<a href="/dashboard">Dashboard</a>'];
  if (user.role === 'admin') {
    links.push('<a href="/admin/templates">Pricing</a>', '<a href="/admin/users">People</a>', '<a href="/admin/settings">Rates &amp; settings</a>');
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
app.use(require('./routes/jobs'));
app.use(require('./routes/pricing'));

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

cat > src/routes/jobs.js <<'HANDYTRIO_EOF'
const express = require('express');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const multer = require('multer');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { STATUSES, label } = require('../statuses');
const { ref, day, when, WORK_TYPES } = require('../format');
const { calculateEstimate, customerSummary, renderBreakdown } = require('../estimate');

const router = express.Router();

// ---------- Photo uploads ----------
const UPLOAD_DIR = path.join(__dirname, '..', '..', 'uploads');
fs.mkdirSync(UPLOAD_DIR, { recursive: true });
const MAX_PHOTOS = 8;
const MAX_MB = 15;

const upload = multer({
  storage: multer.diskStorage({
    destination: UPLOAD_DIR,
    filename: (req, file, cb) => {
      const ext = path.extname(file.originalname || '').toLowerCase().replace(/[^.a-z0-9]/g, '').slice(0, 6);
      cb(null, crypto.randomUUID() + ext);
    },
  }),
  limits: { fileSize: MAX_MB * 1024 * 1024, files: MAX_PHOTOS, fields: 30 },
  fileFilter: (req, file, cb) => cb(null, /^image\//.test(file.mimetype)),
});

// Runs multer but turns its errors into a friendly message instead of a crash.
function photoUpload(req, res, next) {
  upload.array('photos', MAX_PHOTOS)(req, res, (err) => {
    if (err) {
      req.uploadError =
        err.code === 'LIMIT_FILE_SIZE' ? `Each photo must be under ${MAX_MB} MB.`
        : err.code === 'LIMIT_FILE_COUNT' || err.code === 'LIMIT_UNEXPECTED_FILE' ? `You can add up to ${MAX_PHOTOS} photos.`
        : 'The photos couldn’t be uploaded. Try again.';
    }
    req.files = req.files || [];
    next();
  });
}

const removeFiles = (files) => (files || []).forEach((f) => fs.unlink(f.path, () => {}));

async function savePhotos(client, jobId, files, userId) {
  for (const f of files) {
    await client.query(
      'INSERT INTO job_photos (job_id, stored_name, original_name, mime_type, size_bytes, uploaded_by) VALUES ($1, $2, $3, $4, $5, $6)',
      [jobId, f.filename, f.originalname, f.mimetype, f.size, userId]
    );
  }
}

// ---------- Access ----------
const JOB_SELECT = `SELECT j.*, c.name AS customer_name, c.phone AS customer_phone, c.email AS customer_email,
    b.name AS builder_name
  FROM jobs j JOIN users c ON c.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id`;

function canSee(user, job) {
  return user.role === 'admin'
    || (user.role === 'customer' && job.customer_id === user.id)
    || (user.role === 'builder' && job.assigned_builder_id === user.id);
}

async function loadJob(req) {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id < 1) return null;
  const { rows } = await query(`${JOB_SELECT} WHERE j.id = $1`, [id]);
  const job = rows[0];
  return job && canSee(req.user, job) ? job : null;
}

const notFound = (req, res) =>
  res.status(404).send(page({ title: 'Job not found', user: req.user, body: '<p>That job doesn’t exist or isn’t yours to view.</p><p><a href="/dashboard">Back to your dashboard</a></p>' }));

async function setStatus(client, jobId, from, to, userId, note) {
  await client.query('UPDATE jobs SET status = $1, updated_at = now() WHERE id = $2', [to, jobId]);
  await client.query(
    'INSERT INTO job_status_history (job_id, from_status, to_status, changed_by, note) VALUES ($1, $2, $3, $4, $5)',
    [jobId, from, to, userId, note || null]
  );
}

// ---------- New job request (customers) ----------
const todayISO = () => new Date().toISOString().slice(0, 10);
const asArray = (v) => (v === undefined ? [] : Array.isArray(v) ? v : [v]);

async function activeTemplate(id) {
  const n = Number(id);
  if (!Number.isInteger(n) || n < 1) return null;
  return (await query('SELECT * FROM job_templates WHERE id = $1 AND active', [n])).rows[0] || null;
}

function chooser(templates) {
  const groups = {};
  for (const t of templates) (groups[t.work_type || 'Other jobs'] ||= []).push(t);
  return `<p class="lead">Pick the job that fits best. You’ll get a price guide straight away.</p>
  ${Object.entries(groups).map(([g, ts]) => `<h2>${esc(g)}</h2>
    <div class="choices">${ts.map((t) => `<a class="choice" href="/jobs/new?t=${t.id}"><strong>${esc(t.name)}</strong>${t.description ? `<span>${esc(t.description)}</span>` : ''}</a>`).join('')}</div>`).join('')}
  <h2>Not listed?</h2>
  <div class="choices"><a class="choice" href="/jobs/new?t=other"><strong>Something else</strong><span>Describe the job and we’ll arrange a visit to price it.</span></a></div>`;
}

function requestForm(v, s, t, accessOptions) {
  const opt = (w) => `<option ${v.work_type === w ? 'selected' : ''}>${esc(w)}</option>`;
  const chosen = asArray(v.access).map(String);
  return `<form method="post" action="/jobs" enctype="multipart/form-data" class="request">
  <input type="hidden" name="template_id" value="${t ? t.id : 'other'}">
  <fieldset class="panel">
    <legend>The job</legend>
    ${t ? `<p class="picked"><strong>${esc(t.name)}</strong> <a href="/jobs/new">Change</a></p>` : ''}
    <label>${t ? 'Job title (change it if you like)' : 'What do you need doing?'}<input name="title" value="${esc(v.title)}" maxlength="120" required placeholder="For example: replace a rotten fence post"></label>
    ${t ? '' : `<label>Type of work<select name="work_type" required>${WORK_TYPES.map(opt).join('')}</select></label>`}
    ${t && t.quantity_question ? `<label>${esc(t.quantity_question)}<input name="quantity" type="number" min="0.5" step="0.5" max="${esc(t.max_quantity)}" value="${esc(v.quantity || '')}" required></label>` : ''}
    <label>Describe the job<textarea name="description" rows="5" maxlength="4000" placeholder="Sizes, materials, what’s wrong, anything you’ve already bought">${esc(v.description)}</textarea></label>
    <label>Photos (up to ${MAX_PHOTOS})<input type="file" name="photos" accept="image/*" multiple></label>
    <p class="hint">Photos of the area and any damage help us price it accurately.</p>
  </fieldset>
  <fieldset class="panel">
    <legend>Where</legend>
    <label>Address<input name="address_line" value="${esc(v.address_line)}" required autocomplete="street-address"></label>
    <div class="row">
      <label>Town<input name="town" value="${esc(v.town)}" autocomplete="address-level2"></label>
      <label>Postcode<input name="postcode" value="${esc(v.postcode)}" required autocomplete="postal-code"></label>
    </div>
    ${t && accessOptions.length ? `<p class="fieldlabel">Anything that makes access harder?</p>
      ${accessOptions.map((a) => `<label class="check"><input type="checkbox" name="access" value="${a.id}" ${chosen.includes(String(a.id)) ? 'checked' : ''}> ${esc(a.label)}</label>`).join('')}` : ''}
    <label>Access information<textarea name="access_info" rows="3" maxlength="2000" placeholder="Parking, key safe or who lets us in, pets">${esc(v.access_info)}</textarea></label>
  </fieldset>
  <fieldset class="panel">
    <legend>When</legend>
    <div class="row">
      <label>Earliest start<input type="date" name="preferred_start" value="${esc(v.preferred_start)}" min="${todayISO()}" required></label>
      <label>Finished by (optional)<input type="date" name="preferred_end" value="${esc(v.preferred_end)}" min="${todayISO()}"></label>
    </div>
    <p class="hint">Jobs needed within ${esc(s.urgent_within_hours)} hours are treated as urgent and cost more.</p>
  </fieldset>
  <button class="primary">${t ? 'Send and see my price guide' : 'Send job request'}</button>
</form>`;
}

router.get('/jobs/new', requireRole('customer'), wrap(async (req, res) => {
  const pick = req.query.t;
  if (!pick) {
    const templates = (await query('SELECT id, name, description, work_type FROM job_templates WHERE active ORDER BY work_type, name')).rows;
    if (!templates.length) return res.redirect('/jobs/new?t=other');
    return res.send(page({ title: 'Request a job', user: req.user, body: chooser(templates) }));
  }
  const t = pick === 'other' ? null : await activeTemplate(pick);
  if (pick !== 'other' && !t) return res.redirect('/jobs/new');
  const me = (await query('SELECT address_line, town, postcode FROM users WHERE id = $1', [req.user.id])).rows[0];
  const s = (await query('SELECT urgent_within_hours FROM settings WHERE id = 1')).rows[0];
  const access = t ? (await query('SELECT id, label FROM access_options WHERE active ORDER BY id')).rows : [];
  const v = { ...me, title: t ? t.name : '', work_type: 'Something else' };
  res.send(page({ title: 'Request a job', user: req.user, body: requestForm(v, s, t, access) }));
}));

router.post('/jobs', requireRole('customer'), photoUpload, wrap(async (req, res) => {
  const v = {};
  for (const k of ['title', 'work_type', 'description', 'address_line', 'town', 'postcode', 'access_info', 'preferred_start', 'preferred_end', 'quantity']) {
    v[k] = String(req.body[k] || '').trim();
  }
  v.postcode = v.postcode.toUpperCase();
  v.access = asArray(req.body.access);
  const s = (await query('SELECT urgent_within_hours FROM settings WHERE id = 1')).rows[0];
  const isDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d) && !Number.isNaN(Date.parse(d));

  const isOther = req.body.template_id === 'other';
  const t = isOther ? null : await activeTemplate(req.body.template_id);
  if (!isOther && !t) { removeFiles(req.files); return res.redirect('/jobs/new'); }
  if (t) v.work_type = t.work_type || 'Something else';
  const accessOptions = t ? (await query('SELECT id, label FROM access_options WHERE active ORDER BY id')).rows : [];
  const accessIds = v.access.map(Number).filter((id) => accessOptions.some((a) => a.id === id));
  const qty = t && t.quantity_question ? Number(v.quantity) : 1;

  let error = req.uploadError || null;
  if (!error) {
    if (!v.title) error = 'Give the job a title.';
    else if (!WORK_TYPES.includes(v.work_type)) error = 'Choose the type of work.';
    else if (t && t.quantity_question && (!(qty > 0) || qty > Number(t.max_quantity))) error = `Answer “${t.quantity_question}” with a number from 0.5 to ${Number(t.max_quantity)}. For bigger jobs, choose Something else.`;
    else if (!v.address_line || !v.postcode) error = 'Enter the address and postcode for the job.';
    else if (!isDate(v.preferred_start) || v.preferred_start < todayISO()) error = 'Choose an earliest start date from today onwards.';
    else if (v.preferred_end && (!isDate(v.preferred_end) || v.preferred_end < v.preferred_start)) error = 'The finish date must be on or after the start date.';
  }
  if (error) {
    removeFiles(req.files);
    return res.status(400).send(page({ title: 'Request a job', user: req.user, error, body: requestForm(v, s, t, accessOptions) }));
  }

  const hoursAhead = (Date.parse(v.preferred_start) - Date.parse(todayISO())) / 3600000;
  const urgent = hoursAhead < Number(s.urgent_within_hours);

  let estimate = null;
  if (t) {
    try {
      estimate = await calculateEstimate({ templateId: t.id, quantity: qty, accessIds, postcode: v.postcode, urgent });
    } catch (e) {
      console.error('Estimate failed:', e);
    }
  }
  const status = isOther ? 'inspection_required' : 'request';

  const client = await pool.connect();
  let jobId;
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `INSERT INTO jobs (customer_id, title, work_type, description, address_line, town, postcode, access_info,
         preferred_start, preferred_end, urgent, status, template_id, quantity, access_option_ids)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15) RETURNING id`,
      [req.user.id, v.title, v.work_type, v.description || null, v.address_line, v.town || null, v.postcode,
        v.access_info || null, v.preferred_start, v.preferred_end || null, urgent, status,
        t ? t.id : null, t ? qty : null, accessIds]
    );
    jobId = rows[0].id;
    await client.query(
      'INSERT INTO job_status_history (job_id, from_status, to_status, changed_by, note) VALUES ($1, NULL, $2, $3, $4)',
      [jobId, status, req.user.id, 'Request sent by customer']
    );
    if (estimate) {
      await client.query('UPDATE jobs SET estimate_low = $1, estimate_high = $2, estimate_snapshot = $3 WHERE id = $4',
        [estimate.low, estimate.high, JSON.stringify(estimate), jobId]);
      await setStatus(client, jobId, status, 'estimated', null, 'Price guide worked out automatically');
    }
    await savePhotos(client, jobId, req.files, req.user.id);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    removeFiles(req.files);
    throw e;
  } finally {
    client.release();
  }
  res.redirect(`/jobs/${jobId}?sent=1`);
}));

// ---------- Job page ----------
router.get('/jobs/:id', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const user = req.user;

  const photos = (await query('SELECT id, original_name FROM job_photos WHERE job_id = $1 ORDER BY id', [job.id])).rows;
  const history = (await query(
    `SELECT h.*, u.name AS by_name FROM job_status_history h LEFT JOIN users u ON u.id = h.changed_by
     WHERE h.job_id = $1 ORDER BY h.created_at DESC, h.id DESC`, [job.id])).rows;

  const address = [job.address_line, job.town, job.postcode].filter(Boolean).join(', ');
  const mapsUrl = 'https://www.google.com/maps/dir/?api=1&destination=' + encodeURIComponent(address);

  const photoGrid = photos.length
    ? `<div class="photos">${photos.map((p) => `<a href="/jobs/${job.id}/photos/${p.id}" target="_blank" rel="noopener"><img src="/jobs/${job.id}/photos/${p.id}" alt="${esc(p.original_name || 'Job photo')}" loading="lazy"></a>`).join('')}</div>`
    : '<p class="empty">No photos yet.</p>';

  const addPhotos = photos.length < MAX_PHOTOS && !['paid', 'cancelled', 'declined'].includes(job.status)
    ? `<form method="post" action="/jobs/${job.id}/photos" enctype="multipart/form-data" class="inline-form">
        <input type="file" name="photos" accept="image/*" multiple required>
        <button class="small">Add photos</button>
      </form>` : '';

  let actions = '';
  if (user.role === 'customer' && ['request', 'inspection_required', 'estimated'].includes(job.status)) {
    actions = `<form method="post" action="/jobs/${job.id}/cancel" class="panel">
      <p>Changed your mind? You can cancel this request until an inspection is booked.</p>
      <button class="small danger">Cancel this request</button></form>`;
  }
  if (user.role === 'admin') {
    const builders = (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows;
    actions = `<div class="admin-actions">
      <form method="post" action="/jobs/${job.id}/assign" class="panel">
        <label>Builder<select name="builder_id">
          <option value="">Not assigned</option>
          ${builders.map((b) => `<option value="${b.id}" ${b.id === job.assigned_builder_id ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}
        </select></label>
        <button class="small">Save builder</button>
      </form>
      <form method="post" action="/jobs/${job.id}/status" class="panel">
        <label>Move to stage<select name="status">
          ${STATUSES.map(([k, l]) => `<option value="${k}" ${k === job.status ? 'selected' : ''}>${esc(l)}</option>`).join('')}
        </select></label>
        <label>Note (optional)<input name="note" maxlength="500"></label>
        <button class="small">Update stage</button>
      </form>
    </div>`;
  }

  const e = job.estimate_snapshot;
  let estimatePanel = '';
  if (e) {
    estimatePanel = `<section class="panel callout estimate">
      <h2>Price guide</h2>
      <p class="bigprice">${esc(customerSummary(e))}</p>
      <p>${user.role === 'customer'
        ? 'This is a guide based on what you’ve told us. We’ll confirm the exact price after we’ve seen the job.'
        : `${esc(e.template.name)}${e.quantity_unit ? `, ${e.quantity} ${esc(e.quantity_unit)}` : ''}. Worked out ${when(e.generated_at)}.`}</p>
      ${user.role !== 'customer' ? `<details ${user.role === 'admin' ? 'open' : ''}><summary>How this was worked out</summary>${renderBreakdown(e)}</details>` : ''}
      ${user.role === 'admin' && job.template_id ? `<form method="post" action="/jobs/${job.id}/estimate" class="inline"><button class="small">Recalculate with today’s prices</button></form>` : ''}
    </section>`;
  } else if (job.status === 'inspection_required') {
    estimatePanel = `<section class="panel callout"><h2>Price</h2><p>${user.role === 'customer'
      ? 'This job needs a visit before we can price it. We’ll be in touch to arrange an inspection.'
      : 'Not a standard job, so no automatic estimate. Book an inspection to price it.'}</p></section>`;
  }

  const notice = req.query.sent ? 'Job request sent. We’ll review it and be in touch.'
    : req.query.updated ? 'Job updated.' : req.query.photos ? 'Photos added.' : null;
  const error = req.query.photoerror ? String(req.query.photoerror).slice(0, 120) : null;

  const body = `
  <p class="jobhead"><span class="ref">${ref(job.id)}</span> <span class="tag">${esc(label(job.status))}</span>
    ${job.urgent ? '<span class="tag urgent">Urgent</span>' : ''}</p>
  ${estimatePanel}
  <div class="jobgrid">
    <section class="panel">
      <h2>The job</h2>
      <dl>
        <dt>Type of work</dt><dd>${esc(job.work_type || 'Not given')}</dd>
        <dt>Details</dt><dd class="pre">${esc(job.description || 'No details given')}</dd>
        <dt>Wanted from</dt><dd>${day(job.preferred_start)}${job.preferred_end ? ` to ${day(job.preferred_end)}` : ''}</dd>
        ${user.role !== 'customer' ? `<dt>Builder</dt><dd>${esc(job.builder_name || 'Not assigned')}</dd>` : ''}
      </dl>
    </section>
    <section class="panel">
      <h2>Where</h2>
      <dl>
        <dt>Address</dt><dd>${esc(address)}</dd>
        <dt>Access</dt><dd class="pre">${esc(job.access_info || 'No access notes')}</dd>
        ${user.role !== 'customer' ? `<dt>Customer</dt><dd>${esc(job.customer_name)}<br>${job.customer_phone ? `<a href="tel:${esc(job.customer_phone)}">${esc(job.customer_phone)}</a><br>` : ''}<a href="mailto:${esc(job.customer_email)}">${esc(job.customer_email)}</a></dd>` : ''}
      </dl>
      ${user.role !== 'customer' ? `<p><a class="button" href="${esc(mapsUrl)}" target="_blank" rel="noopener">Directions</a></p>` : ''}
    </section>
  </div>
  <h2>Photos</h2>
  ${photoGrid}
  ${addPhotos}
  ${actions}
  <h2>History</h2>
  <ol class="history">${history.map((h) => `<li><strong>${esc(label(h.to_status))}</strong> <span class="muted">${when(h.created_at)}${h.by_name ? `, ${esc(h.by_name)}` : ''}</span>${h.note ? `<br>${esc(h.note)}` : ''}</li>`).join('')}</ol>
  <p><a href="/dashboard">Back to dashboard</a></p>`;

  res.send(page({ title: job.title, user, notice, error, body }));
}));

// ---------- Photo file ----------
router.get('/jobs/:id/photos/:photoId', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return res.sendStatus(404);
  const { rows } = await query('SELECT stored_name, mime_type FROM job_photos WHERE id = $1 AND job_id = $2', [Number(req.params.photoId) || 0, job.id]);
  if (!rows[0]) return res.sendStatus(404);
  res.set('Cache-Control', 'private, max-age=86400');
  res.type(rows[0].mime_type);
  res.sendFile(path.join(UPLOAD_DIR, path.basename(rows[0].stored_name)), (err) => {
    if (err && !res.headersSent) res.sendStatus(404);
  });
}));

router.post('/jobs/:id/photos', requireLogin, photoUpload, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) { removeFiles(req.files); return notFound(req, res); }
  const count = (await query('SELECT count(*)::int AS n FROM job_photos WHERE job_id = $1', [job.id])).rows[0].n;
  let error = req.uploadError;
  if (!error && !req.files.length) error = 'Choose at least one photo.';
  if (!error && count + req.files.length > MAX_PHOTOS) error = `A job can have up to ${MAX_PHOTOS} photos. It has ${count} already.`;
  if (error) {
    removeFiles(req.files);
    return res.redirect(`/jobs/${job.id}?photoerror=${encodeURIComponent(error)}`);
  }
  const client = await pool.connect();
  try {
    await savePhotos(client, job.id, req.files, req.user.id);
  } catch (e) {
    removeFiles(req.files);
    throw e;
  } finally {
    client.release();
  }
  res.redirect(`/jobs/${job.id}?photos=1`);
}));

// ---------- Customer cancel ----------
router.post('/jobs/:id/cancel', requireRole('customer'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  if (['request', 'inspection_required', 'estimated'].includes(job.status)) {
    const client = await pool.connect();
    try {
      await setStatus(client, job.id, job.status, 'cancelled', req.user.id, 'Cancelled by customer');
    } finally {
      client.release();
    }
  }
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

// ---------- Admin: recalculate estimate ----------
router.post('/jobs/:id/estimate', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  if (!job.template_id) return res.redirect(`/jobs/${job.id}`);
  const est = await calculateEstimate({
    templateId: job.template_id, quantity: job.quantity, accessIds: job.access_option_ids || [],
    postcode: job.postcode, urgent: job.urgent,
  });
  if (!est) return res.redirect(`/jobs/${job.id}`);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE jobs SET estimate_low = $1, estimate_high = $2, estimate_snapshot = $3, updated_at = now() WHERE id = $4',
      [est.low, est.high, JSON.stringify(est), job.id]);
    if (job.status === 'request') await setStatus(client, job.id, 'request', 'estimated', req.user.id, 'Price guide worked out');
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

// ---------- Admin: assign builder and move stage ----------
router.post('/jobs/:id/assign', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const builderId = req.body.builder_id ? Number(req.body.builder_id) : null;
  if (builderId !== null) {
    const ok = (await query("SELECT 1 FROM users WHERE id = $1 AND role = 'builder' AND active", [builderId])).rows.length;
    if (!ok) return res.redirect(`/jobs/${job.id}`);
  }
  await query('UPDATE jobs SET assigned_builder_id = $1, updated_at = now() WHERE id = $2', [builderId, job.id]);
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

router.post('/jobs/:id/status', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const to = String(req.body.status || '');
  if (STATUSES.some(([k]) => k === to) && to !== job.status) {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await setStatus(client, job.id, job.status, to, req.user.id, String(req.body.note || '').trim().slice(0, 500));
      await client.query('COMMIT');
    } catch (e) {
      await client.query('ROLLBACK');
      throw e;
    } finally {
      client.release();
    }
  }
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

module.exports = router;
HANDYTRIO_EOF

cat > src/routes/pricing.js <<'HANDYTRIO_EOF'
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { WORK_TYPES } = require('../format');
const { calculateEstimate, renderBreakdown, money } = require('../estimate');

const router = express.Router();
const admin = requireRole('admin');

const subnav = (active) => `<nav class="subnav">${[
  ['/admin/templates', 'Job templates'],
  ['/admin/price-list', 'Price list'],
  ['/admin/suppliers', 'Suppliers'],
  ['/admin/access-options', 'Access options'],
].map(([h, l]) => `<a href="${h}" ${h === active ? 'aria-current="page"' : ''}>${l}</a>`).join('')}</nav>`;

const txt = (v, max = 200) => String(v ?? '').trim().slice(0, max);
const num = (v) => {
  const s = String(v ?? '').trim().replace(/[£,\s]/g, '');
  if (s === '') return null;
  const n = Number(s);
  return Number.isFinite(n) && n >= 0 ? n : NaN;
};
const idOf = (v) => {
  const n = Number(v);
  return Number.isInteger(n) && n > 0 ? n : null;
};
const METHODS = { hourly: 'Hourly', day: 'Day rate', fixed: 'Fixed price' };
const UNIT_WORD = { hourly: 'hours', day: 'days', fixed: '£' };

// ================= Suppliers =================
router.get('/admin/suppliers', admin, wrap(async (req, res) => {
  const { rows } = await query(
    `SELECT s.*, (SELECT count(*)::int FROM price_items p WHERE p.supplier_id = s.id) AS items
     FROM suppliers s ORDER BY s.active DESC, s.name`);
  const list = rows.length ? `<div class="scroll"><table>
    <thead><tr><th>Supplier</th><th>Phone</th><th>Email</th><th>Items</th><th>Status</th><th></th></tr></thead>
    <tbody>${rows.map((s) => `<tr class="${s.active ? '' : 'off'}">
      <td><a href="/admin/price-list?supplier=${s.id}">${esc(s.name)}</a></td><td>${esc(s.phone)}</td><td>${esc(s.email)}</td>
      <td>${s.items}</td><td>${s.active ? 'Active' : 'Switched off'}</td>
      <td><form method="post" action="/admin/suppliers/${s.id}/toggle" class="inline"><button class="small">${s.active ? 'Switch off' : 'Switch on'}</button></form></td>
    </tr>`).join('')}</tbody></table></div>` : '<p class="empty">No suppliers yet. Add your local merchants below.</p>';
  const body = `${subnav('/admin/suppliers')}${list}
    <h2>Add a supplier</h2>
    <form method="post" action="/admin/suppliers" class="panel narrow">
      <label>Name<input name="name" required maxlength="120"></label>
      <label>Phone<input name="phone" type="tel"></label>
      <label>Email<input name="email" type="email"></label>
      <button class="primary">Add supplier</button>
    </form>`;
  res.send(page({ title: 'Suppliers', user: req.user, notice: req.query.added ? 'Supplier added.' : null, error: req.query.error ? txt(req.query.error) : null, body }));
}));

router.post('/admin/suppliers', admin, wrap(async (req, res) => {
  const name = txt(req.body.name, 120);
  if (!name) return res.redirect('/admin/suppliers?error=' + encodeURIComponent('Enter a supplier name.'));
  try {
    await query('INSERT INTO suppliers (name, phone, email) VALUES ($1, $2, $3)', [name, txt(req.body.phone) || null, txt(req.body.email) || null]);
  } catch (e) {
    if (e.code === '23505') return res.redirect('/admin/suppliers?error=' + encodeURIComponent('That supplier already exists.'));
    throw e;
  }
  res.redirect('/admin/suppliers?added=1');
}));

router.post('/admin/suppliers/:id/toggle', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  if (id) await query('UPDATE suppliers SET active = NOT active WHERE id = $1', [id]);
  res.redirect('/admin/suppliers');
}));

// ================= Price list =================
async function supplierOptions(selected, { includeNone = true } = {}) {
  const { rows } = await query('SELECT id, name FROM suppliers WHERE active ORDER BY name');
  return (includeNone ? '<option value="">No supplier</option>' : '')
    + rows.map((s) => `<option value="${s.id}" ${s.id === selected ? 'selected' : ''}>${esc(s.name)}</option>`).join('');
}

function itemFields(v = {}, supplierOpts) {
  return `<label>Supplier<select name="supplier_id">${supplierOpts}</select></label>
    <div class="row">
      <label>Product code (optional)<input name="code" value="${esc(v.code)}" maxlength="60"></label>
      <label>Unit<input name="unit" value="${esc(v.unit || 'each')}" maxlength="30" placeholder="each, m, m², bag, length"></label>
    </div>
    <label>Item name<input name="name" value="${esc(v.name)}" required maxlength="200"></label>
    <label>Price (before your markup, excluding VAT)<input name="price" type="number" step="0.01" min="0" value="${esc(v.price)}" required></label>
    <label class="check"><input type="checkbox" name="cut_material" ${v.cut_material ? 'checked' : ''}> Cut to size (add the waste allowance)</label>`;
}

router.get('/admin/price-list', admin, wrap(async (req, res) => {
  const supplier = idOf(req.query.supplier);
  const q = txt(req.query.q, 80);
  const params = [];
  const where = [];
  if (supplier) { params.push(supplier); where.push(`p.supplier_id = $${params.length}`); }
  if (q) { params.push('%' + q + '%'); where.push(`(p.name ILIKE $${params.length} OR p.code ILIKE $${params.length})`); }
  const { rows } = await query(
    `SELECT p.*, s.name AS supplier_name FROM price_items p LEFT JOIN suppliers s ON s.id = p.supplier_id
     ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY p.active DESC, s.name NULLS FIRST, p.name LIMIT 500`, params);
  const cur = (await query('SELECT currency FROM settings WHERE id = 1')).rows[0].currency;

  const filter = `<form method="get" action="/admin/price-list" class="filters">
    <label>Supplier<select name="supplier"><option value="">All</option>${(await supplierOptions(supplier, { includeNone: false }))}</select></label>
    <label>Search<input name="q" value="${esc(q)}" placeholder="Name or code"></label>
    <button class="small">Show</button></form>`;
  const list = rows.length ? `<div class="scroll"><table>
    <thead><tr><th>Item</th><th>Code</th><th>Supplier</th><th>Unit</th><th class="num">Price</th><th></th></tr></thead>
    <tbody>${rows.map((p) => `<tr class="${p.active ? '' : 'off'}">
      <td>${esc(p.name)}${p.cut_material ? ' <span class="tag">Cut</span>' : ''}</td><td>${esc(p.code)}</td>
      <td>${esc(p.supplier_name || '')}</td><td>${esc(p.unit)}</td><td class="num">${money(p.price, cur)}</td>
      <td><a href="/admin/price-list/${p.id}">Edit</a></td></tr>`).join('')}</tbody></table></div>`
    : '<p class="empty">No items match. Add one below, or import a list.</p>';

  const body = `${subnav('/admin/price-list')}${filter}${list}
  <div class="twocol">
    <section>
      <h2>Add an item</h2>
      <form method="post" action="/admin/price-list" class="panel">${itemFields({}, await supplierOptions(supplier))}<button class="primary">Add item</button></form>
    </section>
    <section>
      <h2>Import or update prices</h2>
      <form method="post" action="/admin/price-list/import" class="panel">
        <label>Supplier<select name="supplier_id" required>${await supplierOptions(supplier, { includeNone: false })}</select></label>
        <label>Paste rows: code, name, unit, price, cut (yes/no)
          <textarea name="csv" rows="8" required placeholder="D-INT-01, Internal door 762mm, each, 45.00, no&#10;CLS-2.4, CLS timber 2.4m, length, 3.20, yes"></textarea></label>
        <p class="hint">Items with a matching code (or name, if there’s no code) get their price updated. New ones are added. You can paste straight from a spreadsheet saved as CSV.</p>
        <button class="primary">Import</button>
      </form>
    </section>
  </div>`;
  res.send(page({ title: 'Price list', user: req.user, notice: req.query.msg ? txt(req.query.msg, 300) : null, error: req.query.error ? txt(req.query.error, 300) : null, body }));
}));

function readItem(body) {
  return {
    supplier_id: idOf(body.supplier_id),
    code: txt(body.code, 60) || null,
    name: txt(body.name, 200),
    unit: txt(body.unit, 30) || 'each',
    price: num(body.price),
    cut_material: body.cut_material === 'on',
    active: body.active === undefined ? true : body.active === 'on',
  };
}
const itemError = (v) => (!v.name ? 'Enter an item name.' : v.price === null || Number.isNaN(v.price) ? 'Enter a price of 0 or more.' : null);

router.post('/admin/price-list', admin, wrap(async (req, res) => {
  const v = readItem(req.body);
  const error = itemError(v);
  if (error) return res.redirect('/admin/price-list?error=' + encodeURIComponent(error));
  await query('INSERT INTO price_items (supplier_id, code, name, unit, price, cut_material) VALUES ($1, $2, $3, $4, $5, $6)',
    [v.supplier_id, v.code, v.name, v.unit, v.price, v.cut_material]);
  res.redirect('/admin/price-list?msg=' + encodeURIComponent(`Added ${v.name}.`) + (v.supplier_id ? `&supplier=${v.supplier_id}` : ''));
}));

router.get('/admin/price-list/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const p = id && (await query('SELECT * FROM price_items WHERE id = $1', [id])).rows[0];
  if (!p) return res.redirect('/admin/price-list');
  const used = (await query(
    `SELECT DISTINCT t.id, t.name FROM template_materials tm JOIN job_templates t ON t.id = tm.template_id WHERE tm.price_item_id = $1 ORDER BY t.name`, [id])).rows;
  const body = `${subnav('/admin/price-list')}
    <form method="post" action="/admin/price-list/${p.id}" class="panel narrow">
      ${itemFields(p, await supplierOptions(p.supplier_id))}
      <label class="check"><input type="checkbox" name="active" ${p.active ? 'checked' : ''}> Active (switch off instead of deleting)</label>
      <input type="hidden" name="active_present" value="1">
      <button class="primary">Save item</button>
    </form>
    ${used.length ? `<p>Used in: ${used.map((t) => `<a href="/admin/templates/${t.id}">${esc(t.name)}</a>`).join(', ')}</p>` : '<p class="muted">Not used in any job template yet.</p>'}
    <p><a href="/admin/price-list">Back to price list</a></p>`;
  res.send(page({ title: `Edit ${p.name}`, user: req.user, body }));
}));

router.post('/admin/price-list/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  if (!id) return res.redirect('/admin/price-list');
  const v = readItem({ ...req.body, active: req.body.active_present ? (req.body.active || 'off') : undefined });
  const error = itemError(v);
  if (error) return res.redirect('/admin/price-list?error=' + encodeURIComponent(error));
  await query(
    `UPDATE price_items SET supplier_id = $1, code = $2, name = $3, unit = $4, price = $5, cut_material = $6, active = $7, updated_at = now() WHERE id = $8`,
    [v.supplier_id, v.code, v.name, v.unit, v.price, v.cut_material, v.active, id]);
  res.redirect('/admin/price-list?msg=' + encodeURIComponent(`Saved ${v.name}.`));
}));

function parseCsvLine(line) {
  const out = [];
  let cur = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quoted) {
      if (c === '"') {
        if (line[i + 1] === '"') { cur += '"'; i++; } else quoted = false;
      } else cur += c;
    } else if (c === '"') quoted = true;
    else if (c === ',' || c === '\t') { out.push(cur); cur = ''; }
    else cur += c;
  }
  out.push(cur);
  return out.map((s) => s.trim());
}

router.post('/admin/price-list/import', admin, wrap(async (req, res) => {
  const supplierId = idOf(req.body.supplier_id);
  if (!supplierId) return res.redirect('/admin/price-list?error=' + encodeURIComponent('Choose a supplier for the import.'));
  const lines = String(req.body.csv || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean).slice(0, 2000);
  let added = 0;
  let updated = 0;
  const problems = [];
  for (let i = 0; i < lines.length; i++) {
    const [code, name, unit, price, cut] = parseCsvLine(lines[i]);
    if (i === 0 && /^(code|name|item)$/i.test(code || '')) continue; // header row
    const p = num(price);
    if (!name || p === null || Number.isNaN(p)) { problems.push(i + 1); continue; }
    const isCut = /^(y|yes|true|1|cut)$/i.test(cut || '');
    const existing = code
      ? (await query('SELECT id FROM price_items WHERE supplier_id = $1 AND code = $2', [supplierId, code])).rows[0]
      : (await query('SELECT id FROM price_items WHERE supplier_id = $1 AND lower(name) = lower($2)', [supplierId, name])).rows[0];
    if (existing) {
      await query('UPDATE price_items SET name = $1, unit = $2, price = $3, cut_material = $4, active = true, updated_at = now() WHERE id = $5',
        [name.slice(0, 200), (unit || 'each').slice(0, 30), p, isCut, existing.id]);
      updated++;
    } else {
      await query('INSERT INTO price_items (supplier_id, code, name, unit, price, cut_material) VALUES ($1, $2, $3, $4, $5, $6)',
        [supplierId, code ? code.slice(0, 60) : null, name.slice(0, 200), (unit || 'each').slice(0, 30), p, isCut]);
      added++;
    }
  }
  const msg = `Import finished: ${added} added, ${updated} updated.` + (problems.length ? ` Skipped line${problems.length === 1 ? '' : 's'} ${problems.slice(0, 15).join(', ')} (missing name or price).` : '');
  res.redirect(`/admin/price-list?supplier=${supplierId}&msg=${encodeURIComponent(msg)}`);
}));

// ================= Job templates =================
router.get('/admin/templates', admin, wrap(async (req, res) => {
  const { rows } = await query(
    `SELECT t.*, (SELECT count(*)::int FROM template_materials m WHERE m.template_id = t.id) AS materials
     FROM job_templates t ORDER BY t.active DESC, t.work_type, t.name`);
  const list = rows.length ? `<div class="scroll"><table>
    <thead><tr><th>Template</th><th>Type of work</th><th>Pricing</th><th>Materials</th><th>Status</th></tr></thead>
    <tbody>${rows.map((t) => `<tr class="${t.active ? '' : 'off'}">
      <td><a href="/admin/templates/${t.id}">${esc(t.name)}</a></td><td>${esc(t.work_type)}</td>
      <td>${METHODS[t.pricing_method]}</td><td>${t.materials}</td><td>${t.active ? 'Shown to customers' : 'Hidden'}</td>
    </tr>`).join('')}</tbody></table></div>` : '<p class="empty">No templates yet. Start with the job you do most often.</p>';
  const body = `${subnav('/admin/templates')}
    <p class="lead">Each template is a job customers can pick. Its labour, materials and your rates work out the estimate.</p>
    ${list}
    <h2>New template</h2>
    <form method="post" action="/admin/templates" class="panel narrow">
      <label>Job name customers will see<input name="name" required maxlength="120" placeholder="Hang an internal door"></label>
      <label>Type of work<select name="work_type">${WORK_TYPES.filter((w) => w !== 'Something else').map((w) => `<option>${esc(w)}</option>`).join('')}</select></label>
      <label>Pricing method<select name="pricing_method">${Object.entries(METHODS).map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></label>
      <button class="primary">Create and set up</button>
    </form>`;
  res.send(page({ title: 'Job templates', user: req.user, body }));
}));

router.post('/admin/templates', admin, wrap(async (req, res) => {
  const name = txt(req.body.name, 120);
  const method = METHODS[req.body.pricing_method] ? req.body.pricing_method : 'hourly';
  const workType = WORK_TYPES.includes(req.body.work_type) ? req.body.work_type : null;
  if (!name) return res.redirect('/admin/templates');
  const { rows } = await query('INSERT INTO job_templates (name, work_type, pricing_method, active) VALUES ($1, $2, $3, false) RETURNING id', [name, workType, method]);
  res.redirect(`/admin/templates/${rows[0].id}?created=1`);
}));

router.get('/admin/templates/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const t = id && (await query('SELECT * FROM job_templates WHERE id = $1', [id])).rows[0];
  if (!t) return res.redirect('/admin/templates');
  const mats = (await query(
    `SELECT tm.id, tm.qty_per_unit, p.name, p.unit, p.price, p.active, s.name AS supplier
     FROM template_materials tm JOIN price_items p ON p.id = tm.price_item_id LEFT JOIN suppliers s ON s.id = p.supplier_id
     WHERE tm.template_id = $1 ORDER BY tm.id`, [id])).rows;
  const items = (await query(
    `SELECT p.id, p.name, p.unit, p.price, s.name AS supplier FROM price_items p LEFT JOIN suppliers s ON s.id = p.supplier_id
     WHERE p.active ORDER BY p.name`)).rows;
  const cur = (await query('SELECT currency FROM settings WHERE id = 1')).rows[0].currency;
  const unitWord = UNIT_WORD[t.pricing_method];
  const perWhat = t.quantity_unit ? esc(t.quantity_unit.replace(/s$/, '')) : 'unit';

  const previewQty = Number(req.query.qty) > 0 ? Number(req.query.qty) : 1;
  const est = await calculateEstimate({ templateId: id, quantity: previewQty, skipTravel: true });

  const v = (k) => esc(t[k] ?? '');
  const body = `${subnav('/admin/templates')}
  <div class="twocol">
  <section>
    <form method="post" action="/admin/templates/${t.id}" class="panel">
      <label>Job name customers will see<input name="name" value="${v('name')}" required maxlength="120"></label>
      <label>Type of work<select name="work_type">${WORK_TYPES.filter((w) => w !== 'Something else').map((w) => `<option ${w === t.work_type ? 'selected' : ''}>${esc(w)}</option>`).join('')}</select></label>
      <label>Short description for customers (optional)<textarea name="description" rows="2" maxlength="500">${v('description')}</textarea></label>

      <label>Pricing method<select name="pricing_method">${Object.entries(METHODS).map(([k, l]) => `<option value="${k}" ${k === t.pricing_method ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
      <div class="row">
        <label>Labour per ${perWhat} (${unitWord})<input name="labour_per_unit" type="number" step="0.01" min="0" value="${v('labour_per_unit')}"></label>
        <label>Plus once per job (${unitWord})<input name="labour_setup" type="number" step="0.01" min="0" value="${v('labour_setup')}"></label>
      </div>
      <label>Crew size (blank uses the default)<input name="crew" type="number" step="1" min="1" value="${v('crew')}"></label>

      <label>Sizing question (blank means no question, quantity 1)<input name="quantity_question" value="${v('quantity_question')}" maxlength="120" placeholder="How many doors?"></label>
      <div class="row">
        <label>Unit word<input name="quantity_unit" value="${v('quantity_unit')}" maxlength="30" placeholder="doors, m², panels"></label>
        <label>Most a customer can enter<input name="max_quantity" type="number" step="0.5" min="1" value="${v('max_quantity')}"></label>
      </div>

      <div class="row">
        <label>Range below (%, blank = default)<input name="range_low_pct" type="number" step="0.1" min="0" value="${v('range_low_pct')}"></label>
        <label>Range above (%, blank = default)<input name="range_high_pct" type="number" step="0.1" min="0" value="${v('range_high_pct')}"></label>
      </div>
      <label class="check"><input type="checkbox" name="materials_included" ${t.materials_included ? 'checked' : ''}> Materials are included in the fixed price</label>
      <label class="check"><input type="checkbox" name="active" ${t.active ? 'checked' : ''}> Show this job to customers</label>
      <button class="primary">Save template</button>
    </form>

    <h2>Materials per ${perWhat}</h2>
    ${mats.length ? `<div class="scroll"><table>
      <thead><tr><th>Item</th><th>Qty</th><th class="num">Price</th><th></th></tr></thead>
      <tbody>${mats.map((m) => `<tr class="${m.active ? '' : 'off'}">
        <td>${esc(m.name)}${m.supplier ? ` <span class="muted">(${esc(m.supplier)})</span>` : ''}</td>
        <td>${Number(m.qty_per_unit)} ${esc(m.unit)}</td><td class="num">${money(m.price, cur)}</td>
        <td><form method="post" action="/admin/templates/${t.id}/materials/${m.id}/delete" class="inline"><button class="small">Remove</button></form></td>
      </tr>`).join('')}</tbody></table></div>` : '<p class="empty">No materials yet.</p>'}
    ${items.length ? `<form method="post" action="/admin/templates/${t.id}/materials" class="panel addmat">
      <label>Item<select name="price_item_id" required>${items.map((p) => `<option value="${p.id}">${esc(p.name)} (${esc(p.unit)}, ${money(p.price, cur)}${p.supplier ? `, ${esc(p.supplier)}` : ''})</option>`).join('')}</select></label>
      <label>Qty per ${perWhat}<input name="qty_per_unit" type="number" step="0.01" min="0" value="1" required></label>
      <button class="small">Add material</button>
    </form>` : '<p>Add items to the <a href="/admin/price-list">price list</a> first.</p>'}
  </section>

  <section>
    <h2>Example estimate</h2>
    <form method="get" action="/admin/templates/${t.id}" class="filters">
      <label>${t.quantity_question ? esc(t.quantity_question) : 'Quantity'}<input name="qty" type="number" step="0.5" min="0.5" value="${previewQty}" ${t.quantity_question ? '' : 'disabled'}></label>
      <button class="small">Recalculate</button>
    </form>
    <p class="hint">Uses today’s prices and rates, with no travel, access issues or urgency.</p>
    ${est ? renderBreakdown(est) : ''}
  </section>
  </div>
  <p><a href="/admin/templates">Back to templates</a></p>`;
  const notice = req.query.created ? 'Template created. It stays hidden from customers until you tick “Show this job to customers”.' : req.query.saved ? 'Template saved.' : null;
  res.send(page({ title: t.name, user: req.user, notice, error: req.query.error ? txt(req.query.error) : null, body }));
}));

router.post('/admin/templates/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  if (!id) return res.redirect('/admin/templates');
  const b = req.body;
  const name = txt(b.name, 120);
  const nums = {};
  for (const k of ['labour_per_unit', 'labour_setup', 'crew', 'max_quantity', 'range_low_pct', 'range_high_pct']) nums[k] = num(b[k]);
  const bad = Object.entries(nums).find(([, n]) => Number.isNaN(n));
  if (!name || bad) return res.redirect(`/admin/templates/${id}?error=` + encodeURIComponent(!name ? 'Enter a job name.' : 'Numbers must be 0 or more.'));
  await query(
    `UPDATE job_templates SET name = $1, work_type = $2, description = $3, pricing_method = $4, labour_per_unit = $5, labour_setup = $6,
       crew = $7, quantity_question = $8, quantity_unit = $9, max_quantity = $10, range_low_pct = $11, range_high_pct = $12,
       materials_included = $13, active = $14 WHERE id = $15`,
    [name, WORK_TYPES.includes(b.work_type) ? b.work_type : null, txt(b.description, 500) || null,
      METHODS[b.pricing_method] ? b.pricing_method : 'hourly', nums.labour_per_unit || 0, nums.labour_setup || 0,
      nums.crew ? Math.max(1, Math.round(nums.crew)) : null, txt(b.quantity_question, 120) || null, txt(b.quantity_unit, 30) || null,
      nums.max_quantity || 50, nums.range_low_pct, nums.range_high_pct, b.materials_included === 'on', b.active === 'on', id]);
  res.redirect(`/admin/templates/${id}?saved=1`);
}));

router.post('/admin/templates/:id/materials', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const itemId = idOf(req.body.price_item_id);
  const qty = num(req.body.qty_per_unit);
  if (id && itemId && qty !== null && !Number.isNaN(qty)) {
    await query('INSERT INTO template_materials (template_id, price_item_id, qty_per_unit) VALUES ($1, $2, $3)', [id, itemId, qty]);
  }
  res.redirect(`/admin/templates/${id || ''}`);
}));

router.post('/admin/templates/:id/materials/:mid/delete', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const mid = idOf(req.params.mid);
  if (id && mid) await query('DELETE FROM template_materials WHERE id = $1 AND template_id = $2', [mid, id]);
  res.redirect(`/admin/templates/${id || ''}`);
}));

// ================= Access options =================
router.get('/admin/access-options', admin, wrap(async (req, res) => {
  const { rows } = await query('SELECT * FROM access_options ORDER BY active DESC, id');
  const body = `${subnav('/admin/access-options')}
    <p class="lead">Customers tick these on the request form. Each one multiplies the labour, so 1.2 adds 20%.</p>
    ${rows.map((a) => `<form method="post" action="/admin/access-options/${a.id}" class="panel accessrow ${a.active ? '' : 'off'}">
      <label>Label<input name="label" value="${esc(a.label)}" required maxlength="120"></label>
      <label>Multiplier<input name="multiplier" type="number" step="0.05" min="0.5" value="${esc(a.multiplier)}" required></label>
      <label class="check"><input type="checkbox" name="active" ${a.active ? 'checked' : ''}> Active</label>
      <button class="small">Save</button>
    </form>`).join('')}
    <h2>Add an option</h2>
    <form method="post" action="/admin/access-options" class="panel accessrow">
      <label>Label<input name="label" required maxlength="120" placeholder="Third floor or higher, no lift"></label>
      <label>Multiplier<input name="multiplier" type="number" step="0.05" min="0.5" value="1.1" required></label>
      <button class="primary">Add option</button>
    </form>`;
  res.send(page({ title: 'Access options', user: req.user, notice: req.query.saved ? 'Saved.' : null, body }));
}));

router.post('/admin/access-options', admin, wrap(async (req, res) => {
  const label = txt(req.body.label, 120);
  const m = num(req.body.multiplier);
  if (label && m > 0) await query('INSERT INTO access_options (label, multiplier) VALUES ($1, $2)', [label, m]);
  res.redirect('/admin/access-options?saved=1');
}));

router.post('/admin/access-options/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const label = txt(req.body.label, 120);
  const m = num(req.body.multiplier);
  if (id && label && m > 0) await query('UPDATE access_options SET label = $1, multiplier = $2, active = $3 WHERE id = $4', [label, m, req.body.active === 'on', id]);
  res.redirect('/admin/access-options?saved=1');
}));

module.exports = router;
HANDYTRIO_EOF

cat > scripts/seed-example.js <<'HANDYTRIO_EOF'
// Adds one example supplier, three price items and a "Hang an internal door" template, only if no templates exist yet.
require('dotenv').config();
const { Client } = require('pg');

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const has = (await c.query('SELECT 1 FROM job_templates LIMIT 1')).rows.length;
  if (has) {
    console.log('Templates already exist, example not added.');
    return c.end();
  }
  await c.query('BEGIN');
  const sup = (await c.query(
    `INSERT INTO suppliers (name) VALUES ('Example Merchants') ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id`)).rows[0].id;
  const add = async (code, name, unit, price) => (await c.query(
    'INSERT INTO price_items (supplier_id, code, name, unit, price) VALUES ($1, $2, $3, $4, $5) RETURNING id', [sup, code, name, unit, price])).rows[0].id;
  const door = await add('EX-DOOR', 'Internal door, 762mm', 'each', 45);
  const hinges = await add('EX-HINGE', 'Hinges 75mm (1.5 pairs)', 'set', 8);
  const handle = await add('EX-HANDLE', 'Door handle and latch set', 'set', 15);
  const t = (await c.query(
    `INSERT INTO job_templates (name, work_type, description, pricing_method, labour_per_unit, quantity_question, quantity_unit, max_quantity, active)
     VALUES ('Hang an internal door', 'Doors and windows', 'Supply and hang a standard internal door with hinges and handle.', 'hourly', 3, 'How many doors?', 'doors', 20, true)
     RETURNING id`)).rows[0].id;
  for (const id of [door, hinges, handle]) {
    await c.query('INSERT INTO template_materials (template_id, price_item_id, qty_per_unit) VALUES ($1, $2, 1)', [t, id]);
  }
  await c.query('COMMIT');
  console.log('Added example template "Hang an internal door" with Example Merchants prices.');
  await c.end();
})().catch((e) => {
  console.error('Example not added:', e.message);
  process.exit(1);
});
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

/* Stage 2: job requests and job pages */
textarea { display: block; width: 100%; margin-top: .3rem; padding: .6rem .7rem; font: inherit; color: var(--ink); background: var(--bg); border: 1px solid var(--line); border-radius: 4px; resize: vertical; }
input[type="file"] { padding: .5rem; }
.hint { color: var(--muted); font-size: .9rem; margin: -.4rem 0 .6rem; }
.request { max-width: 640px; }
.request legend { font: 600 1.2rem "Barlow Condensed", Barlow, sans-serif; padding: 0 .3rem; }

a.button { display: inline-block; text-decoration: none; border: 1px solid var(--line); background: var(--surface); color: var(--ink); border-radius: 4px; padding: .55rem 1.1rem; font-weight: 600; }
a.button.primary { background: var(--hivis); color: var(--hivis-ink); border-color: transparent; }
button.danger { color: var(--bad-ink); border-color: var(--bad-ink); }

.jobhead { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin: -.5rem 0 1rem; }
.jobhead .ref { font: 700 1.1rem "Barlow Condensed", Barlow, sans-serif; color: var(--muted); }
.jobgrid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1rem; }
.jobgrid .panel { margin: 0; }
.jobgrid h2 { margin-top: 0; }
dl { margin: 0; display: grid; grid-template-columns: max-content 1fr; gap: .5rem 1rem; }
dt { color: var(--muted); }
dd { margin: 0; overflow-wrap: anywhere; }
.pre { white-space: pre-wrap; }

.photos { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: .5rem; margin-bottom: .75rem; }
.photos img { width: 100%; aspect-ratio: 4 / 3; object-fit: cover; border-radius: 4px; border: 1px solid var(--line); display: block; }
.inline-form { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin: 0 0 1rem; }
.inline-form input[type="file"] { width: auto; flex: 1 1 220px; margin: 0; }
.admin-actions { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 1rem; margin-top: 1rem; }
.admin-actions .panel { margin: 0; }

.history { list-style: none; padding: 0; margin: 0 0 1rem; border-left: 3px solid var(--line); }
.history li { padding: .3rem 0 .6rem 1rem; }

@media (max-width: 560px) {
  dl { grid-template-columns: 1fr; gap: .1rem; }
  dd { margin-bottom: .5rem; }
}

/* Stage 3: pricing and estimates */
.lead { max-width: 65ch; }
.subnav { display: flex; flex-wrap: wrap; gap: .25rem; margin: 0 0 1.25rem; border-bottom: 2px solid var(--line); }
.subnav a { text-decoration: none; padding: .45rem .8rem; border-bottom: 3px solid transparent; margin-bottom: -2px; color: var(--muted); }
.subnav a[aria-current="page"] { color: var(--ink); border-bottom-color: var(--hivis); font-weight: 600; }
.twocol { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 1.5rem; align-items: start; }
.twocol h2:first-child { margin-top: 0; }
.filters { display: flex; flex-wrap: wrap; gap: .75rem; align-items: end; margin: 0 0 1rem; }
.filters label { margin: 0; }
.filters input, .filters select { width: auto; min-width: 160px; }
td.num, th.num { text-align: right; }
.addmat { display: grid; grid-template-columns: 1fr 120px auto; gap: .75rem; align-items: end; margin-top: .75rem; }
.addmat label { margin: 0; }
.accessrow { display: grid; grid-template-columns: 1fr 120px auto auto; gap: .75rem; align-items: end; margin-bottom: .5rem; }
.accessrow label { margin: 0; }
.accessrow.off { opacity: .6; }

.choices { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: .75rem; }
.choice { display: flex; flex-direction: column; gap: .25rem; text-decoration: none; background: var(--surface); border: 1px solid var(--line); border-left: 5px solid var(--slate); border-radius: 6px; padding: .9rem 1rem; }
.choice:hover { border-left-color: var(--hivis); }
.choice span { color: var(--muted); font-size: .92rem; }
.picked { display: flex; gap: .75rem; align-items: baseline; margin: 0 0 .75rem; }
.fieldlabel { font-weight: 500; margin: 0 0 .4rem; }

.estimate .bigprice { font: 700 2rem/1.1 "Barlow Condensed", Barlow, sans-serif; margin: .25rem 0 .5rem; }
.estimate details { margin: .75rem 0; }
.estimate summary { cursor: pointer; font-weight: 600; }
.breakdown td { white-space: normal; }
.breakdown tr.group th { background: var(--bg); color: var(--ink); }
.breakdown tr.sum td { font-weight: 600; }
.breakdown tr.grand td { font-weight: 700; font-size: 1.1rem; border-top: 2px solid var(--ink); }
.warnings { background: var(--bad-bg); color: var(--bad-ink); border-radius: 4px; padding: .6rem 1rem .6rem 2rem; margin: .75rem 0 0; }

@media (max-width: 560px) {
  .addmat, .accessrow { grid-template-columns: 1fr; }
}
HANDYTRIO_EOF

echo "Updating database..."
node scripts/migrate.js
node scripts/seed-example.js
touch src/server.js
echo ""
echo "Stage 3 installed. If the app was running, it restarts by itself; otherwise run: npm run dev"
