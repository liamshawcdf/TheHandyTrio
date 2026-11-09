#!/usr/bin/env bash
# TheHandyTrio stage 5: deposits, parts, booking, builder route, completion, invoices and payments. Run with: bash payments.sh
set -e
if [ ! -f package.json ]; then echo "Run this inside the TheHandyTrio folder"; exit 1; fi
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

-- Stage 5: deposits, parts, scheduling, completion, invoices and payments
ALTER TABLE settings ADD COLUMN IF NOT EXISTS bank_details text NOT NULL DEFAULT '';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS payment_instructions text NOT NULL DEFAULT 'You can pay by bank transfer, or call us to pay by card over the phone. Please use your job reference as the payment reference.';
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS address text;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS postcode text;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS scheduled_start date;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS scheduled_end date;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS completion_note text;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS completed_at timestamptz;

CREATE TABLE IF NOT EXISTS invoices (
  id         serial PRIMARY KEY,
  job_id     int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  kind       text NOT NULL CHECK (kind IN ('deposit','final')),
  quote_id   int REFERENCES quotes(id),
  layout     text NOT NULL DEFAULT 'itemised',
  lines      jsonb NOT NULL,
  net        numeric NOT NULL,
  vat_rate   numeric NOT NULL DEFAULT 0,
  vat        numeric NOT NULL DEFAULT 0,
  total      numeric NOT NULL,
  less_paid  numeric NOT NULL DEFAULT 0,
  amount_due numeric NOT NULL,
  due_date   date,
  status     text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued','paid','void')),
  note       text,
  created_by int REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  paid_at    timestamptz
);
CREATE INDEX IF NOT EXISTS invoices_job_idx ON invoices (job_id);

CREATE TABLE IF NOT EXISTS payments (
  id                serial PRIMARY KEY,
  job_id            int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  invoice_id        int REFERENCES invoices(id),
  amount            numeric NOT NULL CHECK (amount > 0),
  method            text NOT NULL,
  reference         text,
  stripe_session_id text UNIQUE,
  received_at       timestamptz NOT NULL DEFAULT now(),
  recorded_by       int REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS payments_job_idx ON payments (job_id);

CREATE TABLE IF NOT EXISTS job_parts (
  id          serial PRIMARY KEY,
  job_id      int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  description text NOT NULL,
  qty         numeric NOT NULL DEFAULT 1,
  unit        text,
  supplier_id int REFERENCES suppliers(id),
  status      text NOT NULL DEFAULT 'to_order' CHECK (status IN ('to_order','ordered','ready','collected','delivered')),
  note        text,
  sort        int NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS job_parts_job_idx ON job_parts (job_id);
HANDYTRIO_EOF

cat > src/pdf.js <<'HANDYTRIO_EOF'
// Branded A4 documents (quotes and invoices) with page numbers.
const PDFDocument = require('pdfkit');

/*
  opts: { res, download, filename, s (settings), title, meta: [[label, value]], customer: {name, lines},
          heading, intro, itemised, rows: [{description, qty, unit, price, total}], money,
          totals: [[label, value, bold?]], afterTotals: [text], blocks: [{title, text}] }
*/
function renderDocument(opts) {
  const { res, s, money: m } = opts;
  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `${opts.download ? 'attachment' : 'inline'}; filename="${opts.filename}"`);
  const doc = new PDFDocument({ size: 'A4', margin: 50, bufferPages: true, info: { Title: `${opts.title} ${opts.filename}`, Author: s.business_name } });
  doc.pipe(res);

  const W = doc.page.width;
  const L = 50;
  const R = W - 50;
  const ink = '#1d2529';
  const muted = '#5d6a70';

  doc.rect(0, 0, W, 86).fill('#24414f');
  doc.rect(0, 86, W, 6).fill('#f2c300');
  doc.fillColor('#ffffff').font('Helvetica-Bold').fontSize(22).text(s.business_name, L, 28, { width: 300 });
  const contact = [s.business_address, s.business_phone, s.business_email].filter(Boolean).join('\n');
  if (contact) doc.font('Helvetica').fontSize(9).text(contact, R - 220, 26, { width: 220, align: 'right' });

  doc.fillColor(ink).font('Helvetica-Bold').fontSize(20).text(opts.title, L, 115);
  let my = 115;
  for (const [k, v] of opts.meta) {
    doc.font('Helvetica').fontSize(9).fillColor(muted).text(k, R - 200, my, { width: 80 });
    doc.font('Helvetica-Bold').fillColor(ink).text(String(v ?? ''), R - 120, my, { width: 120, align: 'right' });
    my += 14;
  }
  doc.font('Helvetica').fontSize(9).fillColor(muted).text('For', L, 150);
  doc.font('Helvetica-Bold').fontSize(11).fillColor(ink).text(opts.customer.name, L, 162);
  doc.font('Helvetica').fontSize(10).text(opts.customer.lines.filter(Boolean).join('\n'), L, doc.y + 2, { width: 260 });

  doc.y = Math.max(doc.y, my) + 22;
  doc.font('Helvetica-Bold').fontSize(13).fillColor(ink).text(opts.heading, L, doc.y, { width: R - L });
  if (opts.intro) doc.moveDown(0.3).font('Helvetica').fontSize(10).text(opts.intro, { width: R - L });
  doc.moveDown(1);

  const cols = opts.itemised
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
  const q = (n) => (n === null || n === undefined ? '' : String(Math.round(n * 100) / 100));
  for (const r of opts.rows) {
    const vals = opts.itemised ? [r.description, q(r.qty), r.unit || '', r.price === null ? '' : m(r.price), m(r.total)] : [r.description, m(r.total)];
    const h = Math.max(14, doc.heightOfString(r.description, { width: cols[0][2] - 8 }));
    if (doc.y + h > doc.page.height - 140) { doc.addPage(); doc.y = 60; header(); doc.font('Helvetica').fontSize(10); }
    const y = doc.y;
    cols.forEach(([, x, w, a], i) => doc.fillColor(ink).text(vals[i], x + 4, y, { width: w - 8, align: a }));
    doc.y = y + h + 6;
    doc.moveTo(L, doc.y - 3).lineTo(R, doc.y - 3).lineWidth(0.5).strokeColor('#c9d0cd').stroke();
  }

  if (doc.y > doc.page.height - 220) { doc.addPage(); doc.y = 60; }
  doc.moveDown(0.5);
  for (const [k, v, bold] of opts.totals) {
    const y = doc.y;
    if (bold) doc.moveTo(R - 220, y - 2).lineTo(R, y - 2).lineWidth(1.2).strokeColor(ink).stroke();
    doc.font(bold ? 'Helvetica-Bold' : 'Helvetica').fontSize(bold ? 12 : 10).fillColor(ink);
    doc.text(k, R - 220, y + (bold ? 3 : 0), { width: 120 });
    doc.text(v, R - 100, y + (bold ? 3 : 0), { width: 100, align: 'right' });
    doc.y = y + (bold ? 22 : 16);
  }
  for (const t of opts.afterTotals || []) {
    doc.font('Helvetica').fontSize(10).fillColor(muted).text(t, R - 300, doc.y + 2, { width: 300, align: 'right' });
  }

  doc.x = L;
  doc.moveDown(1.5);
  for (const b of opts.blocks || []) {
    if (!b.text) continue;
    if (doc.y > doc.page.height - 120) { doc.addPage(); doc.y = 60; }
    if (b.title) doc.font('Helvetica-Bold').fontSize(b.small ? 9 : 10).fillColor(b.small ? muted : ink).text(b.title, L, doc.y, { width: R - L });
    doc.font('Helvetica').fontSize(b.small ? 8.5 : 10).fillColor(b.small ? muted : ink).text(b.text, L, doc.y, { width: R - L });
    doc.moveDown(1);
  }

  const range = doc.bufferedPageRange();
  for (let i = 0; i < range.count; i++) {
    doc.switchToPage(range.start + i);
    const bottom = doc.page.margins.bottom;
    doc.page.margins.bottom = 0;
    doc.font('Helvetica').fontSize(8).fillColor(muted)
      .text(`${s.business_name}  |  ${opts.filename.replace(/\.pdf$/, '')}  |  Page ${i + 1} of ${range.count}`, L, doc.page.height - 35, { width: R - L, align: 'center' });
    doc.page.margins.bottom = bottom;
  }
  doc.end();
}

module.exports = { renderDocument };
HANDYTRIO_EOF

cat > src/notify.js <<'HANDYTRIO_EOF'
// Customer emails. Sends through SMTP when it is set up in .env, and logs every email either way.
const nodemailer = require('nodemailer');
const { query } = require('./db');
const { label } = require('./statuses');
const { ref } = require('./format');
const { customerSummary } = require('./estimate');

let transport;
function getTransport() {
  if (transport !== undefined) return transport;
  if (!process.env.SMTP_HOST) {
    transport = null;
    return transport;
  }
  const port = Number(process.env.SMTP_PORT || 587);
  transport = nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port,
    secure: port === 465,
    auth: process.env.SMTP_USER ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS } : undefined,
  });
  return transport;
}

