#!/usr/bin/env bash
# TheHandyTrio update 2 of 3: calendar, inspection booking and phone calendar feed. Run with: bash calendar.sh
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

-- Stage 6: engineer qualifications and certificates
CREATE TABLE IF NOT EXISTS staff_qualifications (
  id         serial PRIMARY KEY,
  user_id    int NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind       text NOT NULL CHECK (kind IN ('gas','electrical','pat')),
  scheme     text,
  number     text NOT NULL,
  categories text,
  expires    date NOT NULL,
  notes      text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS staff_qualifications_user_idx ON staff_qualifications (user_id);

CREATE TABLE IF NOT EXISTS job_team (
  job_id  int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  user_id int NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  PRIMARY KEY (job_id, user_id)
);

CREATE TABLE IF NOT EXISTS certificates (
  id              serial PRIMARY KEY,
  job_id          int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  type            text NOT NULL,
  engineer_id     int NOT NULL REFERENCES users(id),
  data            jsonb NOT NULL DEFAULT '{}',
  status          text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','issued','void')),
  outcome         text,
  engineer_name   text,
  engineer_scheme text,
  engineer_number text,
  engineer_categories text,
  declaration_name text,
  issued_at       timestamptz,
  next_due        date,
  sent_to         text,
  sent_at         timestamptz,
  void_reason     text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS certificates_job_idx ON certificates (job_id);
CREATE INDEX IF NOT EXISTS certificates_due_idx ON certificates (next_due) WHERE status = 'issued';

INSERT INTO email_templates (status, subject, body) VALUES
 ('cert_issued', 'Your {cert_name} ({cert_number})', E'Hi {first_name},\n\nPlease find attached your {cert_name}, number {cert_number}, for {job_title}.\n\nPlease keep it somewhere safe. You can also download it any time from your job page:\n{job_link}\n\nThanks,\n{business_name}')
ON CONFLICT (status) DO NOTHING;

-- Stage 7: password resets, photos in the database, backups, privacy
CREATE TABLE IF NOT EXISTS password_resets (
  id         serial PRIMARY KEY,
  user_id    int NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE job_photos ADD COLUMN IF NOT EXISTS data bytea;
ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_accepted_at timestamptz;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS privacy_notice text NOT NULL DEFAULT '';
CREATE TABLE IF NOT EXISTS backup_log (
  id             serial PRIMARY KEY,
  created_by     int REFERENCES users(id),
  include_photos boolean NOT NULL DEFAULT false,
  size_bytes     bigint,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- Update 2: calendar and inspection booking
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS inspection_at timestamptz;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS inspection_minutes int NOT NULL DEFAULT 60;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS inspection_builder_id int REFERENCES users(id);
CREATE INDEX IF NOT EXISTS jobs_inspection_idx ON jobs (inspection_at) WHERE inspection_at IS NOT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS calendar_token text UNIQUE;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS inspection_days text NOT NULL DEFAULT 'Mon,Tue,Wed,Thu,Fri';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS inspection_start text NOT NULL DEFAULT '09:00';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS inspection_end text NOT NULL DEFAULT '16:00';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS inspection_slot_minutes int NOT NULL DEFAULT 60;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS inspection_notice_hours int NOT NULL DEFAULT 24;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS inspection_horizon_days int NOT NULL DEFAULT 21;

UPDATE email_templates SET body = E'Hi {first_name},\n\nYour inspection visit for "{job_title}" is booked for {inspection_time}.\n\nIf you need to change it, you can do so from your job page up to a day before:\n{job_link}\n\nThanks,\n{business_name}'
WHERE status = 'inspection_booked' AND body NOT LIKE '%{inspection_time}%';
UPDATE email_templates SET body = E'Hi {first_name},\n\n"{job_title}" is booked in for {booked_dates}. You can see the details here:\n{job_link}\n\nThanks,\n{business_name}'
WHERE status = 'scheduled' AND body NOT LIKE '%{booked_dates}%';
INSERT INTO email_templates (status, subject, body) VALUES
 ('inspection_cancelled', 'Your inspection visit has been cancelled ({job_ref})', E'Hi {first_name},\n\nThe inspection visit for "{job_title}" has been cancelled. You can book a new time from your job page:\n{job_link}\n\nThanks,\n{business_name}')
ON CONFLICT (status) DO NOTHING;
HANDYTRIO_EOF

cat > src/format.js <<'HANDYTRIO_EOF'
// Dates and times always show in UK time, whatever time zone the server runs in.
const TZ = 'Europe/London';
const pad = (n) => String(n).padStart(2, '0');

const ref = (id) => 'HT-' + String(id).padStart(5, '0');
const day = (d) => (d ? new Date(d).toLocaleDateString('en-GB', { timeZone: TZ, day: 'numeric', month: 'short', year: 'numeric' }) : '');
const when = (d) => (d ? new Date(d).toLocaleString('en-GB', { timeZone: TZ, day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '');
const longWhen = (d) => (d ? new Date(d).toLocaleString('en-GB', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long', hour: 'numeric', minute: '2-digit', hour12: true }).replace(' at ', ' at ') : '');
const timeOnly = (d) => new Date(d).toLocaleTimeString('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit' });

// The calendar date (YYYY-MM-DD) of an instant, in UK time.
const ukDate = (d) => new Date(d).toLocaleDateString('en-CA', { timeZone: TZ });

// Minutes the UK is ahead of UTC at a given instant (0 in winter, 60 in summer).
function ukOffset(date) {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: TZ, hour12: false, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(date);
  const g = (t) => Number(parts.find((p) => p.type === t).value);
  return (Date.UTC(g('year'), g('month') - 1, g('day'), g('hour') % 24, g('minute'), g('second')) - date.getTime()) / 60000;
}

// The instant of a UK wall-clock time, e.g. ukTime('2026-07-01', '09:30').
function ukTime(dateISO, hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  const guess = new Date(`${dateISO}T${pad(h)}:${pad(m)}:00Z`);
  return new Date(guess.getTime() - ukOffset(guess) * 60000);
}

// Adds whole days to a YYYY-MM-DD date.
function addDays(dateISO, n) {
  const d = new Date(`${dateISO}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

const WORK_TYPES = [
  'Carpentry and joinery',
  'Doors and windows',
  'Plumbing',
  'Electrical',
  'Painting and decorating',
  'Tiling and flooring',
  'Plastering',
  'Fencing, decking and garden',
  'Roofing and guttering',
  'Something else',
];

module.exports = { TZ, ref, day, when, longWhen, timeOnly, ukDate, ukTime, ukOffset, addDays, WORK_TYPES };
HANDYTRIO_EOF

cat > src/notify.js <<'HANDYTRIO_EOF'
// Customer emails. Sends through SMTP when it is set up in .env, and logs every email either way.
const nodemailer = require('nodemailer');
const { query } = require('./db');
const { label } = require('./statuses');
const { ref, day, longWhen } = require('./format');
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

async function sendEmail({ to, subject, body, jobId = null, attachments = [], logBody = null }) {
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
      await t.sendMail({ from: process.env.SMTP_FROM || process.env.SMTP_USER, to, subject, text: body, attachments });
    } catch (e) {
      status = 'failed';
      error = String(e.message || e).slice(0, 300);
    }
  }
  await query('INSERT INTO email_log (job_id, to_address, subject, body, status, error) VALUES ($1, $2, $3, $4, $5, $6)',
    [jobId, to || null, subject, (logBody || body) + (attachments.length ? `\n\n[Attached: ${attachments.map((a) => a.filename).join(', ')}]` : ''), status, error]);
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
      inspection_time: job.inspection_at ? longWhen(job.inspection_at) : 'a time we will confirm with you',
      booked_dates: job.scheduled_start
        ? `${day(job.scheduled_start)}${job.scheduled_end && day(job.scheduled_end) !== day(job.scheduled_start) ? ` to ${day(job.scheduled_end)}` : ''}`
        : 'dates we will confirm with you',
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

const PLACEHOLDERS = ['inspection_time', 'booked_dates', 'cert_name', 'cert_number', 'first_name', 'customer_name', 'job_ref', 'job_title', 'stage', 'price_guide', 'job_link', 'business_name'];

module.exports = { jobVars, notifyStageChange, notifyOffice, sendEmail, fill, emailReady, PLACEHOLDERS };
HANDYTRIO_EOF

cat > src/layout.js <<'HANDYTRIO_EOF'
const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin' };

function nav(user) {
  if (!user) return '<a href="/login">Log in</a><a href="/register">Create account</a>';
  const links = ['<a href="/dashboard">Dashboard</a>'];
  if (user.role !== 'customer') links.push(`<a href="/jobs">${user.role === 'admin' ? 'All jobs' : 'My jobs'}</a>`, `<a href="/calendar">${user.role === 'admin' ? 'Calendar' : 'My diary'}</a>`);
  if (user.role === 'admin') {
    links.push('<a href="/admin/certificates">Certificates</a>', '<a href="/admin/templates">Pricing</a>', '<a href="/admin/users">People</a>', '<a href="/admin/emails">Emails</a>', '<a href="/admin/backups">Backups</a>', '<a href="/admin/settings">Settings</a>');
  }
  links.push('<a href="/account">My account</a>');
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
<script src="/js/photos.js" defer></script>
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
<footer class="foot"><a href="/privacy">Privacy notice</a></footer>
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
app.use(require('./routes/joblist'));
app.use(require('./routes/jobs'));
app.use(require('./routes/pricing'));
app.use(require('./routes/onsite').router);
app.use(require('./routes/quotes').router);
app.use(require('./routes/workflow').router);
app.use(require('./routes/certs').router);
app.use(require('./routes/backups'));
app.use(require('./routes/calendar').router);
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

cat > src/routes/calendar.js <<'HANDYTRIO_EOF'
// The calendar: inspection booking (by customers or the office), the week view,
// and a live calendar feed for phones (iPhone, Google, Outlook).
const express = require('express');
const crypto = require('crypto');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day, longWhen, timeOnly, ukDate, ukTime, addDays } = require('../format');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange, notifyOffice } = require('../notify');
const { locate } = require('../estimate');

const router = express.Router();
const staff = requireRole('admin', 'builder');
const N = (x) => Number(x) || 0;
const DAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const BOOKABLE = ['request', 'estimated', 'inspection_required', 'inspection_booked'];
const ACTIVE_WORK = ['scheduled', 'in_progress', 'parts_ordered'];
const validTime = (t, fallback) => (/^([01]\d|2[0-3]):[0-5]\d$/.test(t || '') ? t : fallback);
const weekdayOf = (iso) => new Date(`${iso}T12:00:00Z`).getUTCDay();

// ======================= Inspection slots =======================
async function bookingRules() {
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const days = String(s.inspection_days || '').split(/[\s,]+/).map((d) => DAY_NAMES.findIndex((n) => n.toLowerCase() === d.slice(0, 3).toLowerCase())).filter((i) => i >= 0);
  return {
    s,
    days: days.length ? days : [1, 2, 3, 4, 5],
    start: validTime(s.inspection_start, '09:00'),
    end: validTime(s.inspection_end, '16:00'),
    slot: Math.min(240, Math.max(15, N(s.inspection_slot_minutes) || 60)),
    notice: Math.max(0, N(s.inspection_notice_hours)),
    horizon: Math.min(90, Math.max(1, N(s.inspection_horizon_days) || 21)),
  };
}

// Every open slot from now to the booking horizon, with the builders free for each.
async function openSlots(excludeJobId = 0) {
  const r = await bookingRules();
  const now = Date.now();
  const earliest = now + r.notice * 3600000;
  const today = ukDate(new Date());
  const lastDay = addDays(today, r.horizon);
  const builders = (await query("SELECT id, name, postcode FROM users WHERE role = 'builder' AND active ORDER BY id")).rows;
  const inspections = (await query(
    `SELECT inspection_at, inspection_minutes, inspection_builder_id FROM jobs
     WHERE inspection_at IS NOT NULL AND inspection_at >= now() - interval '1 day' AND id <> $1 AND status NOT IN ('cancelled', 'declined')`, [excludeJobId])).rows;
  const work = (await query(
    `SELECT assigned_builder_id, scheduled_start, coalesce(scheduled_end, scheduled_start) AS scheduled_end FROM jobs
     WHERE status = ANY($1) AND scheduled_start IS NOT NULL AND assigned_builder_id IS NOT NULL`, [ACTIVE_WORK])).rows;
  const busyOnDay = (bid, iso) => work.some((w) => w.assigned_builder_id === bid && ukDate(w.scheduled_start) <= iso && iso <= ukDate(w.scheduled_end));

  const days = [];
  for (let iso = today; iso <= lastDay; iso = addDays(iso, 1)) {
    if (!r.days.includes(weekdayOf(iso))) continue;
    const slots = [];
    const endAt = ukTime(iso, r.end).getTime();
    for (let t = ukTime(iso, r.start).getTime(); t + r.slot * 60000 <= endAt; t += r.slot * 60000) {
      if (t < earliest) continue;
      const tEnd = t + r.slot * 60000;
      const free = builders.filter((b) => !busyOnDay(b.id, iso) && !inspections.some((i) => i.inspection_builder_id === b.id
        && new Date(i.inspection_at).getTime() < tEnd && new Date(i.inspection_at).getTime() + N(i.inspection_minutes) * 60000 > t));
      if (free.length) slots.push({ at: new Date(t), free });
    }
    if (slots.length) days.push({ iso, slots });
  }
  return { rules: r, days };
}

// Of the builders free for a slot, send the one who lives nearest the job.
async function nearestBuilder(free, postcode) {
  const to = await locate(postcode);
  if (!to) return free[0];
  let best = free[0];
  let bestD = Infinity;
  for (const b of free) {
    const from = b.postcode ? await locate(b.postcode) : null;
    if (!from) continue;
    const d = (from.lat - to.lat) ** 2 + ((from.lng - to.lng) * Math.cos((to.lat * Math.PI) / 180)) ** 2;
    if (d < bestD) { bestD = d; best = b; }
  }
  return best;
}

const canBook = (user, job) => BOOKABLE.includes(job.status) && (user.role === 'admin' || (user.role === 'customer' && job.customer_id === user.id));

// ======================= Panel on the job page =======================
async function inspectionPanel(job, user) {
  const r = await bookingRules();
  const booked = job.inspection_at && job.status === 'inspection_booked';
  const lateToChange = booked && new Date(job.inspection_at).getTime() - Date.now() < r.notice * 3600000;
  if (booked) {
    const inspector = job.inspection_builder_id ? (await query('SELECT name FROM users WHERE id = $1', [job.inspection_builder_id])).rows[0] : null;
    const mayChange = canBook(user, job) && (user.role === 'admin' || !lateToChange);
    return `<section class="panel callout" id="inspection">
      <h2>Inspection visit</h2>
      <p class="bigprice">${esc(longWhen(job.inspection_at))}</p>
      <p>${inspector ? `${user.role === 'customer' ? 'With' : 'Inspector:'} ${esc(user.role === 'customer' ? inspector.name.split(' ')[0] : inspector.name)}. ` : ''}About ${N(job.inspection_minutes)} minutes.</p>
      ${mayChange ? `<div class="buttons"><a class="button" href="/jobs/${job.id}/inspection">Change time</a>
        <form method="post" action="/jobs/${job.id}/inspection/cancel" class="inline"><button class="small danger">Cancel visit</button></form></div>`
        : user.role === 'customer' ? '<p class="hint">It’s too close to the visit to change it online. Please call us.</p>' : ''}
    </section>`;
  }
  if (!canBook(user, job) || !['inspection_required', 'estimated', 'request'].includes(job.status)) return '';
  return `<section class="panel callout" id="inspection">
    <h2>${user.role === 'customer' ? 'Book your inspection visit' : 'Inspection visit'}</h2>
    <p>${user.role === 'customer' ? 'Pick a time for us to come and look at the job, so we can give you an exact quote.' : 'Not booked yet.'}</p>
    <a class="button primary" href="/jobs/${job.id}/inspection">${user.role === 'customer' ? 'Choose a time' : 'Book an inspection'}</a>
  </section>`;
}

// ======================= Booking pages =======================
router.get('/jobs/:id/inspection', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !canBook(req.user, job)) return notFound(req, res);
  const { rules, days } = await openSlots(job.id);
  const isAdmin = req.user.role === 'admin';
  const picker = days.length ? days.map((d) => `<div class="slotday">
      <h3>${esc(new Date(`${d.iso}T12:00:00Z`).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' }))}</h3>
      <div class="slots">${d.slots.map((s) => `<form method="post" action="/jobs/${job.id}/inspection" class="inline">
        <input type="hidden" name="at" value="${s.at.toISOString()}"><button class="slot">${timeOnly(s.at)}</button></form>`).join('')}</div>
    </div>`).join('')
    : `<p class="empty">No times are free in the next ${rules.horizon} days. ${isAdmin ? 'Book a time by hand below.' : 'Please call us and we’ll fit you in.'}</p>`;
  const builders = isAdmin ? (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows : [];
  const manual = isAdmin ? `<h2>Book a time by hand</h2>
    <form method="post" action="/jobs/${job.id}/inspection" class="panel schedule">
      <label>Date<input type="date" name="date" required></label>
      <label>Time<input type="time" name="time" required step="300"></label>
      <label>Inspector<select name="builder_id">${builders.map((b) => `<option value="${b.id}" ${b.id === job.assigned_builder_id ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}</select></label>
      <button class="primary">Book</button>
    </form>` : '';
  const body = `<p class="jobhead"><a href="/jobs/${job.id}">Back to the job</a></p>
    <p class="lead">Visits take about ${rules.slot} minutes. ${isAdmin ? 'Tapping a time books the nearest free builder.' : 'Tap a time to book it.'}</p>
    ${picker}${manual}`;
  res.send(page({ title: `Book an inspection: ${job.title}`, user: req.user, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
}));

router.post('/jobs/:id/inspection', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !canBook(req.user, job)) return notFound(req, res);
  const { rules, days } = await openSlots(job.id);
  let at = null;
  let builder = null;

  if (req.user.role === 'admin' && req.body.date) {
    // Office booking by hand: any date and time, any builder.
    if (!/^\d{4}-\d{2}-\d{2}$/.test(req.body.date) || !/^\d{2}:\d{2}$/.test(req.body.time || '')) return res.redirect(`/jobs/${job.id}/inspection?error=${encodeURIComponent('Choose a date and time.')}`);
    at = ukTime(req.body.date, req.body.time);
    builder = (await query("SELECT id, name FROM users WHERE id = $1 AND role = 'builder' AND active", [Number(req.body.builder_id) || 0])).rows[0];
    if (!builder) return res.redirect(`/jobs/${job.id}/inspection?error=${encodeURIComponent('Choose an inspector.')}`);
  } else {
    const wanted = new Date(String(req.body.at || '')).getTime();
    const slot = days.flatMap((d) => d.slots).find((s) => s.at.getTime() === wanted);
    if (!slot) return res.redirect(`/jobs/${job.id}/inspection?error=${encodeURIComponent('Sorry, that time has just gone. Please pick another.')}`);
    at = slot.at;
    builder = await nearestBuilder(slot.free, job.postcode);
  }

  const wasBooked = job.status === 'inspection_booked';
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE jobs SET inspection_at = $1, inspection_minutes = $2, inspection_builder_id = $3, updated_at = now() WHERE id = $4',
      [at, rules.slot, builder.id, job.id]);
    // The inspector needs to open the job.
    if (builder.id !== job.assigned_builder_id) {
      await client.query('INSERT INTO job_team (job_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [job.id, builder.id]);
    }
    await setStatus(client, job.id, job.status, 'inspection_booked', req.user.id,
      `Inspection ${wasBooked ? 'moved to' : 'booked for'} ${longWhen(at)} with ${builder.name}${req.user.role === 'customer' ? ' (booked by the customer)' : ''}`);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyStageChange(job.id, 'inspection_booked', baseUrlOf(req));
  if (req.user.role === 'customer') {
    await notifyOffice(`Inspection ${wasBooked ? 'moved' : 'booked'}: ${job.title} (${ref(job.id)})`,
      `${job.customer_name} ${wasBooked ? 'moved their' : 'booked an'} inspection for ${longWhen(at)}. ${builder.name} has been given it as the nearest free builder.\n\n${baseUrlOf(req)}/jobs/${job.id}`, job.id);
  }
  res.redirect(`/jobs/${job.id}?updated=1#inspection`);
}));

router.post('/jobs/:id/inspection/cancel', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !canBook(req.user, job) || job.status !== 'inspection_booked') return notFound(req, res);
  const r = await bookingRules();
  if (req.user.role !== 'admin' && new Date(job.inspection_at).getTime() - Date.now() < r.notice * 3600000) return res.redirect(`/jobs/${job.id}#inspection`);
  const back = job.estimate_snapshot ? 'estimated' : 'inspection_required';
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE jobs SET inspection_at = NULL, inspection_builder_id = NULL, updated_at = now() WHERE id = $1', [job.id]);
    await setStatus(client, job.id, job.status, back, req.user.id, `Inspection cancelled${req.user.role === 'customer' ? ' by the customer' : ''}`);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyStageChange(job.id, 'inspection_cancelled', baseUrlOf(req));
  if (req.user.role === 'customer') {
    await notifyOffice(`Inspection cancelled: ${job.title} (${ref(job.id)})`, `${job.customer_name} cancelled their inspection visit.\n\n${baseUrlOf(req)}/jobs/${job.id}`, job.id);
  }
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

// ======================= Week view =======================
const mondayOf = (iso) => addDays(iso, -((weekdayOf(iso) + 6) % 7));

async function eventsBetween(fromISO, toISO, userId = null) {
  const who = userId ? 'AND (j.inspection_builder_id = $3)' : '';
  const inspections = (await query(
    `SELECT j.id, j.title, j.postcode, j.address_line, j.town, j.inspection_at, j.inspection_minutes, j.inspection_builder_id AS builder_id,
       c.name AS customer_name, c.phone AS customer_phone
     FROM jobs j JOIN users c ON c.id = j.customer_id
     WHERE j.status = 'inspection_booked' AND j.inspection_at >= $1 AND j.inspection_at < $2 ${who}`,
    userId ? [ukTime(fromISO, '00:00'), ukTime(addDays(toISO, 1), '00:00'), userId] : [ukTime(fromISO, '00:00'), ukTime(addDays(toISO, 1), '00:00')])).rows
    .map((e) => ({ ...e, kind: 'inspection', start: ukDate(e.inspection_at), end: ukDate(e.inspection_at) }));
  const whoW = userId ? 'AND (j.assigned_builder_id = $3 OR j.id IN (SELECT job_id FROM job_team WHERE user_id = $3))' : '';
  const work = (await query(
    `SELECT j.id, j.title, j.postcode, j.address_line, j.town, j.status, j.scheduled_start, coalesce(j.scheduled_end, j.scheduled_start) AS scheduled_end,
       j.assigned_builder_id AS builder_id, c.name AS customer_name, c.phone AS customer_phone
     FROM jobs j JOIN users c ON c.id = j.customer_id
     WHERE j.scheduled_start IS NOT NULL AND j.status NOT IN ('cancelled', 'declined')
       AND j.scheduled_start <= $2::date AND coalesce(j.scheduled_end, j.scheduled_start) >= $1::date ${whoW}`,
    userId ? [fromISO, toISO, userId] : [fromISO, toISO])).rows
    .map((e) => ({ ...e, kind: 'work', start: ukDate(e.scheduled_start), end: ukDate(e.scheduled_end) }));
  return [...inspections, ...work];
}

function eventChip(e) {
  return e.kind === 'inspection'
    ? `<a class="ev insp" href="/jobs/${e.id}"><strong>${timeOnly(e.inspection_at)} Inspection</strong><span>${esc(e.title)}</span><span class="muted">${esc(e.postcode)}</span></a>`
    : `<a class="ev work ${e.status === 'in_progress' ? 'live' : ''}" href="/jobs/${e.id}"><strong>${e.status === 'complete' || e.status === 'invoiced' || e.status === 'paid' ? 'Done' : 'Job'}</strong><span>${esc(e.title)}</span><span class="muted">${esc(e.postcode)}</span></a>`;
}

router.get('/calendar', staff, wrap(async (req, res) => {
  const user = req.user;
  const isAdmin = user.role === 'admin';
  const today = ukDate(new Date());
  const start = mondayOf(/^\d{4}-\d{2}-\d{2}$/.test(req.query.week || '') ? req.query.week : today);
  const days = Array.from({ length: 7 }, (_, i) => addDays(start, i));
  const events = await eventsBetween(days[0], days[6], isAdmin ? null : user.id);
  const sortEv = (a, b) => (a.kind === b.kind ? 0 : a.kind === 'inspection' ? 1 : -1) || (a.inspection_at && b.inspection_at ? new Date(a.inspection_at) - new Date(b.inspection_at) : 0);
  const on = (list, iso) => list.filter((e) => e.start <= iso && iso <= e.end).sort(sortEv);
  const dayHead = (iso) => `${new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' })}`;
  const nav = `<nav class="weeknav">
    <a class="button" href="/calendar?week=${addDays(start, -7)}">Previous week</a>
    <a class="button" href="/calendar">This week</a>
    <a class="button" href="/calendar?week=${addDays(start, 7)}">Next week</a>
  </nav>`;

  let grid;
  if (isAdmin) {
    const builders = (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows;
    grid = `<div class="scroll"><table class="week">
      <thead><tr><th>Builder</th>${days.map((d) => `<th class="${d === today ? 'today' : ''}">${dayHead(d)}</th>`).join('')}</tr></thead>
      <tbody>${builders.map((b) => `<tr><th>${esc(b.name)}</th>${days.map((d) => `<td class="${d === today ? 'today' : ''}">${on(events.filter((e) => e.builder_id === b.id), d).map(eventChip).join('')}</td>`).join('')}</tr>`).join('')}
      </tbody></table></div>`;
  } else {
    grid = `<div class="agenda">${days.map((d) => {
      const list = on(events, d);
      return `<section class="aday ${d === today ? 'today' : ''}"><h3>${dayHead(d)}${d === today ? ' <span class="tag">Today</span>' : ''}</h3>
        ${list.length ? list.map(eventChip).join('') : '<p class="muted">Nothing booked</p>'}</section>`;
    }).join('')}</div>`;
  }

  // Live calendar feed link.
  let token = (await query('SELECT calendar_token FROM users WHERE id = $1', [user.id])).rows[0].calendar_token;
  if (!token) {
    token = crypto.randomBytes(24).toString('hex');
    await query('UPDATE users SET calendar_token = $1 WHERE id = $2', [token, user.id]);
  }
  const httpsUrl = `${baseUrlOf(req)}/calendar/feed/${token}.ics`;
  const webcal = httpsUrl.replace(/^https?:/, 'webcal:');
  const feed = `<details class="panel feed"><summary><strong>Show this in my phone’s calendar</strong></summary>
    <p>Subscribing adds ${isAdmin ? 'every booked job and inspection' : 'your booked jobs and inspections'} to your phone’s calendar, and keeps it up to date automatically.</p>
    <p><a class="button primary" href="${esc(webcal)}">Subscribe on iPhone or Mac</a></p>
    <p class="hint">For Google Calendar or Outlook, choose “Add calendar from URL” and paste this link:</p>
    <input readonly value="${esc(httpsUrl)}">
    <p class="hint">Keep this link private: anyone with it can see the diary. If it gets shared by mistake, make a new one.</p>
    <form method="post" action="/calendar/new-link" class="inline"><button class="small">Make a new link</button></form>
  </details>`;

  const body = `${nav}<h2>Week of ${day(start)}</h2>${grid}${feed}`;
  res.send(page({ title: isAdmin ? 'Calendar' : 'My diary', user, body }));
}));

router.post('/calendar/new-link', staff, wrap(async (req, res) => {
  await query('UPDATE users SET calendar_token = $1 WHERE id = $2', [crypto.randomBytes(24).toString('hex'), req.user.id]);
  res.redirect('/calendar');
}));

// ======================= Calendar feed (.ics) =======================
const icsEscape = (s) => String(s ?? '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
const icsStamp = (d) => new Date(d).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
const icsDate = (iso) => iso.replace(/-/g, '');
function fold(line) {
  const out = [];
  let rest = line;
  while (Buffer.byteLength(rest) > 74) {
    let cut = 74;
    while (Buffer.byteLength(rest.slice(0, cut)) > 74) cut--;
    out.push(rest.slice(0, cut));
    rest = ' ' + rest.slice(cut);
  }
  out.push(rest);
  return out.join('\r\n');
}

router.get('/calendar/feed/:token.ics', wrap(async (req, res) => {
  const token = String(req.params.token || '');
  const u = /^[a-f0-9]{48}$/.test(token) ? (await query("SELECT id, role, name FROM users WHERE calendar_token = $1 AND active AND role IN ('admin', 'builder')", [token])).rows[0] : null;
  if (!u) return res.sendStatus(404);
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  const today = ukDate(new Date());
  const events = await eventsBetween(addDays(today, -30), addDays(today, 180), u.role === 'admin' ? null : u.id);
  const base = baseUrlOf(req);
  const names = Object.fromEntries((await query("SELECT id, name FROM users WHERE role = 'builder'")).rows.map((b) => [b.id, b.name]));
  const now = icsStamp(new Date());
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', `PRODID:-//${s.business_name}//TheHandyTrio//EN`, 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    `X-WR-CALNAME:${icsEscape(`${s.business_name}${u.role === 'admin' ? '' : `: ${u.name}`}`)}`, 'X-PUBLISHED-TTL:PT1H', 'REFRESH-INTERVAL;VALUE=DURATION:PT1H'];
  for (const e of events) {
    const address = [e.address_line, e.town, e.postcode].filter(Boolean).join(', ');
    const desc = `${e.customer_name}${e.customer_phone ? `, ${e.customer_phone}` : ''}${u.role === 'admin' && names[e.builder_id] ? `\nBuilder: ${names[e.builder_id]}` : ''}\n${base}/jobs/${e.id}`;
    lines.push('BEGIN:VEVENT', `UID:job-${e.id}-${e.kind}@thehandytrio`, `DTSTAMP:${now}`);
    if (e.kind === 'inspection') {
      lines.push(`DTSTART:${icsStamp(e.inspection_at)}`, `DTEND:${icsStamp(new Date(new Date(e.inspection_at).getTime() + N(e.inspection_minutes) * 60000))}`,
        `SUMMARY:${icsEscape(`Inspection: ${e.title}${u.role === 'admin' && names[e.builder_id] ? ` (${names[e.builder_id]})` : ''}`)}`);
    } else {
      lines.push(`DTSTART;VALUE=DATE:${icsDate(e.start)}`, `DTEND;VALUE=DATE:${icsDate(addDays(e.end, 1))}`,
        `SUMMARY:${icsEscape(`Job: ${e.title}${u.role === 'admin' && names[e.builder_id] ? ` (${names[e.builder_id]})` : ''}`)}`, 'TRANSP:TRANSPARENT');
    }
    lines.push(`LOCATION:${icsEscape(address)}`, `DESCRIPTION:${icsEscape(desc)}`, `URL:${base}/jobs/${e.id}`, 'END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  res.setHeader('Content-Type', 'text/calendar; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  res.send(lines.map(fold).join('\r\n') + '\r\n');
}));

module.exports = { router, inspectionPanel, openSlots, eventsBetween, eventChip };
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
const certs = require('./certs');
const calendar = require('./calendar');

const router = express.Router();

// ---------- Photo uploads ----------
// Photos are stored in the database, so they survive app updates and are included in backups.
// Phones shrink them to about 1600px before upload (see public/js/photos.js), so each is a few hundred KB.
const UPLOAD_DIR = path.join(__dirname, '..', '..', 'uploads'); // older photos saved before this change
const MAX_PHOTOS = 8;
const MAX_MB = 15;

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_MB * 1024 * 1024, files: MAX_PHOTOS, fields: 40 },
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

const removeFiles = () => {}; // nothing on disk to tidy up any more

async function savePhotos(client, jobId, files, userId) {
  for (const f of files) {
    await client.query(
      'INSERT INTO job_photos (job_id, stored_name, original_name, mime_type, size_bytes, uploaded_by, data) VALUES ($1, $2, $3, $4, $5, $6, $7)',
      [jobId, crypto.randomUUID(), String(f.originalname || 'photo').slice(0, 200), f.mimetype, f.size, userId, f.buffer]
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
    <label>Photos (up to ${MAX_PHOTOS})<input type="file" name="photos" accept="image/*" multiple data-shrink></label>
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
        <input type="file" name="photos" accept="image/*" multiple required data-shrink>
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
  ${await calendar.inspectionPanel(job, user)}
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
  ${await certs.certificatesPanel(job, user)}
  ${await certs.teamPanel(job, user)}
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
  const { rows } = await query('SELECT stored_name, mime_type, data FROM job_photos WHERE id = $1 AND job_id = $2', [Number(req.params.photoId) || 0, job.id]);
  if (!rows[0]) return res.sendStatus(404);
  res.set('Cache-Control', 'private, max-age=86400');
  res.type(rows[0].mime_type);
  if (rows[0].data) return res.send(rows[0].data);
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
const { ref, day, ukDate, addDays } = require('../format');

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
      `${JOB_SELECT} WHERE (j.assigned_builder_id = $1 OR j.id IN (SELECT job_id FROM job_team WHERE user_id = $1)) AND j.status <> ALL($2) ORDER BY coalesce(j.scheduled_start, j.preferred_start) NULLS LAST, j.created_at`,
      [user.id, CLOSED]
    );
    const clocked = (await query(
      `SELECT t.job_id, t.started_at, j.title FROM job_time_entries t JOIN jobs j ON j.id = t.job_id
       WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
    const myQuals = (await query(
      `SELECT kind, expires FROM staff_qualifications WHERE user_id = $1 AND expires <= current_date + 30 ORDER BY expires`, [user.id])).rows;
    const qualWarn = myQuals.map((q) => `<div class="error">Your ${esc(q.kind === 'gas' ? 'Gas Safe' : q.kind === 'pat' ? 'PAT' : 'electrical scheme')} qualification ${new Date(q.expires) < new Date(new Date().toDateString()) ? 'has expired' : 'expires'} on ${day(q.expires)}. Send the office your renewal.</div>`).join('');
    const { eventsBetween, eventChip } = require('./calendar');
    const today = ukDate(new Date());
    const soon = (await eventsBetween(today, addDays(today, 6), user.id)).sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));
    const comingUp = `<h2>Coming up this week</h2>${soon.length ? `<div class="soon">${soon.map((e) => `<div><span class="muted">${e.start === today ? 'Today' : day(e.start)}</span>${eventChip(e)}</div>`).join('')}</div>` : '<p class="empty">Nothing booked in the next 7 days.</p>'}
      <p><a href="/calendar">Open my diary</a></p>`;
    const body = `${qualWarn}${clocked ? `<div class="notice">You’re clocked on to <a href="/jobs/${clocked.job_id}#time">${esc(clocked.title)}</a> since ${new Date(clocked.started_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}.</div>` : ''}
      ${comingUp}
      <h2>Your jobs</h2>
      ${jobsTable(rows, { showCustomer: true }) || '<p class="empty">No jobs assigned to you yet. The office will assign them here.</p>'}
      <p><a class="button" href="/jobs?show=finished">See my past jobs</a></p>`;
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
  const quals = (await query(
    `SELECT q.kind, q.expires, u.id AS user_id, u.name FROM staff_qualifications q JOIN users u ON u.id = q.user_id
     WHERE u.active AND q.expires <= current_date + 30 ORDER BY q.expires`)).rows;
  const certsDue = (await query(
    `SELECT count(*)::int AS n FROM certificates WHERE status = 'issued' AND next_due <= current_date + 30`)).rows[0].n;
  const lastBackup = (await query("SELECT max(created_at) AS t FROM backup_log")).rows[0].t;
  const backupDue = !lastBackup || Date.now() - new Date(lastBackup) > 7 * 86400000;
  const todoItems = [
    ...(backupDue ? [`<li><a href="/admin/backups"><strong>Download a backup</strong>: ${lastBackup ? `last one was ${day(lastBackup)}` : 'you haven’t made one yet'}</a></li>`] : []),
    ...quals.map((q) => `<li><a href="/admin/users/${q.user_id}"><strong>${new Date(q.expires) < new Date(new Date().toDateString()) ? 'Qualification expired' : 'Qualification expiring'}</strong>: ${esc(q.name)}, ${esc(q.kind === 'gas' ? 'Gas Safe' : q.kind === 'pat' ? 'PAT' : 'electrical scheme')}, ${day(q.expires)}</a></li>`),
    ...(certsDue ? [`<li><a href="/admin/certificates?due=1"><strong>Certificates due for renewal</strong>: ${certsDue} in the next 30 days or overdue</a></li>`] : []),
    ...actionRows.map((j) => `<li><a href="/jobs/${j.id}"><strong>${esc(ACTIONS.find((a) => a[0] === j.status)[1])}</strong>: ${esc(j.title)} (${ref(j.id)})</a>${j.urgent ? ' <span class="tag urgent">Urgent</span>' : ''}</li>`),
    ...overdue.map((i) => `<li><a href="/jobs/${i.job_id}#invoices"><strong>Chase overdue invoice</strong>: ${esc(i.title)} (${ref(i.job_id)})</a></li>`),
  ];
  const { eventsBetween, eventChip } = require('./calendar');
  const todayISO = ukDate(new Date());
  const todays = await eventsBetween(todayISO, todayISO);
  const todayBox = `<h2>Today</h2>${todays.length ? `<div class="soon">${todays.map(eventChip).join('')}</div>` : '<p class="empty">Nothing booked today.</p>'}<p><a href="/calendar">Open the calendar</a></p>`;
  const todo = `<h2>Needs your attention</h2>${todoItems.length ? `<ul class="todo">${todoItems.join('')}</ul>` : '<p class="empty">Nothing waiting on you right now.</p>'}`;

  const body = `
    ${!s.base_postcode && !s.builder_postcodes ? '<div class="error">Add your builders’ home postcodes on the <a href="/admin/users">People</a> page so travel costs can be worked out.</div>' : ''}
    ${todayBox}
    ${todo}
    <h2>Job pipeline</h2>
    <ol class="pipeline">${pipeline}</ol>
    <h2>Open jobs</h2>
    ${jobsTable(open.rows, { showCustomer: true, showBuilder: true }) || '<p class="empty">No open jobs. New customer requests will appear here.</p>'}
    <p><a class="button" href="/jobs?show=finished">See finished and closed jobs</a></p>`;
  res.send(page({ title: 'Office dashboard', user, body }));
}));

module.exports = router;
HANDYTRIO_EOF

cat > src/routes/settings.js <<'HANDYTRIO_EOF'
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const privacyDefault = require('../privacy-default');

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
  ['Inspection bookings', [
    ['inspection_days', 'Days customers can book (e.g. Mon,Tue,Wed,Thu,Fri)', 'text'],
    ['inspection_start', 'First visit starts (24-hour, e.g. 09:00)', 'text'],
    ['inspection_end', 'Last visit finishes by (e.g. 16:00)', 'text'],
    ['inspection_slot_minutes', 'Length of a visit (minutes)', 'int', '5'],
    ['inspection_notice_hours', 'Minimum notice for booking or changing (hours)', 'int', '1'],
    ['inspection_horizon_days', 'How far ahead customers can book (days)', 'int', '1'],
  ]],
  ['Quotes and documents', [
    ['business_address', 'Business address (shown on quotes)', 'textarea'],
    ['business_phone', 'Business phone', 'text'],
    ['business_email', 'Business email', 'text'],
    ['quote_valid_days', 'Quotes valid for (days)', 'int', '1'],
    ['quote_terms', 'Terms printed on quotes', 'textarea'],
  ]],
  ['Privacy', [
    ['privacy_notice', 'Privacy notice shown to customers (review this so it matches how you work)', 'textarea'],
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
      ? `<label>${esc(lbl)}<textarea name="${key}" rows="${key === 'privacy_notice' ? 16 : 3}" maxlength="10000">${esc(s[key])}</textarea></label>`
      : `<label>${esc(lbl)}<input name="${key}" value="${esc(s[key])}" ${type === 'text' ? '' : `type="number" min="0" step="${step}" required`}></label>`
    ).join('')}
  </fieldset>`).join('');
  return `<form method="post" action="/admin/settings" class="settings">${groups}<button class="primary">Save settings</button></form>`;
}

router.get('/admin/settings', requireRole('admin'), wrap(async (req, res) => {
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  if (!s.privacy_notice) s.privacy_notice = privacyDefault(s);
  res.send(page({ title: 'Rates & settings', user: req.user, notice: req.query.saved ? 'Settings saved.' : null, body: form(s) }));
}));

router.post('/admin/settings', requireRole('admin'), wrap(async (req, res) => {
  const values = [];
  for (const [key, lbl, type] of FIELDS) {
    const raw = req.body[key];
    if (type === 'bool') values.push(raw === 'on');
    else if (type === 'text' || type === 'textarea') values.push(String(raw || '').replace(/\r\n/g, '\n').trim().slice(0, 10000));
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

cat > src/routes/emails.js <<'HANDYTRIO_EOF'
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { STATUSES, label } = require('../statuses');
const { when } = require('../format');
const { sendEmail, fill, emailReady, PLACEHOLDERS } = require('../notify');

const router = express.Router();
const admin = requireRole('admin');
const ORDER = [...STATUSES.map(([k]) => k), 'inspection_cancelled', 'cert_issued'];
const nameOf = (k) => ({ cert_issued: 'Certificate issued (PDF attached)', inspection_cancelled: 'Inspection cancelled' }[k] || label(k));

const sample = {
  first_name: 'Sam', customer_name: 'Sam Jones', job_ref: 'HT-00042', job_title: 'Hang an internal door',
  stage: 'Quote sent', inspection_time: 'Tuesday 14 January at 10:00 am', booked_dates: '20 Jan 2027 to 22 Jan 2027', cert_name: 'Landlord Gas Safety Record', cert_number: 'GSR-00007', price_guide: '£215.00 to £295.00 including VAT', job_link: 'https://example.com/jobs/42',
};

const tabs = (active) => `<nav class="subnav">
  <a href="/admin/emails" ${active === 'templates' ? 'aria-current="page"' : ''}>Customer emails</a>
  <a href="/admin/emails/log" ${active === 'log' ? 'aria-current="page"' : ''}>Sent emails</a></nav>`;

const setupNote = () => (emailReady() ? '' : `<div class="error">Email sending isn’t set up yet, so emails are only saved under <a href="/admin/emails/log">Sent emails</a>. Add your email account details to the .env file to start sending.</div>`);

router.get('/admin/emails', admin, wrap(async (req, res) => {
  const rows = (await query('SELECT * FROM email_templates')).rows.sort((a, b) => ORDER.indexOf(a.status) - ORDER.indexOf(b.status));
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  const vars = { ...sample, business_name: s.business_name };
  const body = `${tabs('templates')}${setupNote()}
    <p class="lead">The customer gets one of these each time their job moves stage. Office notes are never included.
    You can use: ${PLACEHOLDERS.map((p) => `<code>{${p}}</code>`).join(' ')}</p>
    <form method="post" action="/admin/emails/test" class="filters">
      <label>Send a test of<select name="status">${rows.map((t) => `<option value="${t.status}">${esc(nameOf(t.status))}</option>`).join('')}</select></label>
      <button class="small">Send test to ${esc(req.user.email)}</button>
    </form>
    ${rows.map((t) => `<details class="panel emailtpl" id="${t.status}">
      <summary><strong>${esc(nameOf(t.status))}</strong> <span class="tag">${t.enabled ? 'On' : 'Off'}</span> <span class="muted">${esc(fill(t.subject, vars))}</span></summary>
      <form method="post" action="/admin/emails/${t.status}">
        <label class="check"><input type="checkbox" name="enabled" ${t.enabled ? 'checked' : ''}> Send this email</label>
        <label>Subject<input name="subject" value="${esc(t.subject)}" maxlength="200" required></label>
        <label>Message<textarea name="body" rows="9" maxlength="5000" required>${esc(t.body)}</textarea></label>
        <button class="small">Save</button>
      </form>
      <p class="hint">Preview</p>
      <div class="preview">${esc(fill(t.body, vars))}</div>
    </details>`).join('')}`;
  const notice = req.query.saved ? 'Email saved.' : req.query.test ? `Test ${String(req.query.test).slice(0, 40)}.` : null;
  res.send(page({ title: 'Customer emails', user: req.user, notice, body }));
}));

router.post('/admin/emails/test', admin, wrap(async (req, res) => {
  const t = (await query('SELECT * FROM email_templates WHERE status = $1', [String(req.body.status || '')])).rows[0];
  if (!t) return res.redirect('/admin/emails');
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  const vars = { ...sample, business_name: s.business_name };
  const r = await sendEmail({ to: req.user.email, subject: '[Test] ' + fill(t.subject, vars), body: fill(t.body, vars) });
  res.redirect('/admin/emails?test=' + encodeURIComponent(r.status === 'sent' ? 'sent' : `${r.status}: ${r.error}`));
}));

router.post('/admin/emails/:status', admin, wrap(async (req, res) => {
  const subject = String(req.body.subject || '').trim().slice(0, 200);
  const body = String(req.body.body || '').replace(/\r\n/g, '\n').trim().slice(0, 5000);
  if (subject && body) {
    await query('UPDATE email_templates SET subject = $1, body = $2, enabled = $3 WHERE status = $4',
      [subject, body, req.body.enabled === 'on', req.params.status]);
  }
  res.redirect(`/admin/emails?saved=1#${encodeURIComponent(req.params.status)}`);
}));

router.get('/admin/emails/log', admin, wrap(async (req, res) => {
  const rows = (await query('SELECT * FROM email_log ORDER BY created_at DESC LIMIT 100')).rows;
  const body = `${tabs('log')}${setupNote()}
    ${rows.length ? rows.map((e) => `<details class="panel emailtpl">
      <summary>${when(e.created_at)} <span class="tag ${e.status === 'sent' ? '' : 'urgent'}">${esc(e.status)}</span> ${esc(e.to_address)} <span class="muted">${esc(e.subject)}</span></summary>
      ${e.job_id ? `<p><a href="/jobs/${e.job_id}">Open job</a></p>` : ''}
      ${e.error ? `<p class="muted">${esc(e.error)}</p>` : ''}
      <div class="preview">${esc(e.body)}</div>
    </details>`).join('') : '<p class="empty">No emails yet. They appear here as jobs move stage.</p>'}`;
  res.send(page({ title: 'Sent emails', user: req.user, body }));
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

/* Job history */
tr.closedjob td { color: var(--muted); }
tr.closedjob td a { color: var(--ink); }
.pager { display: flex; gap: 1rem; align-items: center; justify-content: center; margin: 1rem 0; }

/* Stage 6: certificates and qualifications */
.certlist { list-style: none; padding: 0; margin: 0 0 1rem; }
.certlist li { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; padding: .5rem 0; border-bottom: 1px solid var(--line); }
.certlist li:last-child { border-bottom: 0; }
a.button.small { padding: .25rem .6rem; font-size: .85rem; }
.certform { max-width: 1000px; }
.certform legend { font: 600 1.2rem "Barlow Condensed", Barlow, sans-serif; padding: 0 .3rem; }
.certgrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 0 1rem; }
.certgrid label { font-size: .9rem; }
.certitem { border-top: 1px solid var(--line); padding-top: .75rem; margin-top: .5rem; }
.certitem:first-of-type { border-top: 0; margin-top: 0; padding-top: 0; }
.certitem.new { opacity: .85; }
.certform .issue { border-left: 6px solid var(--hivis); }
.qual summary { cursor: pointer; display: flex; flex-wrap: wrap; gap: .5rem; align-items: baseline; }
.qual .qualform { margin: .75rem 0 .5rem; background: var(--bg); }

/* Stage 7 */
.foot { max-width: 1100px; margin: 2rem auto 0; padding: 1rem 1.25rem 2rem; border-top: 1px solid var(--line); color: var(--muted); font-size: .9rem; }
.prose { max-width: 75ch; line-height: 1.6; }

/* Update 2: calendar */
.weeknav { display: flex; flex-wrap: wrap; gap: .5rem; margin-bottom: .5rem; }
table.week { table-layout: fixed; min-width: 900px; }
table.week th, table.week td { white-space: normal; vertical-align: top; width: 12.5%; }
table.week td { padding: .4rem; }
table.week .today { background: color-mix(in srgb, var(--hivis) 12%, transparent); }
.ev { display: flex; flex-direction: column; gap: .05rem; text-decoration: none; font-size: .82rem; line-height: 1.25; padding: .35rem .45rem; border-radius: 4px; margin-bottom: .3rem; border-left: 4px solid var(--slate); background: var(--bg); }
.ev.insp { border-left-color: var(--hivis); }
.ev.work.live { border-left-color: #2e8b57; }
.agenda { display: grid; gap: .75rem; }
.aday { background: var(--surface); border: 1px solid var(--line); border-radius: 6px; padding: .6rem .8rem; }
.aday.today { border-color: var(--hivis); }
.aday h3 { margin: 0 0 .4rem; font: 600 1.05rem "Barlow Condensed", Barlow, sans-serif; }
.soon { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: .5rem; }
.slotday h3 { font: 600 1.1rem "Barlow Condensed", Barlow, sans-serif; margin: 1rem 0 .4rem; }
.slots { display: flex; flex-wrap: wrap; gap: .4rem; }
button.slot { background: var(--surface); border: 1px solid var(--line); border-radius: 4px; padding: .55rem .9rem; font-weight: 600; color: var(--ink); }
button.slot:hover, button.slot:focus-visible { background: var(--hivis); color: var(--hivis-ink); border-color: transparent; }
.feed { margin-top: 1.5rem; }
.feed summary { cursor: pointer; }
HANDYTRIO_EOF

echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "Calendar installed. The app restarts by itself; otherwise run: npm run dev"
