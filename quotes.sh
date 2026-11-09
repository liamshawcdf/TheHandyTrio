#!/usr/bin/env bash
# TheHandyTrio stage 4: quotes customers can see, accept or decline, with PDF. Run with: bash quotes.sh
set -e
if [ ! -f package.json ]; then echo "Run this inside the TheHandyTrio folder"; exit 1; fi
echo "Installing PDF package..."
npm install pdfkit@0.15
mkdir -p src/routes

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

-- Stage 3b: worksheets, time tracking and customer emails
CREATE TABLE IF NOT EXISTS job_estimate_lines (
  id          serial PRIMARY KEY,
  job_id      int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  category    text NOT NULL DEFAULT 'materials' CHECK (category IN ('materials','labour','travel','other')),
  description text NOT NULL,
  qty         numeric NOT NULL DEFAULT 1,
  unit        text,
  unit_price  numeric NOT NULL DEFAULT 0,
  sort        int NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS job_estimate_lines_job_idx ON job_estimate_lines (job_id);
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS worksheet_updated_at timestamptz;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS worksheet_updated_by int REFERENCES users(id);
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS worksheet_notes text;

CREATE TABLE IF NOT EXISTS job_time_entries (
  id         serial PRIMARY KEY,
  job_id     int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  user_id    int NOT NULL REFERENCES users(id),
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at   timestamptz,
  note       text
);
CREATE INDEX IF NOT EXISTS job_time_entries_job_idx ON job_time_entries (job_id);
CREATE INDEX IF NOT EXISTS job_time_entries_open_idx ON job_time_entries (user_id) WHERE ended_at IS NULL;

CREATE TABLE IF NOT EXISTS email_templates (
  status  text PRIMARY KEY,
  subject text NOT NULL,
  body    text NOT NULL,
  enabled boolean NOT NULL DEFAULT true
);
INSERT INTO email_templates (status, subject, body) VALUES
 ('request', 'We have your job request ({job_ref})', E'Hi {first_name},\n\nThanks for your request for "{job_title}". We will review it and be in touch soon.\n\nYou can follow progress here:\n{job_link}\n\nThanks,\n{business_name}'),
 ('inspection_required', 'We will need to see your job ({job_ref})', E'Hi {first_name},\n\nThanks for your request for "{job_title}". This job needs a quick visit before we can price it, so we will be in touch to arrange a time.\n\n{job_link}\n\nThanks,\n{business_name}'),
 ('estimated', 'Your price guide for {job_title} ({job_ref})', E'Hi {first_name},\n\nThanks for your request. Based on what you told us, our price guide is {price_guide}.\n\nWe will confirm the exact price once we have seen the job.\n\n{job_link}\n\nThanks,\n{business_name}'),
 ('inspection_booked', 'Your inspection visit is booked ({job_ref})', E'Hi {first_name},\n\nWe have booked a visit to look at "{job_title}". We will confirm the time with you.\n\n{job_link}\n\nThanks,\n{business_name}'),
 ('inspected', 'Thanks for having us round ({job_ref})', E'Hi {first_name},\n\nThanks for letting us look at "{job_title}". We are now preparing your quote.\n\n{job_link}\n\nThanks,\n{business_name}'),
 ('quoted', 'Your quote is ready ({job_ref})', E'Hi {first_name},\n\nYour quote for "{job_title}" is ready. You can view it and accept or decline here:\n{job_link}\n\nThanks,\n{business_name}'),
 ('accepted', 'Thanks for accepting your quote ({job_ref})', E'Hi {first_name},\n\nThanks for accepting our quote for "{job_title}". We will be in touch about the deposit and start date.\n\n{job_link}\n\nThanks,\n{business_name}'),
 ('declined', 'Your job has been closed ({job_ref})', E'Hi {first_name},\n\nYour job "{job_title}" has been closed. If anything changes, we would be happy to help in future.\n\nThanks,\n{business_name}'),
 ('deposit_requested', 'Deposit for your job ({job_ref})', E'Hi {first_name},\n\nTo book in "{job_title}", please pay the deposit. Details are here:\n{job_link}\n\nThanks,\n{business_name}'),
 ('deposit_paid', 'Deposit received, thank you ({job_ref})', E'Hi {first_name},\n\nWe have received your deposit for "{job_title}". We will now order materials and plan the work.\n\n{job_link}\n\nThanks,\n{business_name}'),
 ('parts_ordered', 'Materials ordered for your job ({job_ref})', E'Hi {first_name},\n\nWe have ordered the materials for "{job_title}".\n\n{job_link}\n\nThanks,\n{business_name}'),
 ('scheduled', 'Your job is booked in ({job_ref})', E'Hi {first_name},\n\n"{job_title}" is now booked in. You can see the details here:\n{job_link}\n\nThanks,\n{business_name}'),
 ('in_progress', 'Work has started ({job_ref})', E'Hi {first_name},\n\nWork on "{job_title}" has started.\n\n{job_link}\n\nThanks,\n{business_name}'),
 ('complete', 'Work complete ({job_ref})', E'Hi {first_name},\n\nWe have finished "{job_title}". Thank you for choosing us. Your invoice will follow shortly.\n\n{job_link}\n\nThanks,\n{business_name}'),
 ('invoiced', 'Your invoice is ready ({job_ref})', E'Hi {first_name},\n\nYour invoice for "{job_title}" is ready here:\n{job_link}\n\nThanks,\n{business_name}'),
 ('paid', 'Payment received, thank you ({job_ref})', E'Hi {first_name},\n\nWe have received your payment for "{job_title}". Thanks again for choosing us.\n\n{business_name}'),
 ('cancelled', 'Your job request has been cancelled ({job_ref})', E'Hi {first_name},\n\nYour request "{job_title}" has been cancelled. If this was a mistake, just send a new request.\n\nThanks,\n{business_name}')
ON CONFLICT (status) DO NOTHING;

CREATE TABLE IF NOT EXISTS email_log (
  id         serial PRIMARY KEY,
  job_id     int REFERENCES jobs(id) ON DELETE SET NULL,
  to_address text,
  subject    text,
  body       text,
  status     text NOT NULL,
  error      text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Stage 4: quotes
ALTER TABLE settings ADD COLUMN IF NOT EXISTS business_address text NOT NULL DEFAULT '';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS business_phone text NOT NULL DEFAULT '';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS business_email text NOT NULL DEFAULT '';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS quote_valid_days int NOT NULL DEFAULT 30;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS quote_terms text NOT NULL DEFAULT 'Prices are based on the work described. Anything extra found once work starts will be agreed with you before we carry it out. A deposit is due on acceptance and the balance on completion.';

CREATE TABLE IF NOT EXISTS quotes (
  id            serial PRIMARY KEY,
  job_id        int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  layout        text NOT NULL DEFAULT 'itemised' CHECK (layout IN ('itemised','summary')),
  scope         text,
  customer_note text,
  lines         jsonb NOT NULL,
  net           numeric NOT NULL,
  vat_rate      numeric NOT NULL DEFAULT 0,
  vat           numeric NOT NULL DEFAULT 0,
  total         numeric NOT NULL,
  deposit_pct   numeric NOT NULL DEFAULT 0,
  deposit       numeric NOT NULL DEFAULT 0,
  valid_until   date,
  status        text NOT NULL DEFAULT 'sent' CHECK (status IN ('sent','accepted','declined','superseded')),
  created_by    int REFERENCES users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  responded_at  timestamptz,
  responded_by  int REFERENCES users(id),
  response_note text
);
CREATE INDEX IF NOT EXISTS quotes_job_idx ON quotes (job_id);
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
app.use(require('./routes/onsite').router);
app.use(require('./routes/quotes').router);
app.use(require('./routes/emails'));

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

cat > src/routes/quotes.js <<'HANDYTRIO_EOF'
// Quotes: sent from the working estimate, viewed and accepted or declined by the customer, downloadable as PDF.
const express = require('express');
const PDFDocument = require('pdfkit');
const { pool, query } = require('../db');
const { esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day } = require('../format');
const { money } = require('../estimate');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange } = require('../notify');

const router = express.Router();
const N = (x) => Number(x) || 0;
const r2 = (n) => Math.round(n * 100) / 100;
const qref = (id) => 'Q-' + String(id).padStart(5, '0');
const CAT_SUMMARY = { materials: 'Materials', labour: 'Labour', travel: 'Travel and other costs', other: 'Travel and other costs' };

async function currentQuote(jobId) {
  return (await query("SELECT * FROM quotes WHERE job_id = $1 AND status <> 'superseded' ORDER BY id DESC LIMIT 1", [jobId])).rows[0] || null;
}

// What the customer sees: every line, or one line per type.
function displayLines(q) {
  if (q.layout === 'itemised') {
    return q.lines.map((l) => ({ description: l.description, qty: N(l.qty), unit: l.unit || '', price: N(l.unit_price), total: r2(N(l.qty) * N(l.unit_price)) }));
  }
  const groups = {};
  for (const l of q.lines) {
    const k = CAT_SUMMARY[l.category] || 'Other';
    groups[k] = r2((groups[k] || 0) + N(l.qty) * N(l.unit_price));
  }
  return Object.entries(groups).map(([description, total]) => ({ description, qty: null, unit: '', price: null, total }));
}

const fmtQty = (n) => (n === null ? '' : String(Math.round(n * 100) / 100));

// ---------- Panel on the job page ----------
async function quotePanel(job, user) {
  const q = await currentQuote(job.id);
  const s = (await query('SELECT currency FROM settings WHERE id = 1')).rows[0];
  const m = (n) => money(n, s.currency);
  if (!q) return '';
  const rows = displayLines(q);
  const itemised = q.layout === 'itemised';
  const canRespond = q.status === 'sent' && job.status === 'quoted' && (user.role === 'admin' || (user.role === 'customer' && job.customer_id === user.id));
  const expired = q.valid_until && new Date(q.valid_until) < new Date(new Date().toDateString());

  return `<section class="panel quote" id="quote">
    <div class="quotehead">
      <h2>Quote ${qref(q.id)}</h2>
      <span class="tag ${q.status === 'accepted' ? 'ok' : ''}">${{ sent: expired ? 'Expired' : 'Waiting for your answer', accepted: 'Accepted', declined: 'Declined' }[q.status] || ''}</span>
    </div>
    <p class="muted">Sent ${day(q.created_at)}${q.valid_until ? `, valid until ${day(q.valid_until)}` : ''}</p>
    ${q.scope ? `<h3>The work</h3><p class="pre">${esc(q.scope)}</p>` : ''}
    <div class="scroll"><table class="quotetable">
      <thead><tr><th>Description</th>${itemised ? '<th class="num">Qty</th><th>Unit</th><th class="num">Price</th>' : ''}<th class="num">Total</th></tr></thead>
      <tbody>${rows.map((r) => `<tr><td>${esc(r.description)}</td>${itemised ? `<td class="num">${fmtQty(r.qty)}</td><td>${esc(r.unit)}</td><td class="num">${m(r.price)}</td>` : ''}<td class="num">${m(r.total)}</td></tr>`).join('')}</tbody>
    </table></div>
    <div class="wtotals">
      <div><span>Net</span><span>${m(q.net)}</span></div>
      ${N(q.vat) ? `<div><span>VAT ${N(q.vat_rate)}%</span><span>${m(q.vat)}</span></div>` : ''}
      <div class="grand"><span>Total</span><span>${m(q.total)}</span></div>
      ${N(q.deposit) ? `<div><span>Deposit to book (${N(q.deposit_pct)}%)</span><span>${m(q.deposit)}</span></div>` : ''}
    </div>
    ${q.customer_note ? `<p class="pre">${esc(q.customer_note)}</p>` : ''}
    <div class="buttons">
      <a class="button" href="/jobs/${job.id}/quotes/${q.id}/pdf" target="_blank" rel="noopener">View or print</a>
      <a class="button" href="/jobs/${job.id}/quotes/${q.id}/pdf?download=1">Download PDF</a>
    </div>
    ${canRespond && !expired ? `<div class="respond">
      <form method="post" action="/jobs/${job.id}/quotes/${q.id}/accept" class="inline">
        <button class="primary">${user.role === 'admin' ? 'Mark as accepted' : 'Accept this quote'}</button>
      </form>
      <details><summary>${user.role === 'admin' ? 'Mark as declined' : 'Decline'}</summary>
        <form method="post" action="/jobs/${job.id}/quotes/${q.id}/decline" class="panel">
          <label>Reason (optional)<textarea name="reason" rows="2" maxlength="500"></textarea></label>
          <button class="small danger">Decline quote</button>
        </form>
      </details>
    </div>` : ''}
    ${canRespond && expired ? `<p>This quote has expired. ${user.role === 'customer' ? 'Get in touch and we’ll send an updated one.' : 'Send an updated quote from the working estimate.'}</p>` : ''}
    ${q.status !== 'sent' && q.responded_at ? `<p class="muted">${q.status === 'accepted' ? 'Accepted' : 'Declined'} ${day(q.responded_at)}${user.role !== 'customer' && q.response_note ? `: ${esc(q.response_note)}` : ''}</p>` : ''}
  </section>`;
}

// The "send quote" form shown to the office under the working estimate.
async function sendQuoteForm(job, user) {
  if (user.role !== 'admin') return '';
  const lines = (await query('SELECT 1 FROM job_estimate_lines WHERE job_id = $1 LIMIT 1', [job.id])).rows.length;
  if (!lines) return '';
  if (['accepted', 'deposit_requested', 'deposit_paid', 'parts_ordered', 'scheduled', 'in_progress', 'complete', 'invoiced', 'paid', 'cancelled'].includes(job.status)) return '';
  const existing = await currentQuote(job.id);
  return `<details class="panel sendquote" ${req_open(job)}>
    <summary><strong>${existing ? 'Send an updated quote' : 'Send quote to customer'}</strong></summary>
    <form method="post" action="/jobs/${job.id}/quotes">
      <label>Description of the work (shown on the quote)<textarea name="scope" rows="4" maxlength="4000">${esc(existing ? existing.scope : job.description)}</textarea></label>
      <label>How should prices show?<select name="layout">
        <option value="itemised">Every line with quantities and prices</option>
        <option value="summary">Totals for materials, labour, and travel and other costs</option>
      </select></label>
      <label>Message to the customer (optional)<textarea name="customer_note" rows="2" maxlength="2000"></textarea></label>
      <p class="hint">Uses the working estimate as it is now. The customer is emailed and can accept or decline online.${existing ? ' The previous quote is replaced.' : ''}</p>
      <button class="primary">${existing ? 'Send updated quote' : 'Send quote'}</button>
    </form>
  </details>`;
}
const req_open = (job) => (['inspected', 'estimated'].includes(job.status) ? 'open' : '');

// ---------- Send ----------
router.post('/jobs/:id/quotes', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const lines = (await query('SELECT category, description, qty, unit, unit_price FROM job_estimate_lines WHERE job_id = $1 ORDER BY sort, id', [job.id])).rows
    .map((l) => ({ category: l.category, description: l.description, qty: N(l.qty), unit: l.unit, unit_price: N(l.unit_price) }));
  if (!lines.length) return res.redirect(`/jobs/${job.id}?error=` + encodeURIComponent('Add lines to the working estimate before sending a quote.'));
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const net = r2(lines.reduce((a, l) => a + l.qty * l.unit_price, 0));
  const vatRate = s.vat_registered ? N(s.vat_rate) : 0;
  const vat = r2(net * vatRate / 100);
  const total = r2(net + vat);
  const deposit = r2(total * N(s.deposit_pct) / 100);
  const valid = new Date(Date.now() + N(s.quote_valid_days) * 86400000).toISOString().slice(0, 10);
  const layout = req.body.layout === 'summary' ? 'summary' : 'itemised';

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const prev = (await client.query("UPDATE quotes SET status = 'superseded' WHERE job_id = $1 AND status = 'sent' RETURNING id", [job.id])).rows.length;
    const { rows } = await client.query(
      `INSERT INTO quotes (job_id, layout, scope, customer_note, lines, net, vat_rate, vat, total, deposit_pct, deposit, valid_until, created_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) RETURNING id`,
      [job.id, layout, String(req.body.scope || '').trim().slice(0, 4000) || null, String(req.body.customer_note || '').trim().slice(0, 2000) || null,
        JSON.stringify(lines), net, vatRate, vat, total, N(s.deposit_pct), deposit, valid, req.user.id]);
    await setStatus(client, job.id, job.status, 'quoted', req.user.id, `${prev ? 'Updated quote' : 'Quote'} ${qref(rows[0].id)} sent`);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyStageChange(job.id, 'quoted', baseUrlOf(req));
  res.redirect(`/jobs/${job.id}?updated=1#quote`);
}));