const emailReady = () => Boolean(process.env.SMTP_HOST);
const fill = (text, vars) => String(text).replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k] ?? '') : m));

async function sendEmail({ to, subject, body, jobId = null }) {
  const t = getTransport();
  let status = 'sent';
  let error = null;
  if (!to) {
    status = 'skipped';
    error = 'No email address';
  } else if (!t) {
    status = 'not sent';
    error = 'Email sending is not set up yet';
  } else {
    try {
      await t.sendMail({ from: process.env.SMTP_FROM || process.env.SMTP_USER, to, subject, text: body });
    } catch (e) {
      status = 'failed';
      error = String(e.message || e).slice(0, 300);
    }
  }
  await query('INSERT INTO email_log (job_id, to_address, subject, body, status, error) VALUES ($1, $2, $3, $4, $5, $6)',
    [jobId, to || null, subject, body, status, error]);
  return { status, error };
}

async function jobVars(jobId, status, baseUrl) {
  const job = (await query(
    'SELECT j.*, c.name AS customer_name, c.email AS customer_email FROM jobs j JOIN users c ON c.id = j.customer_id WHERE j.id = $1',
    [jobId])).rows[0];
  if (!job) return null;
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  return {
    job,
    vars: {
      customer_name: job.customer_name,
      first_name: String(job.customer_name || '').split(' ')[0],
      job_ref: ref(job.id),
      job_title: job.title,
      stage: label(status),
      price_guide: job.estimate_snapshot ? customerSummary(job.estimate_snapshot) : 'to be confirmed',
      job_link: `${baseUrl}/jobs/${job.id}`,
      business_name: s.business_name,
    },
  };
}

// Never throws: a failed email must not stop the job being updated.
async function notifyStageChange(jobId, status, baseUrl) {
  try {
    const tpl = (await query('SELECT * FROM email_templates WHERE status = $1', [status])).rows[0];
    if (!tpl || !tpl.enabled) return;
    const data = await jobVars(jobId, status, baseUrl);
    if (!data) return;
    await sendEmail({ to: data.job.customer_email, subject: fill(tpl.subject, data.vars), body: fill(tpl.body, data.vars), jobId });
  } catch (e) {
    console.error('Customer email failed:', e);
  }
}

// Lets the office know something needs doing. Goes to the business email in Settings.
async function notifyOffice(subject, body, jobId = null) {
  try {
    const s = (await query('SELECT business_email FROM settings WHERE id = 1')).rows[0];
    if (!s.business_email) return;
    await sendEmail({ to: s.business_email, subject: `[TheHandyTrio] ${subject}`, body, jobId });
  } catch (e) {
    console.error('Office email failed:', e);
  }
}

const PLACEHOLDERS = ['first_name', 'customer_name', 'job_ref', 'job_title', 'stage', 'price_guide', 'job_link', 'business_name'];

module.exports = { notifyStageChange, notifyOffice, sendEmail, fill, emailReady, PLACEHOLDERS };
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
app.use(require('./routes/workflow').router);
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

cat > src/routes/workflow.js <<'HANDYTRIO_EOF'
// Everything after a quote is accepted: deposit, parts, scheduling, the builder's route,
// completion, the final invoice and payments (recorded by the office or paid online with Stripe).
const express = require('express');
const { pool, query } = require('../db');
const { esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day, when } = require('../format');
const { money } = require('../estimate');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange, notifyOffice } = require('../notify');
const { currentQuote, displayLines, qref } = require('./quotes');
const { renderDocument } = require('../pdf');

const router = express.Router();
const admin = requireRole('admin');
const staff = requireRole('admin', 'builder');
const N = (x) => Number(x) || 0;
const r2 = (n) => Math.round(n * 100) / 100;
const iref = (id) => 'INV-' + String(id).padStart(5, '0');
const todayISO = () => new Date().toISOString().slice(0, 10);
const isDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d || '') && !Number.isNaN(Date.parse(d));
const settings = async () => (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
const mayWork = (user, job) => user.role === 'admin' || (user.role === 'builder' && job.assigned_builder_id === user.id);
const stripeReady = () => Boolean(process.env.STRIPE_SECRET_KEY);
const back = (res, job, hash = '', msg = 'updated=1') => res.redirect(`/jobs/${job.id}?${msg}${hash}`);
const errorBack = (res, job, text, hash = '') => res.redirect(`/jobs/${job.id}?error=${encodeURIComponent(text)}${hash}`);

const ORDER = ['accepted', 'deposit_requested', 'deposit_paid', 'parts_ordered', 'scheduled', 'in_progress', 'complete', 'invoiced', 'paid'];
const before = (status, target) => ORDER.indexOf(status) !== -1 && ORDER.indexOf(status) < ORDER.indexOf(target);

async function inTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
}

// ======================= Payments =======================
async function paidOn(invoiceId, client = { query }) {
  return N((await client.query('SELECT coalesce(sum(amount), 0) AS n FROM payments WHERE invoice_id = $1', [invoiceId])).rows[0].n);
}

// Records a payment and moves the invoice and job on when it is fully paid. Returns the new job status, if any.
async function applyPayment({ invoice, job, amount, method, reference, userId, stripeSessionId = null, receivedAt = null }) {
  return inTransaction(async (client) => {
    await client.query(
      `INSERT INTO payments (job_id, invoice_id, amount, method, reference, stripe_session_id, received_at, recorded_by)
       VALUES ($1, $2, $3, $4, $5, $6, coalesce($7::timestamptz, now()), $8)`,
      [job.id, invoice.id, amount, method, reference || null, stripeSessionId, receivedAt, userId]);
    const paid = await paidOn(invoice.id, client);
    if (paid + 0.005 < N(invoice.amount_due)) return null;
    await client.query("UPDATE invoices SET status = 'paid', paid_at = now() WHERE id = $1", [invoice.id]);
    const target = invoice.kind === 'deposit' ? 'deposit_paid' : 'paid';
    if (before(job.status, target)) {
      await setStatus(client, job.id, job.status, target, userId, `${iref(invoice.id)} paid (${method})`);
      return target;
    }
    return null;
  });
}

async function afterPayment(req, job, invoice, newStatus, amount, method) {
  if (newStatus) await notifyStageChange(job.id, newStatus, baseUrlOf(req));
  const m = money(amount);
  const next = newStatus === 'deposit_paid' ? '\nNext: order the parts and schedule the job.\n' : newStatus === 'paid' ? '\nThe job is fully paid.\n' : '';
  await notifyOffice(`Payment received: ${m} for ${job.title} (${ref(job.id)})`,
    `${m} received by ${method} against ${iref(invoice.id)}.${next}\n${baseUrlOf(req)}/jobs/${job.id}`, job.id);
}

async function stripeApi(path, params = null) {
  const res = await fetch('https://api.stripe.com/v1/' + path, {
    method: params ? 'POST' : 'GET',
    headers: { Authorization: 'Bearer ' + process.env.STRIPE_SECRET_KEY, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: params ? new URLSearchParams(params).toString() : undefined,
    signal: AbortSignal.timeout(15000),
  });
  const data = await res.json();
  if (!res.ok) throw new Error((data.error && data.error.message) || 'Stripe error');
  return data;
}

async function loadInvoice(req, job) {
  return (await query('SELECT * FROM invoices WHERE id = $1 AND job_id = $2', [Number(req.params.iid) || 0, job.id])).rows[0] || null;
}

// ======================= Panels on the job page =======================
async function nextStepPanel(job, user) {
  if (user.role === 'customer') return '';
  const s = await settings();
  const m = (n) => money(n, s.currency);
  const parts = [];

  if (user.role === 'admin' && job.status === 'accepted') {
    const q = await currentQuote(job.id);
    const dep = q ? N(q.deposit) : 0;
    parts.push(`<h3>Request the deposit</h3>
      <form method="post" action="/jobs/${job.id}/deposit" class="inline-form">
        <label>Deposit amount (including VAT)<input name="amount" type="number" step="0.01" min="0.01" value="${dep.toFixed(2)}" required></label>
        <button class="primary">Send deposit request</button>
      </form>
      <form method="post" action="/jobs/${job.id}/skip-deposit" class="inline"><button class="small">No deposit needed, carry on</button></form>`);
  }

  if (user.role === 'admin' && ['deposit_paid', 'parts_ordered', 'scheduled'].includes(job.status)) {
    const builders = (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows;
    const iso = (d) => (d ? new Date(d).toLocaleDateString('en-CA') : '');
    parts.push(`<h3>${job.status === 'scheduled' ? 'Change the booking' : 'Book the job in'}</h3>
      <form method="post" action="/jobs/${job.id}/schedule" class="schedule">
        <label>Builder<select name="builder_id" required>${builders.map((b) => `<option value="${b.id}" ${b.id === job.assigned_builder_id ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}</select></label>
        <label>Start<input type="date" name="start" value="${iso(job.scheduled_start)}" required></label>
        <label>Finish (optional)<input type="date" name="end" value="${iso(job.scheduled_end)}"></label>
        <button class="primary">${job.status === 'scheduled' ? 'Save and tell the customer' : 'Book in and tell the customer'}</button>
      </form>`);
  }

  if (mayWork(user, job) && job.status === 'scheduled') {
    parts.push(`<h3>On the day</h3><form method="post" action="/jobs/${job.id}/start" class="inline"><button class="primary">Start the job</button></form>`);
  }

  if (mayWork(user, job) && job.status === 'in_progress') {
    parts.push(`<h3>Finished?</h3>
      <form method="post" action="/jobs/${job.id}/complete">
        <label>What was done, and anything the office should know<textarea name="note" rows="3" maxlength="2000"></textarea></label>
        <p class="hint">Add finished-work photos below first. This clocks you off and tells the customer and office the work is done.</p>
        <button class="primary">Mark work complete</button>
      </form>`);
  }

  if (user.role === 'admin' && job.status === 'complete') {
    const q = await currentQuote(job.id);
    const paid = N((await query('SELECT coalesce(sum(amount), 0) AS n FROM payments WHERE job_id = $1', [job.id])).rows[0].n);
    parts.push(`<h3>Send the final invoice</h3>
      ${job.completion_note ? `<p class="pre muted">Builder’s note: ${esc(job.completion_note)}</p>` : ''}
      <form method="post" action="/jobs/${job.id}/invoice">
        <p>Based on quote ${q ? `${qref(q.id)} (${m(q.total)})` : '(none found)'}, less ${m(paid)} already paid.</p>
        <p class="fieldlabel">Agreed extras (before VAT, optional)</p>
        ${[0, 1, 2].map((i) => `<div class="row"><label>Description<input name="x${i}_desc" maxlength="200"></label><label>Amount<input name="x${i}_amount" type="number" step="0.01" min="0"></label></div>`).join('')}
        <label>Note on the invoice (optional)<textarea name="note" rows="2" maxlength="1000"></textarea></label>
        <button class="primary">Send invoice</button>
      </form>`);
  }

  if (!parts.length) return '';
  return `<section class="panel nextstep staffonly"><h2>Next step <span class="tag">Office and builders only</span></h2>${parts.join('')}</section>`;
}

const PART_STATUS = { to_order: 'To order', ordered: 'Ordered', ready: 'Ready to collect', collected: 'Collected', delivered: 'Delivered to site' };

async function partsPanel(job, user) {
  if (user.role === 'customer' || !ORDER.includes(job.status) || job.status === 'accepted') return '';
  const rows = (await query(
    `SELECT p.*, s.name AS supplier_name FROM job_parts p LEFT JOIN suppliers s ON s.id = p.supplier_id WHERE p.job_id = $1 ORDER BY p.sort, p.id`, [job.id])).rows;
  const isAdmin = user.role === 'admin';
  if (!rows.length) {
    return isAdmin ? `<section class="panel staffonly"><h2>Parts <span class="tag">Office and builders only</span></h2>
      <p>Make an order list from the materials on the accepted quote.</p>
      <form method="post" action="/jobs/${job.id}/parts/from-quote" class="inline"><button class="primary">Make parts list</button></form>
      <form method="post" action="/jobs/${job.id}/parts" class="inline"><input type="hidden" name="count" value="0"><button class="small">Start an empty list</button></form>
    </section>` : '';
  }
  const suppliers = (await query('SELECT id, name FROM suppliers WHERE active ORDER BY name')).rows;
  const supSel = (i, sel) => `<select name="p${i}_supplier"><option value="">No supplier</option>${suppliers.map((s) => `<option value="${s.id}" ${s.id === sel ? 'selected' : ''}>${esc(s.name)}</option>`).join('')}</select>`;
  const statusSel = (i, sel) => `<select name="p${i}_status">${Object.entries(PART_STATUS).map(([k, l]) => `<option value="${k}" ${k === sel ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
  const count = rows.length + (isAdmin ? 2 : 0);
  const outstanding = rows.filter((p) => p.status === 'to_order').length;
  return `<section class="panel staffonly" id="parts"><h2>Parts <span class="tag">Office and builders only</span></h2>
    <p>${outstanding ? `<span class="tag urgent">${outstanding} still to order</span>` : '<span class="tag ok">All ordered</span>'}</p>
    <form method="post" action="/jobs/${job.id}/parts">
      <input type="hidden" name="count" value="${count}">
      ${rows.map((p, i) => `<div class="pline">
        <input type="hidden" name="p${i}_id" value="${p.id}">
        ${isAdmin ? `<label class="desc">Item<input name="p${i}_desc" value="${esc(p.description)}" maxlength="200"></label>
          <label>Qty<input name="p${i}_qty" type="number" step="0.01" min="0" value="${N(p.qty)}"></label>
          <label>Supplier${supSel(i, p.supplier_id)}</label>`
        : `<div class="desc"><strong>${esc(p.description)}</strong><br>${N(p.qty)} ${esc(p.unit)}${p.supplier_name ? `, ${esc(p.supplier_name)}` : ''}</div>`}
        <label>Status${statusSel(i, p.status)}</label>
        <label>Note<input name="p${i}_note" value="${esc(p.note)}" maxlength="200" placeholder="Order number, branch"></label>
        ${isAdmin ? `<label class="check del"><input type="checkbox" name="p${i}_del"> Remove</label>` : ''}
      </div>`).join('')}
      ${isAdmin ? [0, 1].map((k) => { const i = rows.length + k; return `<div class="pline new">
        <label class="desc">Item<input name="p${i}_desc" maxlength="200" placeholder="Add a part"></label>
        <label>Qty<input name="p${i}_qty" type="number" step="0.01" min="0" value="1"></label>
        <label>Supplier${supSel(i, null)}</label>
        <label>Status${statusSel(i, 'to_order')}</label>
        <label>Note<input name="p${i}_note" maxlength="200"></label><span></span>
      </div>`; }).join('') : ''}
      <button class="primary">Save parts</button>
    </form>
  </section>`;
}

async function routePanel(job, user) {
  if (user.role === 'customer' || !['deposit_paid', 'parts_ordered', 'scheduled', 'in_progress'].includes(job.status)) return '';
  const stops = (await query(
    `SELECT s.id, s.name, s.address, s.postcode,
       string_agg(p.description || ' x' || (p.qty::float8)::text, ', ' ORDER BY p.sort, p.id) AS items
     FROM job_parts p JOIN suppliers s ON s.id = p.supplier_id
     WHERE p.job_id = $1 AND p.status IN ('ordered', 'ready')
     GROUP BY s.id, s.name, s.address, s.postcode ORDER BY s.name`, [job.id])).rows;
  const jobAddress = [job.address_line, job.town, job.postcode].filter(Boolean).join(', ');
  const placeOf = (s) => [s.name, s.address, s.postcode].filter(Boolean).join(', ');
  const usable = stops.filter((s) => s.address || s.postcode);
  const url = 'https://www.google.com/maps/dir/?api=1&travelmode=driving&destination=' + encodeURIComponent(jobAddress)
    + (usable.length ? '&waypoints=' + encodeURIComponent(usable.map(placeOf).join('|')) : '');
  return `<section class="panel staffonly route"><h2>Route <span class="tag">Office and builders only</span></h2>
    <ol class="stops">
      ${stops.map((s) => `<li><strong>Collect from ${esc(s.name)}</strong>${s.address || s.postcode ? `<br>${esc([s.address, s.postcode].filter(Boolean).join(', '))}` : '<br><span class="muted">No address saved for this supplier</span>'}<br><span class="muted">${esc(s.items)}</span></li>`).join('')}
      <li><strong>Job</strong><br>${esc(jobAddress)}${job.scheduled_start ? `<br><span class="muted">Booked ${day(job.scheduled_start)}${job.scheduled_end ? ` to ${day(job.scheduled_end)}` : ''}</span>` : ''}</li>
    </ol>
    <a class="button primary" href="${esc(url)}" target="_blank" rel="noopener">Open route in Google Maps</a>
    <p class="hint">Starts from wherever the phone is. Parts marked Collected or Delivered drop off the route.</p>
  </section>`;
}

async function invoicesPanel(job, user, req) {
  const invoices = (await query(
    `SELECT * FROM invoices WHERE job_id = $1 ${user.role === 'customer' ? "AND status <> 'void'" : ''} ORDER BY id`, [job.id])).rows;
  if (!invoices.length) return '';
  const s = await settings();
  const m = (n) => money(n, s.currency);
  const payments = (await query('SELECT * FROM payments WHERE job_id = $1 ORDER BY received_at', [job.id])).rows;
  const out = [];
  for (const inv of invoices) {
    const paid = payments.filter((p) => p.invoice_id === inv.id).reduce((a, p) => a + N(p.amount), 0);
    const due = r2(Math.max(0, N(inv.amount_due) - paid));
    const overdue = inv.status === 'issued' && inv.due_date && new Date(inv.due_date) < new Date(new Date().toDateString());
    const label = inv.kind === 'deposit' ? 'Deposit invoice' : 'Invoice';
    const tag = inv.status === 'paid' ? '<span class="tag ok">Paid</span>' : inv.status === 'void' ? '<span class="tag">Cancelled</span>' : overdue ? '<span class="tag urgent">Overdue</span>' : '<span class="tag">Waiting for payment</span>';
    const canPayOnline = user.role === 'customer' && inv.status === 'issued' && due > 0 && stripeReady();
    out.push(`<div class="invoice ${inv.status}">
      <div class="quotehead"><h3>${label} ${iref(inv.id)}</h3>${tag}</div>
      <div class="wtotals">
        <div><span>Total</span><span>${m(inv.total)}</span></div>
        ${N(inv.less_paid) ? `<div><span>Less already paid</span><span>−${m(inv.less_paid)}</span></div>` : ''}
        ${paid ? `<div><span>Paid on this invoice</span><span>−${m(paid)}</span></div>` : ''}
        <div class="grand"><span>${inv.status === 'void' ? 'Cancelled' : 'Left to pay'}</span><span>${inv.status === 'void' ? '' : m(due)}</span></div>
        ${inv.due_date && inv.status === 'issued' ? `<div><span>Due by</span><span>${day(inv.due_date)}</span></div>` : ''}
      </div>
      <div class="buttons">
        <a class="button" href="/jobs/${job.id}/invoices/${inv.id}/pdf" target="_blank" rel="noopener">View or print</a>
        <a class="button" href="/jobs/${job.id}/invoices/${inv.id}/pdf?download=1">Download PDF</a>
        ${canPayOnline ? `<form method="post" action="/jobs/${job.id}/invoices/${inv.id}/pay" class="inline"><button class="primary">Pay ${m(due)} by card</button></form>` : ''}
      </div>
      ${user.role === 'customer' && inv.status === 'issued' && due > 0 ? `<div class="payhow">
        <p class="pre">${esc(s.payment_instructions)}</p>
        ${s.bank_details ? `<p class="pre"><strong>Bank details</strong>\n${esc(s.bank_details)}\nReference: ${ref(job.id)}</p>` : ''}
      </div>` : ''}
      ${user.role === 'admin' && inv.status === 'issued' ? `<details class="recordpay"><summary>Record a payment</summary>
        <form method="post" action="/jobs/${job.id}/invoices/${inv.id}/payments" class="panel">
          <div class="row">
            <label>Amount<input name="amount" type="number" step="0.01" min="0.01" value="${due.toFixed(2)}" required></label>
            <label>Date received<input name="date" type="date" value="${todayISO()}" required></label>
          </div>
          <label>How it was paid<select name="method">
            <option>Card over the phone</option><option>Bank transfer</option><option>Cash</option><option>Cheque</option><option>Card in person</option>
          </select></label>
          <label>Reference (optional)<input name="reference" maxlength="100"></label>
          <button class="primary">Record payment</button>
        </form>
        <form method="post" action="/jobs/${job.id}/invoices/${inv.id}/void" class="inline">
          <label class="check"><input type="checkbox" name="confirm" required> Cancel this invoice</label> <button class="small danger">Cancel invoice</button>
        </form>
      </details>` : ''}
    </div>`);
  }
  const payList = payments.length ? `<h3>Payments</h3><ul class="payments">${payments.map((p) => `<li>${day(p.received_at)}: ${m(p.amount)} by ${esc(p.method)}${user.role !== 'customer' && p.reference ? ` (${esc(p.reference)})` : ''}${p.invoice_id ? `, ${iref(p.invoice_id)}` : ''}</li>`).join('')}</ul>` : '';
  const flash = req && req.query.paid ? '<div class="notice">Thank you, your payment has been received.</div>'
    : req && req.query.payfail ? `<div class="error">${esc(String(req.query.payfail).slice(0, 200))}</div>` : '';
  return `<section class="panel invoices" id="invoices"><h2>Invoices and payments</h2>${flash}${out.join('')}${payList}</section>`;
}

// ======================= Actions =======================
router.post('/jobs/:id/deposit', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  if (job.status !== 'accepted') return back(res, job);
  const amount = r2(N(req.body.amount));
  if (amount <= 0) return errorBack(res, job, 'Enter a deposit amount.');
  const s = await settings();
  const q = await currentQuote(job.id);
  const vatRate = s.vat_registered ? N(s.vat_rate) : 0;
  const net = r2(amount / (1 + vatRate / 100));
  const lines = [{ category: 'other', description: `Deposit${q ? ` for quote ${qref(q.id)}` : ''}: ${job.title}`, qty: 1, unit: '', unit_price: net }];
  await inTransaction(async (client) => {
    await client.query(
      `INSERT INTO invoices (job_id, kind, quote_id, lines, net, vat_rate, vat, total, amount_due, due_date, created_by)
       VALUES ($1, 'deposit', $2, $3, $4, $5, $6, $7, $7, $8, $9)`,
      [job.id, q ? q.id : null, JSON.stringify(lines), net, vatRate, r2(amount - net), amount, todayISO(), req.user.id]);
    await setStatus(client, job.id, job.status, 'deposit_requested', req.user.id, `Deposit of ${money(amount)} requested`);
  });
  await notifyStageChange(job.id, 'deposit_requested', baseUrlOf(req));
  back(res, job, '#invoices');
}));

router.post('/jobs/:id/skip-deposit', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  if (job.status === 'accepted') {
    await inTransaction((client) => setStatus(client, job.id, job.status, 'deposit_paid', req.user.id, 'No deposit needed'));
  }
  back(res, job, '#parts');
}));

router.post('/jobs/:id/parts/from-quote', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const q = (await query("SELECT * FROM quotes WHERE job_id = $1 AND status = 'accepted' ORDER BY id DESC LIMIT 1", [job.id])).rows[0];
  let lines = q ? q.lines.filter((l) => l.category === 'materials') : [];
  if (!lines.length) {
    lines = (await query("SELECT description, qty, unit FROM job_estimate_lines WHERE job_id = $1 AND category = 'materials' ORDER BY sort, id", [job.id])).rows;
  }
  await inTransaction(async (client) => {
    let i = 0;
    for (const l of lines) {
      const match = (await client.query('SELECT supplier_id FROM price_items WHERE lower(name) = lower($1) AND supplier_id IS NOT NULL ORDER BY active DESC, id LIMIT 1', [l.description])).rows[0];
      await client.query('INSERT INTO job_parts (job_id, description, qty, unit, supplier_id, sort) VALUES ($1, $2, $3, $4, $5, $6)',
        [job.id, l.description, N(l.qty), l.unit || null, match ? match.supplier_id : null, i++]);
    }
  });
  back(res, job, '#parts', lines.length ? 'updated=1' : 'error=' + encodeURIComponent('No materials found on the quote. Add parts by hand.'));
}));

router.post('/jobs/:id/parts', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const isAdmin = req.user.role === 'admin';
  const count = Math.min(Number(req.body.count) || 0, 300);
  let moved = false;
  await inTransaction(async (client) => {
    for (let i = 0; i < count; i++) {
      const id = Number(req.body[`p${i}_id`]) || null;
      const status = PART_STATUS[req.body[`p${i}_status`]] ? req.body[`p${i}_status`] : 'to_order';
      const note = String(req.body[`p${i}_note`] || '').trim().slice(0, 200) || null;
      if (!isAdmin) {
        if (id) await client.query('UPDATE job_parts SET status = $1, note = $2, updated_at = now() WHERE id = $3 AND job_id = $4', [status, note, id, job.id]);
        continue;
      }
      if (id && req.body[`p${i}_del`] === 'on') {
        await client.query('DELETE FROM job_parts WHERE id = $1 AND job_id = $2', [id, job.id]);
        continue;
      }
      const desc = String(req.body[`p${i}_desc`] || '').trim().slice(0, 200);
      if (!desc) continue;
      const qty = Math.max(0, N(req.body[`p${i}_qty`]));
      const supplier = Number(req.body[`p${i}_supplier`]) || null;
      if (id) {
        await client.query('UPDATE job_parts SET description = $1, qty = $2, supplier_id = $3, status = $4, note = $5, updated_at = now() WHERE id = $6 AND job_id = $7',
          [desc, qty, supplier, status, note, id, job.id]);
      } else {
        await client.query('INSERT INTO job_parts (job_id, description, qty, supplier_id, status, note, sort) VALUES ($1, $2, $3, $4, $5, $6, $7)',
          [job.id, desc, qty, supplier, status, note, 1000 + i]);
      }
    }
    // Once nothing is left to order, the job moves to Parts ordered.
    const left = (await client.query("SELECT count(*)::int AS n, count(*) FILTER (WHERE status = 'to_order')::int AS todo FROM job_parts WHERE job_id = $1", [job.id])).rows[0];
    if (left.n && !left.todo && job.status === 'deposit_paid') {
      await setStatus(client, job.id, job.status, 'parts_ordered', req.user.id, 'All parts ordered');
      moved = true;
    }
  });
  if (moved) await notifyStageChange(job.id, 'parts_ordered', baseUrlOf(req));
  back(res, job, '#parts');
}));

router.post('/jobs/:id/schedule', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const builderId = Number(req.body.builder_id) || null;
  const start = String(req.body.start || '');
  const end = String(req.body.end || '');
  if (!isDate(start)) return errorBack(res, job, 'Choose a start date.');
  if (end && (!isDate(end) || end < start)) return errorBack(res, job, 'The finish date must be on or after the start.');
  const ok = builderId && (await query("SELECT 1 FROM users WHERE id = $1 AND role = 'builder' AND active", [builderId])).rows.length;
  if (!ok) return errorBack(res, job, 'Choose a builder.');
  await inTransaction(async (client) => {
    await client.query('UPDATE jobs SET assigned_builder_id = $1, scheduled_start = $2, scheduled_end = $3, updated_at = now() WHERE id = $4',
      [builderId, start, end || null, job.id]);
    await setStatus(client, job.id, job.status, 'scheduled', req.user.id, `Booked for ${day(start)}${end ? ` to ${day(end)}` : ''}`);
  });
  await notifyStageChange(job.id, 'scheduled', baseUrlOf(req));
  back(res, job);
}));

router.post('/jobs/:id/start', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  if (job.status === 'scheduled') {
    await inTransaction((client) => setStatus(client, job.id, job.status, 'in_progress', req.user.id, 'Work started'));
    await notifyStageChange(job.id, 'in_progress', baseUrlOf(req));
  }
  back(res, job, '#time');
}));

router.post('/jobs/:id/complete', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  if (job.status !== 'in_progress') return back(res, job);
  const note = String(req.body.note || '').trim().slice(0, 2000) || null;
  await inTransaction(async (client) => {
    await client.query("UPDATE job_time_entries SET ended_at = now() WHERE job_id = $1 AND ended_at IS NULL", [job.id]);
    await client.query('UPDATE jobs SET completion_note = $1, completed_at = now(), updated_at = now() WHERE id = $2', [note, job.id]);
    await setStatus(client, job.id, job.status, 'complete', req.user.id, note ? `Work complete: ${note}` : 'Work complete');
  });
  await notifyStageChange(job.id, 'complete', baseUrlOf(req));
  await notifyOffice(`Work complete: ${job.title} (${ref(job.id)})`,
    `${req.user.name} has marked the job complete.${note ? `\n\nNote: ${note}` : ''}\n\nNext: send the final invoice.\n${baseUrlOf(req)}/jobs/${job.id}`, job.id);
  back(res, job);
}));

router.post('/jobs/:id/invoice', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  if (job.status !== 'complete') return back(res, job);
  const q = (await query("SELECT * FROM quotes WHERE job_id = $1 AND status = 'accepted' ORDER BY id DESC LIMIT 1", [job.id])).rows[0];
  if (!q) return errorBack(res, job, 'There’s no accepted quote to invoice from.');
  const s = await settings();
  const lines = q.lines.map((l) => ({ ...l }));
  for (let i = 0; i < 3; i++) {
    const d = String(req.body[`x${i}_desc`] || '').trim().slice(0, 200);
    const a = r2(N(req.body[`x${i}_amount`]));
    if (d && a > 0) lines.push({ category: 'other', description: d, qty: 1, unit: '', unit_price: a, extra: true });
  }
  const net = r2(lines.reduce((t, l) => t + N(l.qty) * N(l.unit_price), 0));
  const vatRate = s.vat_registered ? N(s.vat_rate) : 0;
  const vat = r2(net * vatRate / 100);
  const total = r2(net + vat);
  const paid = N((await query('SELECT coalesce(sum(amount), 0) AS n FROM payments WHERE job_id = $1', [job.id])).rows[0].n);
  const due = r2(Math.max(0, total - paid));
  const dueDate = new Date(Date.now() + N(s.payment_terms_days) * 86400000).toISOString().slice(0, 10);
  // Extras always show as their own lines, even on a summary-style quote.
  await inTransaction(async (client) => {
    await client.query(
      `INSERT INTO invoices (job_id, kind, quote_id, layout, lines, net, vat_rate, vat, total, less_paid, amount_due, due_date, note, created_by)
       VALUES ($1, 'final', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
      [job.id, q.id, q.layout, JSON.stringify(lines), net, vatRate, vat, total, r2(paid), due, dueDate,
        String(req.body.note || '').trim().slice(0, 1000) || null, req.user.id]);
    await setStatus(client, job.id, job.status, 'invoiced', req.user.id, `Final invoice for ${money(total)} sent`);
  });
  await notifyStageChange(job.id, 'invoiced', baseUrlOf(req));
  back(res, job, '#invoices');
}));

router.post('/jobs/:id/invoices/:iid/payments', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const inv = await loadInvoice(req, job);
  if (!inv || inv.status !== 'issued') return back(res, job, '#invoices');
  const amount = r2(N(req.body.amount));
  if (amount <= 0) return errorBack(res, job, 'Enter the amount received.', '#invoices');
  const method = String(req.body.method || 'Other').slice(0, 40);
  const date = isDate(req.body.date) ? req.body.date : null;
  const newStatus = await applyPayment({ invoice: inv, job, amount, method, reference: String(req.body.reference || '').trim().slice(0, 100), userId: req.user.id, receivedAt: date });
  if (newStatus) await notifyStageChange(job.id, newStatus, baseUrlOf(req));
  back(res, job, '#invoices');
}));