// ---------- Accept / decline ----------
async function respond(req, res, accept) {
  const job = await loadJob(req);
  if (!job || !['admin', 'customer'].includes(req.user.role)) return notFound(req, res);
  const q = await currentQuote(job.id);
  if (!q || q.id !== Number(req.params.qid) || q.status !== 'sent' || job.status !== 'quoted') return res.redirect(`/jobs/${job.id}#quote`);
  if (q.valid_until && new Date(q.valid_until) < new Date(new Date().toDateString())) return res.redirect(`/jobs/${job.id}#quote`);
  const to = accept ? 'accepted' : 'declined';
  const reason = String(req.body.reason || '').trim().slice(0, 500) || null;
  const who = req.user.role === 'admin' ? 'by the office' : 'by the customer';
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE quotes SET status = $1, responded_at = now(), responded_by = $2, response_note = $3 WHERE id = $4',
      [to, req.user.id, reason, q.id]);
    await setStatus(client, job.id, job.status, to, req.user.id, `Quote ${qref(q.id)} ${to} ${who}${reason ? `: ${reason}` : ''}`);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyStageChange(job.id, to, baseUrlOf(req));
  res.redirect(`/jobs/${job.id}?updated=1#quote`);
}
router.post('/jobs/:id/quotes/:qid/accept', requireLogin, wrap((req, res) => respond(req, res, true)));
router.post('/jobs/:id/quotes/:qid/decline', requireLogin, wrap((req, res) => respond(req, res, false)));