router.post('/jobs/:id/invoices/:iid/void', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const inv = await loadInvoice(req, job);
  if (inv && inv.status === 'issued' && req.body.confirm === 'on') {
    if (await paidOn(inv.id)) return errorBack(res, job, 'This invoice has payments recorded, so it can’t be cancelled.', '#invoices');
    await query("UPDATE invoices SET status = 'void' WHERE id = $1", [inv.id]);
  }
  back(res, job, '#invoices');
}));

// ---- Online card payments (Stripe Checkout) ----
router.post('/jobs/:id/invoices/:iid/pay', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || req.user.role !== 'customer') return notFound(req, res);
  const inv = await loadInvoice(req, job);
  if (!inv || inv.status !== 'issued' || !stripeReady()) return back(res, job, '#invoices');
  const due = r2(N(inv.amount_due) - (await paidOn(inv.id)));
  if (due <= 0) return back(res, job, '#invoices');
  const base = baseUrlOf(req);
  try {
    const session = await stripeApi('checkout/sessions', {
      mode: 'payment',
      'line_items[0][price_data][currency]': 'gbp',
      'line_items[0][price_data][product_data][name]': `${inv.kind === 'deposit' ? 'Deposit' : 'Invoice'} ${iref(inv.id)}: ${job.title}`.slice(0, 250),
      'line_items[0][price_data][unit_amount]': String(Math.round(due * 100)),
      'line_items[0][quantity]': '1',
      customer_email: job.customer_email,
      'metadata[invoice_id]': String(inv.id),
      'metadata[job_id]': String(job.id),
      success_url: `${base}/jobs/${job.id}/invoices/${inv.id}/paid?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${base}/jobs/${job.id}#invoices`,
    });
    res.redirect(303, session.url);
  } catch (e) {
    console.error('Stripe checkout failed:', e.message);
    res.redirect(`/jobs/${job.id}?payfail=${encodeURIComponent('Online payment isn’t available right now. Please use one of the other ways to pay.')}#invoices`);
  }
}));

router.get('/jobs/:id/invoices/:iid/paid', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const inv = await loadInvoice(req, job);
  const sessionId = String(req.query.session_id || '');
  if (!inv || !/^cs_[A-Za-z0-9_]+$/.test(sessionId) || !stripeReady()) return back(res, job, '#invoices');
  try {
    const session = await stripeApi('checkout/sessions/' + encodeURIComponent(sessionId));
    if (session.payment_status !== 'paid' || String(session.metadata && session.metadata.invoice_id) !== String(inv.id)) {
      return res.redirect(`/jobs/${job.id}?payfail=${encodeURIComponent('The payment hasn’t gone through. Nothing has been taken.')}#invoices`);
    }
    const already = (await query('SELECT 1 FROM payments WHERE stripe_session_id = $1', [sessionId])).rows.length;
    if (!already) {
      const amount = r2(N(session.amount_total) / 100);
      const newStatus = await applyPayment({ invoice: inv, job, amount, method: 'Card online', reference: session.payment_intent || sessionId, userId: req.user.id, stripeSessionId: sessionId });
      await afterPayment(req, job, inv, newStatus, amount, 'card online');
    }
    res.redirect(`/jobs/${job.id}?paid=1#invoices`);
  } catch (e) {
    if (e.code === '23505') return res.redirect(`/jobs/${job.id}?paid=1#invoices`);
    console.error('Stripe check failed:', e.message);
    res.redirect(`/jobs/${job.id}?payfail=${encodeURIComponent('We couldn’t confirm the payment yet. If money was taken, the office will match it up.')}#invoices`);
  }
}));