// ---------- PDF ----------
router.get('/jobs/:id/quotes/:qid/pdf', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const q = (await query('SELECT * FROM quotes WHERE id = $1 AND job_id = $2', [Number(req.params.qid) || 0, job.id])).rows[0];
  if (!q || (req.user.role === 'customer' && q.status === 'superseded')) return notFound(req, res);
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const cust = (await query('SELECT name, email, phone FROM users WHERE id = $1', [job.customer_id])).rows[0];
  const m = (n) => money(n, s.currency);

  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `${req.query.download ? 'attachment' : 'inline'}; filename="${qref(q.id)}.pdf"`);
  const doc = new PDFDocument({ size: 'A4', margin: 50, bufferPages: true, info: { Title: `Quote ${qref(q.id)}`, Author: s.business_name } });
  doc.pipe(res);

  const W = doc.page.width;
  const L = 50;
  const R = W - 50;
  const ink = '#1d2529';
  const muted = '#5d6a70';

  // Header band
  doc.rect(0, 0, W, 86).fill('#24414f');
  doc.rect(0, 86, W, 6).fill('#f2c300');
  doc.fillColor('#ffffff').font('Helvetica-Bold').fontSize(22).text(s.business_name, L, 28, { width: 300 });
  const contact = [s.business_address, s.business_phone, s.business_email].filter(Boolean).join('\n');
  if (contact) doc.font('Helvetica').fontSize(9).text(contact, R - 220, 26, { width: 220, align: 'right' });

  // Title and details
  doc.fillColor(ink).font('Helvetica-Bold').fontSize(20).text('Quote', L, 115);
  const meta = [['Quote', qref(q.id)], ['Date', day(q.created_at)], ['Valid until', day(q.valid_until)], ['Job', ref(job.id)]];
  let my = 115;
  for (const [k, v] of meta) {
    doc.font('Helvetica').fontSize(9).fillColor(muted).text(k, R - 200, my, { width: 80 });
    doc.font('Helvetica-Bold').fillColor(ink).text(v, R - 120, my, { width: 120, align: 'right' });
    my += 14;
  }
  doc.font('Helvetica').fontSize(9).fillColor(muted).text('For', L, 150);
  doc.font('Helvetica-Bold').fontSize(11).fillColor(ink).text(cust.name, L, 162);
  doc.font('Helvetica').fontSize(10).text([job.address_line, job.town, job.postcode].filter(Boolean).join('\n'), L, doc.y + 2, { width: 260 });

  doc.y = Math.max(doc.y, my) + 22;
  doc.font('Helvetica-Bold').fontSize(13).text(job.title, L, doc.y, { width: R - L });
  if (q.scope) doc.moveDown(0.3).font('Helvetica').fontSize(10).fillColor(ink).text(q.scope, { width: R - L });
  doc.moveDown(1);

  // Table
  const itemised = q.layout === 'itemised';
  const cols = itemised
    ? [['Description', L, 245, 'left'], ['Qty', L + 250, 45, 'right'], ['Unit', L + 300, 45, 'left'], ['Price', L + 350, 70, 'right'], ['Total', R - 75, 75, 'right']]
    : [['Description', L, 360, 'left'], ['Total', R - 100, 100, 'right']];
  const header = () => {
    const y = doc.y;
    doc.rect(L, y - 4, R - L, 20).fill('#e9ecea');
    doc.fillColor(ink).font('Helvetica-Bold').fontSize(9);
    for (const [t, x, w, a] of cols) doc.text(t, x + 4, y + 2, { width: w - 8, align: a });
    doc.y = y + 22;
  };
  header();
  doc.font('Helvetica').fontSize(10);
  for (const r of displayLines(q)) {
    const vals = itemised ? [r.description, fmtQty(r.qty), r.unit, m(r.price), m(r.total)] : [r.description, m(r.total)];
    const h = Math.max(14, doc.heightOfString(r.description, { width: cols[0][2] - 8 }));
    if (doc.y + h > doc.page.height - 140) { doc.addPage(); doc.y = 60; header(); doc.font('Helvetica').fontSize(10); }
    const y = doc.y;
    cols.forEach(([, x, w, a], i) => doc.fillColor(ink).text(vals[i], x + 4, y, { width: w - 8, align: a }));
    doc.y = y + h + 6;
    doc.moveTo(L, doc.y - 3).lineTo(R, doc.y - 3).lineWidth(0.5).strokeColor('#c9d0cd').stroke();
  }

  // Totals
  if (doc.y > doc.page.height - 200) { doc.addPage(); doc.y = 60; }
  doc.moveDown(0.5);
  const tot = [['Net', m(q.net)]];
  if (N(q.vat)) tot.push([`VAT ${N(q.vat_rate)}%`, m(q.vat)]);
  tot.push(['Total', m(q.total)]);
  for (const [k, v] of tot) {
    const y = doc.y;
    const big = k === 'Total';
    if (big) doc.moveTo(R - 200, y - 2).lineTo(R, y - 2).lineWidth(1.2).strokeColor(ink).stroke();
    doc.font(big ? 'Helvetica-Bold' : 'Helvetica').fontSize(big ? 12 : 10).fillColor(ink);
    doc.text(k, R - 200, y + (big ? 3 : 0), { width: 100 });
    doc.text(v, R - 100, y + (big ? 3 : 0), { width: 100, align: 'right' });
    doc.y = y + (big ? 22 : 16);
  }
  if (N(q.deposit)) {
    doc.font('Helvetica').fontSize(10).fillColor(muted).text(`Deposit to book (${N(q.deposit_pct)}%): ${m(q.deposit)}`, R - 260, doc.y + 2, { width: 260, align: 'right' });
  }

  doc.x = L;
  doc.moveDown(1.5);
  if (q.customer_note) doc.font('Helvetica').fontSize(10).fillColor(ink).text(q.customer_note, L, doc.y, { width: R - L }).moveDown(1);
  if (q.status === 'sent') {
    doc.font('Helvetica-Bold').fontSize(10).fillColor(ink).text('To accept this quote', L, doc.y, { width: R - L });
    doc.font('Helvetica').fontSize(10).text(`Log in and open your job: ${baseUrlOf(req)}/jobs/${job.id}`, { width: R - L }).moveDown(1);
  } else if (q.status === 'accepted') {
    doc.font('Helvetica-Bold').fontSize(10).fillColor(ink).text(`Accepted ${day(q.responded_at)}`, L, doc.y).moveDown(1);
  }
  if (s.quote_terms) {
    doc.font('Helvetica-Bold').fontSize(9).fillColor(muted).text('Terms', L, doc.y, { width: R - L });
    doc.font('Helvetica').fontSize(8.5).text(s.quote_terms, { width: R - L });
  }

  // Page numbers
  const range = doc.bufferedPageRange();
  for (let i = 0; i < range.count; i++) {
    doc.switchToPage(range.start + i);
    const bottom = doc.page.margins.bottom;
    doc.page.margins.bottom = 0;
    doc.font('Helvetica').fontSize(8).fillColor(muted)
      .text(`${s.business_name}  |  ${qref(q.id)}  |  Page ${i + 1} of ${range.count}`, L, doc.page.height - 35, { width: R - L, align: 'center' });
    doc.page.margins.bottom = bottom;
  }
  doc.end();
}));