// ---- Invoice PDF ----
router.get('/jobs/:id/invoices/:iid/pdf', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const inv = await loadInvoice(req, job);
  if (!inv || (req.user.role === 'customer' && inv.status === 'void')) return notFound(req, res);
  const s = await settings();
  const m = (n) => money(n, s.currency);
  const cust = (await query('SELECT name FROM users WHERE id = $1', [job.customer_id])).rows[0];
  const paid = await paidOn(inv.id);
  const due = r2(Math.max(0, N(inv.amount_due) - paid));

  // Summary-style quotes group the quoted lines, but agreed extras stay as their own lines.
  const quoted = { layout: inv.layout, lines: inv.lines.filter((l) => !l.extra) };
  const extras = inv.lines.filter((l) => l.extra).map((l) => ({ description: l.description, qty: 1, unit: '', price: N(l.unit_price), total: N(l.unit_price) }));
  const itemised = inv.kind === 'deposit' || inv.layout === 'itemised';
  const rows = [...displayLines({ ...quoted, layout: itemised ? 'itemised' : 'summary' }), ...extras.map((x) => (itemised ? x : { ...x, qty: null, price: null }))];

  const totals = [['Net', m(inv.net)]];
  if (N(inv.vat)) totals.push([`VAT ${N(inv.vat_rate)}%`, m(inv.vat)]);
  totals.push(['Total', m(inv.total), true]);
  if (N(inv.less_paid)) totals.push(['Less already paid', `-${m(inv.less_paid)}`]);
  if (paid) totals.push(['Paid', `-${m(paid)}`]);
  totals.push([inv.status === 'void' ? 'Cancelled' : 'Amount due', inv.status === 'void' ? '' : m(due), true]);

  const blocks = [{ text: inv.note }];
  if (inv.status === 'paid') blocks.push({ title: `Paid in full${inv.paid_at ? ` on ${day(inv.paid_at)}` : ''}. Thank you.`, text: ' ' });
  else if (inv.status === 'issued') {
    blocks.push({ title: 'How to pay', text: s.payment_instructions });
    if (s.bank_details) blocks.push({ title: 'Bank details', text: `${s.bank_details}\nReference: ${ref(job.id)}` });
    if (stripeReady()) blocks.push({ title: 'Pay by card online', text: `${baseUrlOf(req)}/jobs/${job.id}` });
  }

  renderDocument({
    res, s, money: m, download: Boolean(req.query.download), filename: `${iref(inv.id)}.pdf`,
    title: inv.kind === 'deposit' ? 'Deposit invoice' : 'Invoice',
    meta: [['Invoice', iref(inv.id)], ['Date', day(inv.created_at)], ['Due', inv.due_date ? day(inv.due_date) : 'On receipt'], ['Job', ref(job.id)]],
    customer: { name: cust.name, lines: [job.address_line, job.town, job.postcode] },
    heading: job.title, itemised, rows, totals, blocks,
  });
}));

module.exports = { router, nextStepPanel, partsPanel, routePanel, invoicesPanel, iref };
HANDYTRIO_EOF

cat > src/routes/quotes.js <<'HANDYTRIO_EOF'
// Quotes: sent from the working estimate, viewed and accepted or declined by the customer, downloadable as PDF.
const express = require('express');
const { renderDocument } = require('../pdf');
const { pool, query } = require('../db');
const { esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day } = require('../format');
const { money } = require('../estimate');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange, notifyOffice } = require('../notify');

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
  if (req.user.role === 'customer') {
    await notifyOffice(`Quote ${to}: ${job.title} (${ref(job.id)})`,
      `${job.customer_name} has ${to} quote ${qref(q.id)} for ${money(q.total)}.${reason ? `\nReason: ${reason}` : ''}\n\n${accept ? 'Next: request the deposit.\n' : ''}${baseUrlOf(req)}/jobs/${job.id}`, job.id);
  }
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

  const blocks = [{ text: q.customer_note }];
  if (q.status === 'sent') blocks.push({ title: 'To accept this quote', text: `Log in and open your job: ${baseUrlOf(req)}/jobs/${job.id}` });
  if (q.status === 'accepted') blocks.push({ title: `Accepted ${day(q.responded_at)}`, text: ' ' });
  blocks.push({ title: 'Terms', text: s.quote_terms, small: true });
  const totals = [['Net', m(q.net)]];
  if (N(q.vat)) totals.push([`VAT ${N(q.vat_rate)}%`, m(q.vat)]);
  totals.push(['Total', m(q.total), true]);
  renderDocument({
    res, s, money: m, download: Boolean(req.query.download), filename: `${qref(q.id)}.pdf`, title: 'Quote',
    meta: [['Quote', qref(q.id)], ['Date', day(q.created_at)], ['Valid until', day(q.valid_until)], ['Job', ref(job.id)]],
    customer: { name: cust.name, lines: [job.address_line, job.town, job.postcode] },
    heading: job.title, intro: q.scope, itemised: q.layout === 'itemised', rows: displayLines(q), totals,
    afterTotals: N(q.deposit) ? [`Deposit to book (${N(q.deposit_pct)}%): ${m(q.deposit)}`] : [], blocks,
  });
}));

module.exports = { router, quotePanel, sendQuoteForm, currentQuote, displayLines, qref };
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
const workflow = require('./workflow');

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
        <p class="hint">Saving re-prices travel on the price guide and working estimate from this builder’s home, until a quote is sent.</p>
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
  ${await workflow.invoicesPanel(job, user, req)}
  ${await workflow.nextStepPanel(job, user)}
  ${await workflow.routePanel(job, user)}
  ${await quotes.quotePanel(job, user)}
  ${estimatePanel}
  <div class="jobgrid">
    <section class="panel">
      <h2>The job</h2>
      <dl>
        <dt>Type of work</dt><dd>${esc(job.work_type || 'Not given')}</dd>
        <dt>Details</dt><dd class="pre">${esc(job.description || 'No details given')}</dd>
        <dt>Wanted from</dt><dd>${day(job.preferred_start)}${job.preferred_end ? ` to ${day(job.preferred_end)}` : ''}</dd>
        ${job.scheduled_start ? `<dt>Booked in</dt><dd><strong>${day(job.scheduled_start)}${job.scheduled_end ? ` to ${day(job.scheduled_end)}` : ''}</strong></dd>` : ''}
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
  ${await workflow.partsPanel(job, user)}
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
  // Same for the working estimate's travel lines, if one has been started.
  const hasWorksheet = (await query('SELECT 1 FROM job_estimate_lines WHERE job_id = $1 LIMIT 1', [job.id])).rows.length;
  if (hasWorksheet && REPRICE_STAGES.includes(job.status)) {
    await onsite.refreshWorksheetTravel({ ...job, assigned_builder_id: builderId }, req.user.id);
  }
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

cat > src/routes/dashboard.js <<'HANDYTRIO_EOF'
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin } = require('../auth');
const { STATUSES, CLOSED, label } = require('../statuses');
const { ref, day } = require('../format');

const router = express.Router();