module.exports = { router, quotePanel, sendQuoteForm, currentQuote };
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
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange } = require('../notify');
const onsite = require('./onsite');
const quotes = require('./quotes');

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
  await notifyStageChange(jobId, estimate ? 'estimated' : status, baseUrlOf(req));
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
        <p class="hint">Saving re-prices travel from this builder’s home while the job is at estimate stage.</p>
        <button class="small">Save builder</button>
      </form>
      <form method="post" action="/jobs/${job.id}/status" class="panel">
        <label>Move to stage<select name="status">
          ${STATUSES.map(([k, l]) => `<option value="${k}" ${k === job.status ? 'selected' : ''}>${esc(l)}</option>`).join('')}
        </select></label>
        <label>Note for the office (optional)<input name="note" maxlength="500"></label>
        <p class="hint">The customer gets an email about the new stage. They never see this note.</p>
        <button class="small">Update stage</button>
      </form>
    </div>`;
  }

  const e = job.estimate_snapshot;
  const quote = await quotes.currentQuote(job.id);
  let estimatePanel = '';
  if (e && !(quote && user.role === 'customer')) {
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
  const error = req.query.photoerror || req.query.error ? String(req.query.photoerror || req.query.error).slice(0, 160) : null;

  const body = `
  <p class="jobhead"><span class="ref">${ref(job.id)}</span> <span class="tag">${esc(label(job.status))}</span>
    ${job.urgent ? '<span class="tag urgent">Urgent</span>' : ''}</p>
  ${await quotes.quotePanel(job, user)}
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
  ${await onsite.worksheetPanel(job, user)}
  <div id="time">${await onsite.timePanel(job, user)}</div>
  <h2>Photos</h2>
  ${photoGrid}
  ${addPhotos}
  ${actions}
  <h2>History</h2>
  <ol class="history">${history.map((h) => `<li><strong>${esc(label(h.to_status))}</strong> <span class="muted">${when(h.created_at)}${user.role !== 'customer' && h.by_name ? `, ${esc(h.by_name)}` : ''}</span>${user.role !== 'customer' && h.note ? `<br>${esc(h.note)}` : ''}</li>`).join('')}</ol>
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
    await notifyStageChange(job.id, 'cancelled', baseUrlOf(req));
  }
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

// ---------- Admin: recalculate estimate ----------
const REPRICE_STAGES = ['request', 'estimated', 'inspection_required', 'inspection_booked', 'inspected'];

async function refreshEstimate(job, builderId, userId, baseUrl) {
  if (!job.template_id) return;
  const est = await calculateEstimate({
    templateId: job.template_id, quantity: job.quantity, accessIds: job.access_option_ids || [],
    postcode: job.postcode, urgent: job.urgent, builderId,
  });
  if (!est) return;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE jobs SET estimate_low = $1, estimate_high = $2, estimate_snapshot = $3, updated_at = now() WHERE id = $4',
      [est.low, est.high, JSON.stringify(est), job.id]);
    if (job.status === 'request') await setStatus(client, job.id, 'request', 'estimated', userId, 'Price guide worked out');
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  if (job.status === 'request') await notifyStageChange(job.id, 'estimated', baseUrl);
}

router.post('/jobs/:id/estimate', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  await refreshEstimate(job, job.assigned_builder_id, req.user.id, baseUrlOf(req));
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
  // Travel now comes from this builder's home, so re-price while the job is still at estimate stage.
  if (job.estimate_snapshot && REPRICE_STAGES.includes(job.status)) await refreshEstimate(job, builderId, req.user.id, baseUrlOf(req));
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

router.post('/jobs/:id/status', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const to = String(req.body.status || '');
  if (to === 'quoted' && !(await quotes.currentQuote(job.id))) {
    return res.redirect(`/jobs/${job.id}?error=` + encodeURIComponent('Use “Send quote” under the working estimate, so the customer has a quote to see.'));
  }
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
    await notifyStageChange(job.id, to, baseUrlOf(req));
  }
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

module.exports = router;
HANDYTRIO_EOF

cat > src/routes/onsite.js <<'HANDYTRIO_EOF'
// Behind-the-scenes tools for the office and builders: the working estimate (worksheet) and time tracking.
// Customers never see any of this.
const express = require('express');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { when } = require('../format');
const { money } = require('../estimate');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange } = require('../notify');
const { sendQuoteForm } = require('./quotes');

const router = express.Router();
const staff = requireRole('admin', 'builder');

const N = (x) => Number(x) || 0;
const r2 = (n) => Math.round(n * 100) / 100;
const CATS = { materials: 'Materials', labour: 'Labour', travel: 'Travel', other: 'Other' };
const BLANK_ROWS = 3;
const PRE_INSPECTION = ['request', 'estimated', 'inspection_required', 'inspection_booked'];

async function loadLines(jobId) {
  return (await query('SELECT * FROM job_estimate_lines WHERE job_id = $1 ORDER BY sort, id', [jobId])).rows;
}

async function worksheetTotals(lines) {
  const s = (await query('SELECT vat_registered, vat_rate, currency FROM settings WHERE id = 1')).rows[0];
  const byCat = {};
  let net = 0;
  for (const l of lines) {
    const t = r2(N(l.qty) * N(l.unit_price));
    byCat[l.category] = r2((byCat[l.category] || 0) + t);
    net += t;
  }
  net = r2(net);
  const vat = s.vat_registered ? r2(net * N(s.vat_rate) / 100) : 0;
  const labourHours = r2(lines.filter((l) => l.category === 'labour' && /^h(ou)?rs?$/i.test(l.unit || '')).reduce((a, l) => a + N(l.qty), 0));
  return { byCat, net, vat, vatRate: s.vat_registered ? N(s.vat_rate) : 0, total: r2(net + vat), currency: s.currency, labourHours };
}