function jobsTable(jobs, { showCustomer = false, showBuilder = false } = {}) {
  if (!jobs.length) return '';
  const rows = jobs.map((j) => `<tr>
    <td><a href="/jobs/${j.id}">${ref(j.id)}</a></td>
    <td><a href="/jobs/${j.id}">${esc(j.title)}</a>${j.urgent ? ' <span class="tag urgent">Urgent</span>' : ''}</td>
    ${showCustomer ? `<td>${esc(j.customer_name)}</td>` : ''}
    <td>${esc(j.postcode)}</td>
    <td><span class="tag">${esc(label(j.status))}</span></td>
    ${showBuilder ? `<td>${esc(j.builder_name || 'Not assigned')}</td>` : ''}
    <td>${j.scheduled_start ? `<strong>${day(j.scheduled_start)}</strong>` : day(j.preferred_start)}</td>
  </tr>`).join('');
  return `<div class="scroll"><table>
    <thead><tr><th>Job</th><th>Work</th>${showCustomer ? '<th>Customer</th>' : ''}<th>Postcode</th><th>Stage</th>${showBuilder ? '<th>Builder</th>' : ''}<th>Date</th></tr></thead>
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
        <p>Tell us about the job, add photos, and pick when you’d like it done.</p>
        <p><a class="button primary" href="/jobs/new">Request a job</a></p>
      </section>
      <h2>Your jobs</h2>
      ${jobsTable(rows) || '<p class="empty">You haven’t requested any jobs yet.</p>'}`;
    return res.send(page({ title: 'Your dashboard', user, body }));
  }

  if (user.role === 'builder') {
    const { rows } = await query(
      `${JOB_SELECT} WHERE j.assigned_builder_id = $1 AND j.status <> ALL($2) ORDER BY coalesce(j.scheduled_start, j.preferred_start) NULLS LAST, j.created_at`,
      [user.id, CLOSED]
    );
    const clocked = (await query(
      `SELECT t.job_id, t.started_at, j.title FROM job_time_entries t JOIN jobs j ON j.id = t.job_id
       WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
    const body = `${clocked ? `<div class="notice">You’re clocked on to <a href="/jobs/${clocked.job_id}#time">${esc(clocked.title)}</a> since ${new Date(clocked.started_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}.</div>` : ''}
      <h2>Your jobs</h2>
      ${jobsTable(rows, { showCustomer: true }) || '<p class="empty">No jobs assigned to you yet. The office will assign them here.</p>'}`;
    return res.send(page({ title: 'Builder dashboard', user, body }));
  }

  // Admin
  const counts = await query('SELECT status, count(*)::int AS n FROM jobs GROUP BY status');
  const byStatus = Object.fromEntries(counts.rows.map((r) => [r.status, r.n]));
  const pipeline = STATUSES.filter(([k]) => !CLOSED.includes(k))
    .map(([k, l]) => `<li class="${byStatus[k] ? 'has' : ''}"><span class="n">${byStatus[k] || 0}</span><span>${esc(l)}</span></li>`)
    .join('');
  const open = await query(`${JOB_SELECT} WHERE j.status <> ALL($1) ORDER BY j.urgent DESC, j.created_at DESC LIMIT 50`, [CLOSED]);
  const s = (await query(
    `SELECT base_postcode, (SELECT count(*)::int FROM users WHERE role = 'builder' AND active AND coalesce(postcode, '') <> '') AS builder_postcodes
     FROM settings WHERE id = 1`)).rows[0];

  const ACTIONS = [
    ['request', 'Check the price guide'],
    ['inspection_required', 'Book an inspection'],
    ['inspected', 'Send the quote'],
    ['accepted', 'Request the deposit'],
    ['deposit_paid', 'Order parts and book the job in'],
    ['parts_ordered', 'Book the job in'],
    ['complete', 'Send the final invoice'],
  ];
  const actionRows = (await query(
    `SELECT id, title, status, urgent FROM jobs WHERE status = ANY($1) ORDER BY urgent DESC, updated_at`, [ACTIONS.map((a) => a[0])])).rows;
  const overdue = (await query(
    `SELECT i.id, i.job_id, j.title FROM invoices i JOIN jobs j ON j.id = i.job_id
     WHERE i.status = 'issued' AND i.due_date < current_date ORDER BY i.due_date`)).rows;
  const todoItems = [
    ...actionRows.map((j) => `<li><a href="/jobs/${j.id}"><strong>${esc(ACTIONS.find((a) => a[0] === j.status)[1])}</strong>: ${esc(j.title)} (${ref(j.id)})</a>${j.urgent ? ' <span class="tag urgent">Urgent</span>' : ''}</li>`),
    ...overdue.map((i) => `<li><a href="/jobs/${i.job_id}#invoices"><strong>Chase overdue invoice</strong>: ${esc(i.title)} (${ref(i.job_id)})</a></li>`),
  ];
  const todo = `<h2>Needs your attention</h2>${todoItems.length ? `<ul class="todo">${todoItems.join('')}</ul>` : '<p class="empty">Nothing waiting on you right now.</p>'}`;

  const body = `
    ${!s.base_postcode && !s.builder_postcodes ? '<div class="error">Add your builders’ home postcodes on the <a href="/admin/users">People</a> page so travel costs can be worked out.</div>' : ''}
    ${todo}
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
    ['payment_instructions', 'How customers can pay (shown on invoices)', 'textarea'],
    ['bank_details', 'Bank details for transfers (account name, sort code, account number)', 'textarea'],
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
    <thead><tr><th>Supplier</th><th>Address</th><th>Phone</th><th>Items</th><th>Status</th><th></th></tr></thead>
    <tbody>${rows.map((s) => `<tr class="${s.active ? '' : 'off'}">
      <td><a href="/admin/suppliers/${s.id}">${esc(s.name)}</a></td><td>${s.address || s.postcode ? esc([s.address, s.postcode].filter(Boolean).join(', ')) : '<span class="tag urgent">Needs address</span>'}</td><td>${esc(s.phone)}</td>
      <td><a href="/admin/price-list?supplier=${s.id}">${s.items}</a></td><td>${s.active ? 'Active' : 'Switched off'}</td>
      <td><form method="post" action="/admin/suppliers/${s.id}/toggle" class="inline"><button class="small">${s.active ? 'Switch off' : 'Switch on'}</button></form></td>
    </tr>`).join('')}</tbody></table></div>` : '<p class="empty">No suppliers yet. Add your local merchants below.</p>';
  const body = `${subnav('/admin/suppliers')}${list}
    <h2>Add a supplier</h2>
    <form method="post" action="/admin/suppliers" class="panel narrow">
      <label>Name<input name="name" required maxlength="120"></label>
      <label>Branch address<input name="address" maxlength="200"></label>
      <label>Postcode<input name="postcode" maxlength="10"></label>
      <label>Phone<input name="phone" type="tel"></label>
      <label>Email<input name="email" type="email"></label>
      <p class="hint">The address is used to route builders past the branch to collect parts.</p>
      <button class="primary">Add supplier</button>
    </form>`;
  res.send(page({ title: 'Suppliers', user: req.user, notice: req.query.added ? 'Supplier saved.' : null, error: req.query.error ? txt(req.query.error) : null, body }));
}));

router.post('/admin/suppliers', admin, wrap(async (req, res) => {
  const name = txt(req.body.name, 120);
  if (!name) return res.redirect('/admin/suppliers?error=' + encodeURIComponent('Enter a supplier name.'));
  try {
    await query('INSERT INTO suppliers (name, phone, email, address, postcode) VALUES ($1, $2, $3, $4, $5)',
      [name, txt(req.body.phone) || null, txt(req.body.email) || null, txt(req.body.address) || null, txt(req.body.postcode, 10).toUpperCase() || null]);
  } catch (e) {
    if (e.code === '23505') return res.redirect('/admin/suppliers?error=' + encodeURIComponent('That supplier already exists.'));
    throw e;
  }
  res.redirect('/admin/suppliers?added=1');
}));

router.get('/admin/suppliers/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const s = id && (await query('SELECT * FROM suppliers WHERE id = $1', [id])).rows[0];
  if (!s) return res.redirect('/admin/suppliers');
  const body = `${subnav('/admin/suppliers')}
    <form method="post" action="/admin/suppliers/${s.id}" class="panel narrow">
      <label>Name<input name="name" value="${esc(s.name)}" required maxlength="120"></label>
      <label>Branch address<input name="address" value="${esc(s.address)}" maxlength="200"></label>
      <label>Postcode<input name="postcode" value="${esc(s.postcode)}" maxlength="10"></label>
      <label>Phone<input name="phone" value="${esc(s.phone)}" type="tel"></label>
      <label>Email<input name="email" value="${esc(s.email)}" type="email"></label>
      <button class="primary">Save supplier</button>
    </form>
    <p><a href="/admin/price-list?supplier=${s.id}">See this supplier’s prices</a> · <a href="/admin/suppliers">Back to suppliers</a></p>`;
  res.send(page({ title: s.name, user: req.user, body }));
}));

router.post('/admin/suppliers/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const name = txt(req.body.name, 120);
  if (!id || !name) return res.redirect('/admin/suppliers');
  try {
    await query('UPDATE suppliers SET name = $1, address = $2, postcode = $3, phone = $4, email = $5 WHERE id = $6',
      [name, txt(req.body.address) || null, txt(req.body.postcode, 10).toUpperCase() || null, txt(req.body.phone) || null, txt(req.body.email) || null, id]);
  } catch (e) {
    if (e.code === '23505') return res.redirect('/admin/suppliers?error=' + encodeURIComponent('Another supplier already has that name.'));
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

/* Stage 5: after the quote */
.nextstep h3, .invoices h3 { font: 600 1.15rem "Barlow Condensed", Barlow, sans-serif; margin: 1rem 0 .5rem; }
.nextstep h3:first-of-type { margin-top: .25rem; }
.nextstep form.inline { display: inline-block; margin: .25rem .5rem .25rem 0; }
.schedule { display: grid; grid-template-columns: 1.2fr 1fr 1fr auto; gap: .75rem; align-items: end; }
.schedule label { margin: 0; }
.invoices .invoice { border-top: 1px solid var(--line); padding-top: .75rem; margin-top: .75rem; }
.invoices .invoice:first-of-type { border-top: 0; margin-top: 0; padding-top: 0; }
.invoices .invoice.void { opacity: .6; }
.invoices .wtotals { margin: .5rem 0 .75rem auto; }
.payhow { background: var(--bg); border-radius: 4px; padding: .5rem 1rem; margin-top: .75rem; }
.recordpay { margin-top: .75rem; }
.recordpay summary { cursor: pointer; font-weight: 600; }
.recordpay .panel { margin-top: .5rem; }
.payments { margin: 0; padding-left: 1.2rem; }
.pline { display: grid; grid-template-columns: 1fr 80px 160px 150px 1fr 90px; gap: .5rem; align-items: end; padding: .5rem 0; border-bottom: 1px solid var(--line); }
.pline label { margin: 0; font-size: .85rem; }
.pline.new { opacity: .8; }
.pline .del { padding-bottom: .55rem; }
.route .stops { padding-left: 1.3rem; margin: 0 0 1rem; }
.route .stops li { margin-bottom: .6rem; }
.todo { list-style: none; padding: 0; margin: 0; display: grid; gap: .4rem; }
.todo li { background: var(--surface); border: 1px solid var(--line); border-left: 5px solid var(--hivis); border-radius: 4px; padding: .6rem .8rem; }
.todo a { text-decoration: none; }
@media (max-width: 760px) {
  .schedule { grid-template-columns: 1fr 1fr; }
  .pline { grid-template-columns: 1fr 1fr; }
  .pline .desc { grid-column: 1 / -1; }
}
HANDYTRIO_EOF

if ! grep -q "STRIPE_SECRET_KEY" .env; then
  printf "\n# Online card payments with Stripe. Paste your secret key (starts sk_test_ or sk_live_), then restart the app.\n# STRIPE_SECRET_KEY=\n" >> .env
fi
echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "Stage 5 installed. The app restarts by itself; otherwise run: npm run dev"