// Turns the automatic estimate into editable lines that add up to the same net figure.
function linesFromSnapshot(e) {
  const lines = [];
  const markup = e.materials.included ? 0 : N(e.materials.markupPct) / 100;
  for (const m of e.materials.lines) {
    if (!N(m.qty)) continue;
    lines.push({ category: 'materials', description: m.name, qty: m.qty, unit: m.unit, unit_price: r2(m.price * (1 + markup)) });
  }
  if (e.labour.qty !== undefined) {
    lines.push({ category: 'labour', description: 'Labour', qty: e.labour.qty, unit: e.labour.unit, unit_price: e.labour.rate });
  } else {
    lines.push({ category: 'labour', description: 'Labour', qty: 1, unit: 'job', unit_price: e.labour.base });
  }
  if (e.labour.urgentPremium) lines.push({ category: 'labour', description: 'Urgent premium', qty: 1, unit: 'job', unit_price: e.labour.urgentPremium });
  if (e.travel.mileage) lines.push({ category: 'travel', description: `Mileage, ${e.travel.oneWayMiles} miles each way × ${e.travel.visits}`, qty: 1, unit: 'job', unit_price: e.travel.mileage });
  if (e.travel.time) lines.push({ category: 'travel', description: 'Travel time', qty: 1, unit: 'job', unit_price: e.travel.time });
  if (e.contingency) lines.push({ category: 'other', description: `Contingency ${e.contingencyPct}%`, qty: 1, unit: 'job', unit_price: e.contingency });
  if (e.minimumApplied) {
    const sum = lines.reduce((a, l) => a + N(l.qty) * N(l.unit_price), 0);
    const topUp = r2(N(e.net) - sum);
    if (topUp > 0) lines.push({ category: 'other', description: 'Minimum charge top-up', qty: 1, unit: 'job', unit_price: topUp });
  }
  return lines;
}

async function replaceLines(client, jobId, lines, userId, notes) {
  await client.query('DELETE FROM job_estimate_lines WHERE job_id = $1', [jobId]);
  let i = 0;
  for (const l of lines) {
    await client.query(
      'INSERT INTO job_estimate_lines (job_id, category, description, qty, unit, unit_price, sort) VALUES ($1, $2, $3, $4, $5, $6, $7)',
      [jobId, l.category, l.description, l.qty, l.unit || null, l.unit_price, i++]);
  }
  await client.query('UPDATE jobs SET worksheet_updated_at = now(), worksheet_updated_by = $1, worksheet_notes = coalesce($2, worksheet_notes), updated_at = now() WHERE id = $3',
    [userId, notes, jobId]);
}

// ---------------- Panels shown on the job page ----------------
async function worksheetPanel(job, user) {
  if (user.role === 'customer') return '';
  const lines = await loadLines(job.id);
  if (!lines.length) {
    return `<section class="panel staffonly">
      <h2>Working estimate <span class="tag">Office and builders only</span></h2>
      <p>Adjust the price on site or afterwards. This becomes the quote.</p>
      <div class="buttons">
        ${job.estimate_snapshot ? `<form method="post" action="/jobs/${job.id}/worksheet/from-estimate" class="inline"><button class="primary">Start from the price guide</button></form>` : ''}
        <a class="button" href="/jobs/${job.id}/worksheet">Start blank</a>
      </div>
    </section>`;
  }
  const t = await worksheetTotals(lines);
  const m = (n) => money(n, t.currency);
  const by = job.worksheet_updated_by ? (await query('SELECT name FROM users WHERE id = $1', [job.worksheet_updated_by])).rows[0] : null;
  return `<section class="panel staffonly">
    <h2>Working estimate <span class="tag">Office and builders only</span></h2>
    <p class="bigprice">${m(t.total)}${t.vat ? ' <span class="muted small">incl. VAT</span>' : ''}</p>
    <p class="muted">${Object.entries(CATS).filter(([k]) => t.byCat[k]).map(([k, l]) => `${l} ${m(t.byCat[k])}`).join(' · ')}</p>
    <p class="muted">Last updated ${when(job.worksheet_updated_at)}${by ? ` by ${esc(by.name)}` : ''}.</p>
    <a class="button primary" href="/jobs/${job.id}/worksheet">Edit working estimate</a>
    ${await sendQuoteForm(job, user)}
  </section>`;
}

async function timePanel(job, user) {
  if (user.role === 'customer') return '';
  const entries = (await query(
    `SELECT t.*, u.name FROM job_time_entries t JOIN users u ON u.id = t.user_id WHERE t.job_id = $1 ORDER BY t.started_at DESC`, [job.id])).rows;
  const mine = entries.find((e) => e.user_id === user.id && !e.ended_at);
  const elsewhere = !mine && (await query(
    `SELECT t.job_id FROM job_time_entries t WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
  const hrs = (a, b) => (new Date(b || Date.now()) - new Date(a)) / 3600000;
  const fmt = (h) => `${Math.floor(h)}h ${String(Math.round((h % 1) * 60)).padStart(2, '0')}m`;
  const actual = entries.reduce((a, e) => a + hrs(e.started_at, e.ended_at), 0);

  const lines = await loadLines(job.id);
  const wsHours = lines.length ? (await worksheetTotals(lines)).labourHours : 0;
  const autoHours = job.estimate_snapshot && job.estimate_snapshot.labour ? job.estimate_snapshot.labour.estimatedHours : null;
  const estHours = wsHours || autoHours;

  const canClock = user.role === 'admin' || job.assigned_builder_id === user.id;
  const clock = !canClock ? '' : mine
    ? `<form method="post" action="/jobs/${job.id}/clock-off" class="clock on">
        <p><strong>Clocked on</strong> since ${when(mine.started_at)} (${fmt(hrs(mine.started_at))})</p>
        <label>What did you do? (optional)<input name="note" maxlength="300"></label>
        <button class="primary">Clock off</button>
      </form>`
    : `<form method="post" action="/jobs/${job.id}/clock-on" class="clock">
        ${elsewhere ? `<p class="hint">You’re clocked on to another job. Clocking on here will clock you off there.</p>` : ''}
        <button class="primary">Clock on to this job</button>
      </form>`;

  return `<section class="panel staffonly">
    <h2>Time on this job <span class="tag">Office and builders only</span></h2>
    ${clock}
    <p>Actual so far: <strong>${fmt(actual)}</strong>${estHours ? ` against ${estHours} hrs estimated` : ''}${estHours && actual > estHours ? ' <span class="tag urgent">Over estimate</span>' : ''}</p>
    ${entries.length ? `<div class="scroll"><table>
      <thead><tr><th>Who</th><th>Started</th><th>Finished</th><th>Time</th><th>Note</th>${user.role === 'admin' ? '<th></th>' : ''}</tr></thead>
      <tbody>${entries.map((e) => `<tr>
        <td>${esc(e.name)}</td><td>${when(e.started_at)}</td><td>${e.ended_at ? when(e.ended_at) : '<span class="tag">Running</span>'}</td>
        <td>${fmt(hrs(e.started_at, e.ended_at))}</td><td>${esc(e.note)}</td>
        ${user.role === 'admin' ? `<td><form method="post" action="/jobs/${job.id}/time/${e.id}/delete" class="inline"><button class="small">Delete</button></form></td>` : ''}
      </tr>`).join('')}</tbody></table></div>` : '<p class="empty">No time recorded yet.</p>'}
  </section>`;
}

// ---------------- Time tracking ----------------
const mayWork = (user, job) => user.role === 'admin' || job.assigned_builder_id === user.id;

router.post('/jobs/:id/clock-on', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(
      `UPDATE job_time_entries SET ended_at = now(), note = coalesce(note, 'Clocked off automatically when clocking on to another job')
       WHERE user_id = $1 AND ended_at IS NULL`, [req.user.id]);
    await client.query('INSERT INTO job_time_entries (job_id, user_id) VALUES ($1, $2)', [job.id, req.user.id]);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  res.redirect(`/jobs/${job.id}#time`);
}));

router.post('/jobs/:id/clock-off', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const note = String(req.body.note || '').trim().slice(0, 300) || null;
  await query('UPDATE job_time_entries SET ended_at = now(), note = coalesce($1, note) WHERE job_id = $2 AND user_id = $3 AND ended_at IS NULL',
    [note, job.id, req.user.id]);
  res.redirect(`/jobs/${job.id}#time`);
}));

router.post('/jobs/:id/time/:eid/delete', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  await query('DELETE FROM job_time_entries WHERE id = $1 AND job_id = $2', [Number(req.params.eid) || 0, job.id]);
  res.redirect(`/jobs/${job.id}#time`);
}));

// ---------------- Worksheet (working estimate) ----------------
function lineRow(i, l = {}) {
  const isNew = !l.description;
  return `<div class="wline ${isNew ? 'new' : ''}">
    <label>Type<select name="l${i}_cat">${Object.entries(CATS).map(([k, v]) => `<option value="${k}" ${k === (l.category || 'materials') ? 'selected' : ''}>${v}</option>`).join('')}</select></label>
    <label class="desc">Description<input name="l${i}_desc" value="${esc(l.description)}" maxlength="200" ${isNew ? 'placeholder="Add a line"' : ''}></label>
    <label>Qty<input name="l${i}_qty" type="number" step="0.01" min="0" value="${esc(l.qty ?? '')}"></label>
    <label>Unit<input name="l${i}_unit" value="${esc(l.unit)}" maxlength="20"></label>
    <label>Price each<input name="l${i}_price" type="number" step="0.01" min="0" value="${esc(l.unit_price ?? '')}"></label>
    <span class="ltotal">${isNew ? '' : money(N(l.qty) * N(l.unit_price), '£')}</span>
    ${isNew ? '<span></span>' : `<label class="check del"><input type="checkbox" name="l${i}_del"> Remove</label>`}
  </div>`;
}

router.get('/jobs/:id/worksheet', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const lines = await loadLines(job.id);
  const t = await worksheetTotals(lines);
  const m = (n) => money(n, t.currency);
  const items = (await query(
    `SELECT p.id, p.name, p.unit, p.price, s.name AS supplier FROM price_items p LEFT JOIN suppliers s ON s.id = p.supplier_id WHERE p.active ORDER BY p.name`)).rows;
  const count = lines.length + BLANK_ROWS;

  const body = `
  <p class="jobhead"><a href="/jobs/${job.id}">Back to the job</a></p>
  <p class="lead">Prices here are what the customer pays, before VAT. Change anything you find on site. This becomes the quote.</p>
  <form method="post" action="/jobs/${job.id}/worksheet" class="worksheet">
    <input type="hidden" name="count" value="${count}">
    ${lines.map((l, i) => lineRow(i, l)).join('')}
    ${Array.from({ length: BLANK_ROWS }, (_, k) => lineRow(lines.length + k)).join('')}
    <div class="wtotals panel">
      ${Object.entries(CATS).filter(([k]) => t.byCat[k]).map(([k, l]) => `<div><span>${l}</span><span>${m(t.byCat[k])}</span></div>`).join('')}
      <div class="sum"><span>Net</span><span>${m(t.net)}</span></div>
      ${t.vat ? `<div><span>VAT ${t.vatRate}%</span><span>${m(t.vat)}</span></div>` : ''}
      <div class="grand"><span>Total</span><span>${m(t.total)}</span></div>
      <p class="hint">Totals update when you save.</p>
    </div>
    <label>Notes for the office (never shown to the customer)<textarea name="notes" rows="3" maxlength="2000">${esc(job.worksheet_notes)}</textarea></label>
    ${PRE_INSPECTION.includes(job.status) ? '<label class="check"><input type="checkbox" name="mark_inspected"> I’ve inspected the job (moves it to Inspected and emails the customer)</label>' : ''}
    <button class="primary">Save working estimate</button>
  </form>

  <div class="twocol">
    <section>
      <h2>Add from the price list</h2>
      ${items.length ? `<form method="post" action="/jobs/${job.id}/worksheet/add-item" class="panel">
        <label>Item<select name="price_item_id">${items.map((p) => `<option value="${p.id}">${esc(p.name)} (${esc(p.unit)}, ${m(p.price)} cost${p.supplier ? `, ${esc(p.supplier)}` : ''})</option>`).join('')}</select></label>
        <label>Quantity<input name="qty" type="number" step="0.01" min="0.01" value="1" required></label>
        <p class="hint">Added at your markup. Save any changes above first.</p>
        <button class="small">Add item</button>
      </form>` : '<p class="empty">The price list is empty.</p>'}
    </section>
    ${job.estimate_snapshot ? `<section>
      <h2>Start again</h2>
      <form method="post" action="/jobs/${job.id}/worksheet/from-estimate" class="panel">
        <p>Replace every line with the automatic price guide.</p>
        <label class="check"><input type="checkbox" name="confirm" required> Yes, replace all lines</label>
        <button class="small danger">Replace lines</button>
      </form>
    </section>` : ''}
  </div>`;
  res.send(page({ title: `Working estimate: ${job.title}`, user: req.user, notice: req.query.saved ? 'Working estimate saved.' : null, body }));
}));

router.post('/jobs/:id/worksheet', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const count = Math.min(Number(req.body.count) || 0, 300);
  const lines = [];
  for (let i = 0; i < count; i++) {
    if (req.body[`l${i}_del`] === 'on') continue;
    const description = String(req.body[`l${i}_desc`] || '').trim().slice(0, 200);
    if (!description) continue;
    const qty = Math.max(0, N(req.body[`l${i}_qty`]));
    const unitPrice = Math.max(0, N(req.body[`l${i}_price`]));
    const category = CATS[req.body[`l${i}_cat`]] ? req.body[`l${i}_cat`] : 'other';
    lines.push({ category, description, qty: String(req.body[`l${i}_qty`] || '').trim() === '' ? 1 : qty, unit: String(req.body[`l${i}_unit`] || '').trim().slice(0, 20), unit_price: unitPrice });
  }
  const notes = String(req.body.notes ?? '').trim().slice(0, 2000);
  const inspect = req.body.mark_inspected === 'on' && PRE_INSPECTION.includes(job.status);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await replaceLines(client, job.id, lines, req.user.id, notes);
    if (inspect) await setStatus(client, job.id, job.status, 'inspected', req.user.id, 'Inspected on site');
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  if (inspect) await notifyStageChange(job.id, 'inspected', baseUrlOf(req));
  res.redirect(`/jobs/${job.id}/worksheet?saved=1`);
}));

router.post('/jobs/:id/worksheet/from-estimate', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  if (!job.estimate_snapshot) return res.redirect(`/jobs/${job.id}/worksheet`);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await replaceLines(client, job.id, linesFromSnapshot(job.estimate_snapshot), req.user.id, null);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  res.redirect(`/jobs/${job.id}/worksheet?saved=1`);
}));

router.post('/jobs/:id/worksheet/add-item', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const item = (await query('SELECT name, unit, price FROM price_items WHERE id = $1', [Number(req.body.price_item_id) || 0])).rows[0];
  const qty = N(req.body.qty);
  if (item && qty > 0) {
    const s = (await query('SELECT markup_pct FROM settings WHERE id = 1')).rows[0];
    const sort = (await query('SELECT coalesce(max(sort), 0) + 1 AS n FROM job_estimate_lines WHERE job_id = $1', [job.id])).rows[0].n;
    await query(
      `INSERT INTO job_estimate_lines (job_id, category, description, qty, unit, unit_price, sort) VALUES ($1, 'materials', $2, $3, $4, $5, $6)`,
      [job.id, item.name, qty, item.unit, r2(N(item.price) * (1 + N(s.markup_pct) / 100)), sort]);
    await query('UPDATE jobs SET worksheet_updated_at = now(), worksheet_updated_by = $1 WHERE id = $2', [req.user.id, job.id]);
  }
  res.redirect(`/jobs/${job.id}/worksheet?saved=1`);
}));

module.exports = { router, worksheetPanel, timePanel };
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
    ['base_postcode', 'Base postcode (used for travel only when no builder has a home postcode)', 'text'],
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
  ['Quotes and documents', [
    ['business_address', 'Business address (shown on quotes)', 'textarea'],
    ['business_phone', 'Business phone', 'text'],
    ['business_email', 'Business email', 'text'],
    ['quote_valid_days', 'Quotes valid for (days)', 'int', '1'],
    ['quote_terms', 'Terms printed on quotes', 'textarea'],
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
      : type === 'textarea'
      ? `<label>${esc(lbl)}<textarea name="${key}" rows="3" maxlength="2000">${esc(s[key])}</textarea></label>`
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
    else if (type === 'text' || type === 'textarea') values.push(String(raw || '').replace(/\r\n/g, '\n').trim().slice(0, 2000));
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

/* Stage 3b: worksheets, time, emails */
.staffonly { border-left: 6px solid var(--slate); }
.staffonly h2 { margin-top: 0; display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; }
.staffonly h2 .tag { font: 500 .8rem Barlow, sans-serif; }
.small { font-size: .9rem; }
.buttons { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; }
.clock { display: flex; flex-wrap: wrap; gap: .75rem; align-items: end; margin-bottom: .75rem; }
.clock p { margin: 0; flex-basis: 100%; }
.clock label { margin: 0; flex: 1 1 220px; }
.clock.on { background: var(--ok-bg); color: var(--ok-ink); padding: .75rem; border-radius: 4px; }
.clock.on input { background: var(--surface); color: var(--ink); }

.worksheet { max-width: 1000px; }
.wline { display: grid; grid-template-columns: 120px 1fr 80px 80px 100px 90px 90px; gap: .5rem; align-items: end; padding: .5rem 0; border-bottom: 1px solid var(--line); }
.wline label { margin: 0; font-size: .85rem; }
.wline.new { opacity: .8; }
.wline .ltotal { text-align: right; padding-bottom: .6rem; font-weight: 600; }
.wline .del { padding-bottom: .55rem; }
.wtotals { max-width: 360px; margin: 1rem 0 1rem auto; }
.wtotals div { display: flex; justify-content: space-between; padding: .2rem 0; }
.wtotals .sum { border-top: 1px solid var(--line); font-weight: 600; margin-top: .3rem; padding-top: .4rem; }
.wtotals .grand { font-weight: 700; font-size: 1.15rem; border-top: 2px solid var(--ink); margin-top: .3rem; padding-top: .4rem; }

.emailtpl summary { cursor: pointer; display: flex; flex-wrap: wrap; gap: .5rem; align-items: baseline; }
.emailtpl form { margin-top: 1rem; }
.preview { white-space: pre-wrap; background: var(--bg); border: 1px solid var(--line); border-radius: 4px; padding: .75rem 1rem; font-size: .95rem; }
code { background: var(--bg); padding: 0 .3rem; border-radius: 3px; font-size: .9em; }

@media (max-width: 760px) {
  .wline { grid-template-columns: 1fr 1fr 1fr; }
  .wline .desc { grid-column: 1 / -1; grid-row: 1; }
  .wline .ltotal { text-align: left; }
}

/* Stage 4: quotes */
.quote { border-top: 6px solid var(--hivis); }
.quotehead { display: flex; flex-wrap: wrap; gap: .75rem; align-items: center; justify-content: space-between; }
.quotehead h2 { margin: 0; }
.quote h3 { font: 600 1.1rem "Barlow Condensed", Barlow, sans-serif; margin: 1rem 0 .3rem; }
.quote .wtotals { margin: 1rem 0 1rem auto; }
.quotetable td { white-space: normal; }
.tag.ok { background: var(--ok-bg); color: var(--ok-ink); border-color: transparent; }
.respond { display: flex; flex-wrap: wrap; gap: 1rem; align-items: start; margin-top: 1rem; padding-top: 1rem; border-top: 1px solid var(--line); }
.respond details summary { cursor: pointer; padding: .6rem 0; color: var(--muted); }
.sendquote { margin: 1rem 0 0; background: var(--bg); }
.sendquote summary { cursor: pointer; }
.sendquote form { margin-top: 1rem; }
HANDYTRIO_EOF

echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "Quotes installed. The app restarts by itself; otherwise run: npm run dev"
