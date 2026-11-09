#!/usr/bin/env bash
# TheHandyTrio update 3 of 3: reports, repeat-business reminders, texts and review requests. Run with: bash growth.sh
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

-- Update 3: reports, reminders, texts and reviews
ALTER TABLE users ADD COLUMN IF NOT EXISTS cost_rate numeric;
ALTER TABLE users ADD COLUMN IF NOT EXISTS sms_opt_out boolean NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS marketing_opt_out boolean NOT NULL DEFAULT false;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS reminder_days_before int NOT NULL DEFAULT 30;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS review_link text NOT NULL DEFAULT '';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS review_delay_days int NOT NULL DEFAULT 2;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS texts_enabled boolean NOT NULL DEFAULT true;

CREATE TABLE IF NOT EXISTS reminders_sent (
  id      serial PRIMARY KEY,
  kind    text NOT NULL,
  ref_id  int NOT NULL,
  key     text NOT NULL DEFAULT '',
  status  text,
  sent_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, ref_id, key)
);

CREATE TABLE IF NOT EXISTS sms_templates (
  key     text PRIMARY KEY,
  body    text NOT NULL,
  enabled boolean NOT NULL DEFAULT true
);
INSERT INTO sms_templates (key, body) VALUES
 ('inspection_reminder', 'Hi {first_name}, a reminder that {business_name} are visiting tomorrow, {inspection_time}, to look at "{job_title}". Need to change? Call us or visit {job_link}'),
 ('job_reminder', 'Hi {first_name}, a reminder that {business_name} start "{job_title}" tomorrow. Please make sure we can get in. Questions? {job_link}')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS sms_log (
  id         serial PRIMARY KEY,
  job_id     int REFERENCES jobs(id) ON DELETE SET NULL,
  to_number  text,
  body       text,
  status     text NOT NULL,
  error      text,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO email_templates (status, subject, body) VALUES
 ('cert_due', 'Your {cert_name} is due soon', E'Hi {first_name},\n\nYour {cert_name} for {address} is due on {due_date}. Keeping it up to date keeps you safe{landlord_note}.\n\nBook your visit here, it only takes a minute:\n{book_link}\n\nThanks,\n{business_name}'),
 ('review_request', 'How did we do?', E'Hi {first_name},\n\nThanks again for choosing {business_name} for "{job_title}". If you were happy with the work, a quick review would really help a small local business like ours:\n\n{review_link}\n\nThank you,\n{business_name}')
ON CONFLICT (status) DO NOTHING;
HANDYTRIO_EOF

cat > src/sms.js <<'HANDYTRIO_EOF'
// Text messages through Twilio, when it is set up in .env. Every text is logged either way.
const { query } = require('./db');

const smsReady = () => Boolean(process.env.TWILIO_ACCOUNT_SID && process.env.TWILIO_AUTH_TOKEN && process.env.TWILIO_FROM);

// UK numbers to international format: 07700 900123 -> +447700900123.
function ukMobile(raw) {
  const d = String(raw || '').replace(/[^\d+]/g, '');
  if (/^\+447\d{9}$/.test(d)) return d;
  if (/^447\d{9}$/.test(d)) return '+' + d;
  if (/^07\d{9}$/.test(d)) return '+44' + d.slice(1);
  return null;
}

async function sendSms({ to, body, jobId = null }) {
  const number = ukMobile(to);
  let status = 'sent';
  let error = null;
  if (!number) {
    status = 'skipped';
    error = 'No UK mobile number';
  } else if (!smsReady()) {
    status = 'not sent';
    error = 'Text messages are not set up yet';
  } else {
    try {
      const sid = process.env.TWILIO_ACCOUNT_SID;
      const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
        method: 'POST',
        headers: {
          Authorization: 'Basic ' + Buffer.from(`${sid}:${process.env.TWILIO_AUTH_TOKEN}`).toString('base64'),
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({ To: number, From: process.env.TWILIO_FROM, Body: body.slice(0, 640) }).toString(),
        signal: AbortSignal.timeout(15000),
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        status = 'failed';
        error = String(data.message || `Twilio error ${res.status}`).slice(0, 300);
      }
    } catch (e) {
      status = 'failed';
      error = String(e.message || e).slice(0, 300);
    }
  }
  await query('INSERT INTO sms_log (job_id, to_number, body, status, error) VALUES ($1, $2, $3, $4, $5)', [jobId, number || to || null, body, status, error]);
  return { status, error };
}

module.exports = { sendSms, smsReady, ukMobile };
HANDYTRIO_EOF

cat > src/scheduler.js <<'HANDYTRIO_EOF'
// Runs every hour in the background: certificate renewal reminders, day-before texts and review requests.
// Each message is recorded in reminders_sent first, so nothing is ever sent twice.
const { query } = require('./db');
const { sendEmail, fill, jobVars } = require('./notify');
const { sendSms } = require('./sms');
const { TYPES } = require('./certtypes');
const { day, ukDate, addDays, TZ } = require('./format');

let lastBaseUrl = process.env.APP_URL || 'http://localhost:3000';
const rememberBaseUrl = (url) => { if (!process.env.APP_URL && url) lastBaseUrl = url; };

async function claim(kind, refId, key = '') {
  const r = await query('INSERT INTO reminders_sent (kind, ref_id, key) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING id', [kind, refId, key]);
  return r.rows[0] ? r.rows[0].id : null;
}
const mark = (id, status) => query('UPDATE reminders_sent SET status = $1 WHERE id = $2', [status, id]);
const ukHour = () => Number(new Date().toLocaleString('en-GB', { timeZone: TZ, hour: '2-digit', hour12: false }));

async function emailTemplate(key) {
  return (await query('SELECT * FROM email_templates WHERE status = $1 AND enabled', [key])).rows[0] || null;
}

async function certificateReminders(s, base, out) {
  const tpl = await emailTemplate('cert_due');
  if (!tpl) return;
  const due = (await query(
    `SELECT c.*, j.customer_id, j.address_line, j.town, j.postcode, u.marketing_opt_out
     FROM certificates c JOIN jobs j ON j.id = c.job_id JOIN users u ON u.id = j.customer_id
     WHERE c.status = 'issued' AND c.next_due IS NOT NULL AND u.active
       AND c.next_due <= current_date + $1::int AND c.next_due >= current_date - 30
       AND NOT EXISTS (SELECT 1 FROM certificates n JOIN jobs nj ON nj.id = n.job_id
         WHERE n.type = c.type AND n.status IN ('issued', 'draft') AND n.id > c.id AND nj.customer_id = j.customer_id AND nj.postcode IS NOT DISTINCT FROM j.postcode)`,
    [Number(s.reminder_days_before) || 30])).rows;
  for (const c of due) {
    if (c.marketing_opt_out || !TYPES[c.type]) continue;
    const id = await claim('cert_due', c.id);
    if (!id) continue;
    const data = await jobVars(c.job_id, 'paid', base);
    const vars = {
      ...data.vars,
      cert_name: TYPES[c.type].name,
      due_date: day(c.next_due),
      address: [c.address_line, c.town, c.postcode].filter(Boolean).join(', '),
      landlord_note: c.type === 'gas_safety' ? ' and keeps you legal as a landlord' : '',
      book_link: `${base}/rebook/${c.id}`,
    };
    const body = fill(tpl.body, vars) + `\n\nDon’t want reminders like this? Turn them off in your account: ${base}/account`;
    const r = await sendEmail({ to: data.job.customer_email, subject: fill(tpl.subject, vars), body, jobId: c.job_id });
    await mark(id, r.status);
    out.certificates++;
  }
}

async function dayBeforeTexts(s, base, out) {
  if (!s.texts_enabled) return;
  const hour = ukHour();
  if (hour < 9 || hour >= 20) return; // no texts at unsociable hours
  const tomorrow = addDays(ukDate(new Date()), 1);
  const tpls = Object.fromEntries((await query('SELECT * FROM sms_templates WHERE enabled')).rows.map((t) => [t.key, t]));

  const inspections = tpls.inspection_reminder ? (await query(
    `SELECT j.id, j.inspection_at, u.phone, u.sms_opt_out FROM jobs j JOIN users u ON u.id = j.customer_id
     WHERE j.status = 'inspection_booked' AND j.inspection_at IS NOT NULL`)).rows.filter((j) => ukDate(j.inspection_at) === tomorrow) : [];
  for (const j of inspections) {
    if (j.sms_opt_out || !j.phone) continue;
    const id = await claim('inspection_text', j.id, new Date(j.inspection_at).toISOString());
    if (!id) continue;
    const data = await jobVars(j.id, 'inspection_booked', base);
    const r = await sendSms({ to: j.phone, body: fill(tpls.inspection_reminder.body, data.vars), jobId: j.id });
    await mark(id, r.status);
    out.texts++;
  }

  const starts = tpls.job_reminder ? (await query(
    `SELECT j.id, j.scheduled_start, u.phone, u.sms_opt_out FROM jobs j JOIN users u ON u.id = j.customer_id
     WHERE j.status = 'scheduled' AND j.scheduled_start = $1::date`, [tomorrow])).rows : [];
  for (const j of starts) {
    if (j.sms_opt_out || !j.phone) continue;
    const id = await claim('job_text', j.id, tomorrow);
    if (!id) continue;
    const data = await jobVars(j.id, 'scheduled', base);
    const r = await sendSms({ to: j.phone, body: fill(tpls.job_reminder.body, data.vars), jobId: j.id });
    await mark(id, r.status);
    out.texts++;
  }
}

async function reviewRequests(s, base, out) {
  if (!s.review_link) return;
  const tpl = await emailTemplate('review_request');
  if (!tpl) return;
  const delay = Math.max(0, Number(s.review_delay_days) || 0);
  const jobs = (await query(
    `SELECT j.id, u.marketing_opt_out FROM jobs j JOIN users u ON u.id = j.customer_id
     WHERE j.status = 'paid' AND EXISTS (SELECT 1 FROM job_status_history h WHERE h.job_id = j.id AND h.to_status = 'paid'
       AND h.created_at <= now() - make_interval(days => $1::int) AND h.created_at >= now() - interval '30 days')`, [delay])).rows;
  for (const j of jobs) {
    if (j.marketing_opt_out) continue;
    const id = await claim('review', j.id);
    if (!id) continue;
    const data = await jobVars(j.id, 'paid', base);
    const vars = { ...data.vars, review_link: s.review_link };
    const body = fill(tpl.body, vars) + `\n\nDon’t want emails like this? Turn them off in your account: ${base}/account`;
    const r = await sendEmail({ to: data.job.customer_email, subject: fill(tpl.subject, vars), body, jobId: j.id });
    await mark(id, r.status);
    out.reviews++;
  }
}

let running = false;
async function runReminders() {
  if (running) return null;
  running = true;
  const out = { certificates: 0, texts: 0, reviews: 0 };
  try {
    const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
    await certificateReminders(s, lastBaseUrl, out);
    await dayBeforeTexts(s, lastBaseUrl, out);
    await reviewRequests(s, lastBaseUrl, out);
  } catch (e) {
    console.error('Reminders failed:', e);
  } finally {
    running = false;
  }
  return out;
}

function startScheduler() {
  setTimeout(runReminders, 60 * 1000);
  setInterval(runReminders, 60 * 60 * 1000);
}

module.exports = { runReminders, startScheduler, rememberBaseUrl };
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

// Remember the site's address so background reminders can link back to it.
const { rememberBaseUrl, startScheduler } = require('./scheduler');
app.use((req, res, next) => { rememberBaseUrl(`${req.protocol}://${req.get('host')}`); next(); });

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
app.use(require('./routes/repeat'));
app.use(require('./routes/reports'));
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
app.listen(port, () => {
  console.log(`TheHandyTrio running on port ${port}`);
  startScheduler();
});
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
    links.push('<a href="/admin/reports">Reports</a>', '<a href="/admin/certificates">Certificates</a>', '<a href="/admin/templates">Pricing</a>', '<a href="/admin/users">People</a>', '<a href="/admin/emails">Messages</a>', '<a href="/admin/backups">Backups</a>', '<a href="/admin/settings">Settings</a>');
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

cat > src/routes/reports.js <<'HANDYTRIO_EOF'
// Reports: money in, money owed, how well quotes convert, profit per job,
// and how accurate each job template's time estimate turns out to be.
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { ref, day, ukDate, ukTime, addDays } = require('../format');
const { money } = require('../estimate');

const router = express.Router();
const admin = requireRole('admin');
const N = (x) => Number(x) || 0;
const r2 = (n) => Math.round(n * 100) / 100;
const isDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d || '');
const pct = (a, b) => (b ? `${Math.round((a / b) * 100)}%` : 'n/a');

function period(q) {
  const today = ukDate(new Date());
  const [y, m] = today.split('-').map(Number);
  const first = (yy, mm) => `${yy}-${String(mm).padStart(2, '0')}-01`;
  const lastOf = (yy, mm) => addDays(mm === 12 ? first(yy + 1, 1) : first(yy, mm + 1), -1);
  const taxStartYear = today >= `${y}-04-06` ? y : y - 1;
  const presets = {
    this_month: ['This month', first(y, m), today],
    last_month: ['Last month', m === 1 ? first(y - 1, 12) : first(y, m - 1), m === 1 ? lastOf(y - 1, 12) : lastOf(y, m - 1)],
    tax_year: ['This tax year', `${taxStartYear}-04-06`, today],
    last_12: ['Last 12 months', addDays(today, -364), today],
  };
  if (q.preset === 'custom' && isDate(q.from) && isDate(q.to) && q.from <= q.to) return { key: 'custom', label: `${day(q.from)} to ${day(q.to)}`, from: q.from, to: q.to };
  const key = presets[q.preset] ? q.preset : 'this_month';
  const [label, from, to] = presets[key];
  return { key, label, from, to };
}

// Hours estimated for a job: the working estimate's labour hours, else the price guide's.
const ESTIMATED_HOURS = `coalesce(
  nullif((SELECT sum(l.qty) FROM job_estimate_lines l WHERE l.job_id = j.id AND l.category = 'labour' AND l.unit ~* '^h(ou)?rs?$'), 0),
  (j.estimate_snapshot -> 'labour' ->> 'estimatedHours')::numeric)`;
const ACTUAL_HOURS = `(SELECT sum(extract(epoch FROM (coalesce(t.ended_at, now()) - t.started_at)) / 3600) FROM job_time_entries t WHERE t.job_id = j.id)`;

router.get('/admin/reports', admin, wrap(async (req, res) => {
  const p = period(req.query);
  const fromTs = ukTime(p.from, '00:00');
  const toTs = ukTime(addDays(p.to, 1), '00:00');
  const s = (await query('SELECT currency, markup_pct FROM settings WHERE id = 1')).rows[0];
  const m = (n) => money(n, s.currency);

  // ---- Money ----
  const byMethod = (await query('SELECT method, sum(amount) AS total, count(*)::int AS n FROM payments WHERE received_at >= $1 AND received_at < $2 GROUP BY method ORDER BY total DESC', [fromTs, toTs])).rows;
  const takings = byMethod.reduce((a, r) => a + N(r.total), 0);
  const invoiced = N((await query("SELECT sum(total) AS t FROM invoices WHERE kind = 'final' AND status <> 'void' AND created_at >= $1 AND created_at < $2", [fromTs, toTs])).rows[0].t);
  const owed = (await query(
    `SELECT i.id, i.job_id, i.due_date, i.amount_due - coalesce((SELECT sum(amount) FROM payments p WHERE p.invoice_id = i.id), 0) AS left_to_pay
     FROM invoices i WHERE i.status = 'issued'`)).rows.filter((r) => N(r.left_to_pay) > 0.004);
  const today = new Date(new Date().toDateString());
  const ageing = { notDue: 0, d30: 0, d60: 0, older: 0 };
  for (const o of owed) {
    const late = o.due_date ? Math.floor((today - new Date(o.due_date)) / 86400000) : 0;
    const k = late <= 0 ? 'notDue' : late <= 30 ? 'd30' : late <= 60 ? 'd60' : 'older';
    ageing[k] += N(o.left_to_pay);
  }
  const owedTotal = Object.values(ageing).reduce((a, b) => a + b, 0);

  // Takings by month, last 12 months, for the bar chart.
  const monthly = (await query(
    `SELECT to_char(date_trunc('month', received_at AT TIME ZONE 'Europe/London'), 'YYYY-MM') AS mon, sum(amount) AS total
     FROM payments WHERE received_at >= now() - interval '12 months' GROUP BY 1 ORDER BY 1`)).rows;
  const months = [];
  for (let i = 11; i >= 0; i--) {
    const d = new Date();
    d.setDate(1);
    d.setMonth(d.getMonth() - i);
    const key = d.toISOString().slice(0, 7);
    months.push({ key, label: d.toLocaleDateString('en-GB', { month: 'short' }), total: N((monthly.find((x) => x.mon === key) || {}).total) });
  }
  const maxMonth = Math.max(1, ...months.map((x) => x.total));

  // ---- Sales ----
  const requests = (await query('SELECT count(*)::int AS n FROM jobs WHERE created_at >= $1 AND created_at < $2', [fromTs, toTs])).rows[0].n;
  const quoted = (await query("SELECT count(DISTINCT job_id)::int AS n FROM quotes WHERE created_at >= $1 AND created_at < $2", [fromTs, toTs])).rows[0].n;
  const answers = (await query(
    `SELECT count(*) FILTER (WHERE status = 'accepted')::int AS won, count(*) FILTER (WHERE status = 'declined')::int AS lost, avg(total) FILTER (WHERE status = 'accepted') AS avg_won
     FROM quotes WHERE responded_at >= $1 AND responded_at < $2`, [fromTs, toTs])).rows[0];

  // ---- Profit per job (finished in the period) ----
  const jobs = (await query(
    `SELECT j.id, j.title, b.name AS builder,
       (SELECT i.net FROM invoices i WHERE i.job_id = j.id AND i.kind = 'final' AND i.status <> 'void' ORDER BY i.id DESC LIMIT 1) AS invoiced_net,
       (SELECT q.net FROM quotes q WHERE q.job_id = j.id AND q.status = 'accepted' ORDER BY q.id DESC LIMIT 1) AS quoted_net,
       (SELECT q.lines FROM quotes q WHERE q.job_id = j.id AND q.status = 'accepted' ORDER BY q.id DESC LIMIT 1) AS lines,
       (SELECT sum(extract(epoch FROM (coalesce(t.ended_at, now()) - t.started_at)) / 3600 * coalesce(u.cost_rate, 0))
          FROM job_time_entries t JOIN users u ON u.id = t.user_id WHERE t.job_id = j.id) AS labour_cost,
       (SELECT bool_or(u.cost_rate IS NULL) FROM job_time_entries t JOIN users u ON u.id = t.user_id WHERE t.job_id = j.id) AS missing_rate,
       ${ACTUAL_HOURS} AS actual_hours
     FROM jobs j LEFT JOIN users b ON b.id = j.assigned_builder_id
     WHERE j.completed_at >= $1 AND j.completed_at < $2 ORDER BY j.completed_at DESC`, [fromTs, toTs])).rows.map((j) => {
    const revenue = N(j.invoiced_net ?? j.quoted_net);
    // Materials at cost: quoted materials prices take your markup back off.
    const materials = (j.lines || []).filter((l) => l.category === 'materials').reduce((a, l) => a + N(l.qty) * N(l.unit_price), 0) / (1 + N(s.markup_pct) / 100);
    const profit = revenue - materials - N(j.labour_cost);
    return { ...j, revenue, materials: r2(materials), profit: r2(profit) };
  });
  const totals = jobs.reduce((a, j) => ({ revenue: a.revenue + j.revenue, profit: a.profit + j.profit }), { revenue: 0, profit: 0 });
  const missingRates = jobs.some((j) => j.missing_rate);

  // ---- Estimating accuracy by template (all finished jobs, not just this period) ----
  const accuracy = (await query(
    `SELECT t.id, t.name, t.pricing_method, t.labour_per_unit, count(*)::int AS jobs, sum(x.est) AS est, sum(x.actual) AS actual
     FROM (SELECT j.template_id, ${ESTIMATED_HOURS} AS est, ${ACTUAL_HOURS} AS actual FROM jobs j
           WHERE j.template_id IS NOT NULL AND j.status IN ('complete', 'invoiced', 'paid')) x
     JOIN job_templates t ON t.id = x.template_id
     WHERE x.est > 0 AND x.actual > 0 GROUP BY t.id ORDER BY count(*) DESC`)).rows.map((t) => {
    const ratio = N(t.actual) / N(t.est);
    const suggest = t.jobs >= 3 && Math.abs(ratio - 1) >= 0.1 && t.pricing_method !== 'fixed' ? r2(N(t.labour_per_unit) * ratio) : null;
    return { ...t, ratio, suggest };
  });

  // ---- Builders ----
  const builders = (await query(
    `SELECT u.id, u.name, u.cost_rate,
       coalesce(sum(extract(epoch FROM (coalesce(t.ended_at, now()) - t.started_at)) / 3600), 0) AS hours,
       (SELECT count(*)::int FROM jobs j WHERE j.assigned_builder_id = u.id AND j.completed_at >= $1 AND j.completed_at < $2) AS finished
     FROM users u LEFT JOIN job_time_entries t ON t.user_id = u.id AND t.started_at >= $1 AND t.started_at < $2
     WHERE u.role IN ('builder', 'admin') AND u.active GROUP BY u.id ORDER BY u.name`, [fromTs, toTs])).rows.filter((b) => N(b.hours) > 0 || b.finished > 0);

  const presetOpt = (k, l) => `<option value="${k}" ${p.key === k ? 'selected' : ''}>${l}</option>`;
  const csv = (what) => `/admin/reports/${what}.csv?preset=${p.key}${p.key === 'custom' ? `&from=${p.from}&to=${p.to}` : ''}`;
  const card = (label, value, note = '') => `<div class="stat"><span class="muted">${label}</span><strong>${value}</strong>${note ? `<span class="muted small">${note}</span>` : ''}</div>`;

  const body = `<form method="get" action="/admin/reports" class="filters">
      <label>Period<select name="preset">${presetOpt('this_month', 'This month')}${presetOpt('last_month', 'Last month')}${presetOpt('tax_year', 'This tax year')}${presetOpt('last_12', 'Last 12 months')}${presetOpt('custom', 'Choose dates')}</select></label>
      <label>From<input type="date" name="from" value="${p.from}"></label>
      <label>To<input type="date" name="to" value="${p.to}"></label>
      <button class="small">Show</button>
    </form>
    <h2>${esc(p.label)}</h2>
    <div class="stats">
      ${card('Money in', m(takings), byMethod.map((r) => `${esc(r.method)} ${m(r.total)}`).join(' · ') || 'No payments')}
      ${card('Invoiced', m(invoiced))}
      ${card('Owed to you now', m(owedTotal), `${m(ageing.d30 + ageing.d60 + ageing.older)} overdue`)}
      ${card('Quotes won', pct(answers.won, answers.won + answers.lost), `${answers.won} won, ${answers.lost} lost`)}
      ${card('Average job won', m(answers.avg_won || 0))}
      ${card('New requests', requests, `${quoted} quoted`)}
    </div>

    <h2>Money in, last 12 months</h2>
    <div class="bars">${months.map((x) => `<div class="bar"><span class="fill" style="height:${Math.round((x.total / maxMonth) * 100)}%" title="${m(x.total)}"></span><span class="lbl">${x.label}</span></div>`).join('')}</div>

    <h2>Owed to you</h2>
    <div class="stats">
      ${card('Not due yet', m(ageing.notDue))}${card('1 to 30 days late', m(ageing.d30))}${card('31 to 60 days late', m(ageing.d60))}${card('Over 60 days late', m(ageing.older))}
    </div>

    <h2>Profit on jobs finished in this period</h2>
    ${missingRates ? '<p class="error">Some time was logged by people without a pay rate, so their labour counts as £0. Add pay rates on the People page.</p>' : ''}
    ${jobs.length ? `<div class="scroll"><table>
      <thead><tr><th>Job</th><th>Builder</th><th class="num">Charged (net)</th><th class="num">Materials at cost</th><th class="num">Labour cost</th><th class="num">Hours</th><th class="num">Profit</th><th class="num">Margin</th></tr></thead>
      <tbody>${jobs.map((j) => `<tr>
        <td><a href="/jobs/${j.id}">${ref(j.id)}</a> ${esc(j.title)}</td><td>${esc(j.builder || '')}</td>
        <td class="num">${m(j.revenue)}</td><td class="num">${m(j.materials)}</td><td class="num">${m(j.labour_cost)}</td>
        <td class="num">${r2(N(j.actual_hours))}</td>
        <td class="num ${j.profit < 0 ? 'neg' : ''}">${m(j.profit)}</td><td class="num">${pct(j.profit, j.revenue)}</td></tr>`).join('')}
        <tr class="sumrow"><td colspan="2">Total</td><td class="num">${m(totals.revenue)}</td><td></td><td></td><td></td><td class="num">${m(totals.profit)}</td><td class="num">${pct(totals.profit, totals.revenue)}</td></tr>
      </tbody></table></div>
      <p class="hint">An estimate: materials are the quoted prices with your current ${N(s.markup_pct)}% markup taken off, and labour is clocked hours times each person’s pay rate. Travel and other costs aren’t taken off.</p>`
    : '<p class="empty">No jobs finished in this period.</p>'}

    <h2>How accurate are the time estimates?</h2>
    ${accuracy.length ? `<div class="scroll"><table>
      <thead><tr><th>Job template</th><th class="num">Jobs</th><th class="num">Hours estimated</th><th class="num">Hours taken</th><th>Result</th><th>Suggestion</th></tr></thead>
      <tbody>${accuracy.map((t) => `<tr>
        <td><a href="/admin/templates/${t.id}">${esc(t.name)}</a></td><td class="num">${t.jobs}</td>
        <td class="num">${r2(N(t.est))}</td><td class="num">${r2(N(t.actual))}</td>
        <td>${Math.abs(t.ratio - 1) < 0.1 ? '<span class="tag ok">About right</span>' : t.ratio > 1 ? `<span class="tag urgent">${Math.round((t.ratio - 1) * 100)}% longer than estimated</span>` : `<span class="tag">${Math.round((1 - t.ratio) * 100)}% quicker than estimated</span>`}</td>
        <td>${t.suggest !== null ? `<form method="post" action="/admin/reports/template/${t.id}" class="inline">
            <input type="hidden" name="value" value="${t.suggest}">
            <button class="small">Change labour per unit from ${N(t.labour_per_unit)} to ${t.suggest}</button></form>`
          : t.jobs < 3 ? '<span class="muted">Needs 3 or more jobs</span>' : ''}</td></tr>`).join('')}
      </tbody></table></div>
      <p class="hint">Compares the hours on each finished job’s working estimate (or price guide) with the hours actually clocked. Uses every finished job, not just this period.</p>`
    : '<p class="empty">Not enough finished jobs with clocked time yet. This fills in as builders clock on and off.</p>'}

    <h2>People</h2>
    ${builders.length ? `<div class="scroll"><table>
      <thead><tr><th>Name</th><th class="num">Hours clocked</th><th class="num">Jobs finished</th><th class="num">Labour cost</th></tr></thead>
      <tbody>${builders.map((b) => `<tr><td><a href="/admin/users/${b.id}">${esc(b.name)}</a></td><td class="num">${r2(N(b.hours))}</td><td class="num">${b.finished}</td>
        <td class="num">${b.cost_rate === null ? '<span class="muted">No pay rate</span>' : m(N(b.hours) * N(b.cost_rate))}</td></tr>`).join('')}</tbody></table></div>`
    : '<p class="empty">No time clocked in this period.</p>'}

    <h2>Download</h2>
    <p><a class="button" href="${csv('payments')}">Payments (CSV)</a> <a class="button" href="${csv('jobs')}">Jobs finished (CSV)</a></p>
    <p class="hint">Opens in Excel, Numbers or Google Sheets, handy for your accountant.</p>`;
  res.send(page({ title: 'Reports', user: req.user, notice: req.query.applied ? 'Template updated. New price guides use the new figure.' : null, body }));
}));

router.post('/admin/reports/template/:id', admin, wrap(async (req, res) => {
  const v = Number(req.body.value);
  if (Number.isFinite(v) && v > 0) await query("UPDATE job_templates SET labour_per_unit = $1 WHERE id = $2 AND pricing_method <> 'fixed'", [v, Number(req.params.id) || 0]);
  res.redirect('/admin/reports?applied=1');
}));

const csvCell = (v) => {
  const s = v === null || v === undefined ? '' : String(v);
  return /[",\n\r]/.test(s) || /^[=+\-@]/.test(s) ? `"${s.replace(/"/g, '""').replace(/^([=+\-@])/, "'$1")}"` : s;
};
const sendCsv = (res, name, header, rows) => {
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="${name}"`);
  res.send('\uFEFF' + [header, ...rows].map((r) => r.map(csvCell).join(',')).join('\r\n'));
};

router.get('/admin/reports/payments.csv', admin, wrap(async (req, res) => {
  const p = period(req.query);
  const rows = (await query(
    `SELECT p.received_at, p.amount, p.method, p.reference, p.job_id, p.invoice_id, j.title, u.name
     FROM payments p JOIN jobs j ON j.id = p.job_id JOIN users u ON u.id = j.customer_id
     WHERE p.received_at >= $1 AND p.received_at < $2 ORDER BY p.received_at`, [ukTime(p.from, '00:00'), ukTime(addDays(p.to, 1), '00:00')])).rows;
  sendCsv(res, `payments-${p.from}-to-${p.to}.csv`, ['Date', 'Amount', 'Method', 'Reference', 'Job', 'Invoice', 'Work', 'Customer'],
    rows.map((r) => [ukDate(r.received_at), N(r.amount).toFixed(2), r.method, r.reference, ref(r.job_id), r.invoice_id ? `INV-${String(r.invoice_id).padStart(5, '0')}` : '', r.title, r.name]));
}));

router.get('/admin/reports/jobs.csv', admin, wrap(async (req, res) => {
  const p = period(req.query);
  const rows = (await query(
    `SELECT j.id, j.title, j.postcode, j.completed_at, j.status, u.name, b.name AS builder,
       (SELECT i.net FROM invoices i WHERE i.job_id = j.id AND i.kind = 'final' AND i.status <> 'void' ORDER BY i.id DESC LIMIT 1) AS net,
       (SELECT i.total FROM invoices i WHERE i.job_id = j.id AND i.kind = 'final' AND i.status <> 'void' ORDER BY i.id DESC LIMIT 1) AS total,
       ${ACTUAL_HOURS} AS hours
     FROM jobs j JOIN users u ON u.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id
     WHERE j.completed_at >= $1 AND j.completed_at < $2 ORDER BY j.completed_at`, [ukTime(p.from, '00:00'), ukTime(addDays(p.to, 1), '00:00')])).rows;
  sendCsv(res, `jobs-${p.from}-to-${p.to}.csv`, ['Job', 'Work', 'Customer', 'Postcode', 'Builder', 'Finished', 'Stage', 'Invoiced net', 'Invoiced total', 'Hours clocked'],
    rows.map((r) => [ref(r.id), r.title, r.name, r.postcode, r.builder, ukDate(r.completed_at), r.status, r.net === null ? '' : N(r.net).toFixed(2), r.total === null ? '' : N(r.total).toFixed(2), r2(N(r.hours))]));
}));

module.exports = router;
HANDYTRIO_EOF

cat > src/routes/repeat.js <<'HANDYTRIO_EOF'
// Repeat business: the "book your renewal" link in reminder emails, and the office's reminders page.
const express = require('express');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day, when } = require('../format');
const { setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyOffice, emailReady } = require('../notify');
const { smsReady } = require('../sms');
const { TYPES } = require('../certtypes');
const { runReminders } = require('../scheduler');

const router = express.Router();

async function ownedCert(req) {
  const c = (await query(
    `SELECT c.*, j.customer_id, j.address_line, j.town, j.postcode, j.title FROM certificates c JOIN jobs j ON j.id = c.job_id WHERE c.id = $1 AND c.status = 'issued'`,
    [Number(req.params.cid) || 0])).rows[0];
  if (!c || !TYPES[c.type]) return null;
  if (req.user.role === 'customer' && c.customer_id !== req.user.id) return null;
  return c;
}

router.get('/rebook/:cid', requireLogin, wrap(async (req, res) => {
  const c = await ownedCert(req);
  if (!c) return res.redirect('/dashboard');
  const address = [c.address_line, c.town, c.postcode].filter(Boolean).join(', ');
  const body = `<div class="panel narrow callout">
    <p>Your last ${esc(TYPES[c.type].name.toLowerCase())} at <strong>${esc(address)}</strong> was on ${day(c.issued_at)}${c.next_due ? `, and the next one is due by <strong>${day(c.next_due)}</strong>` : ''}.</p>
    <form method="post" action="/rebook/${c.id}">
      <button class="primary">Book my ${esc(TYPES[c.type].name.toLowerCase())}</button>
    </form>
    <p class="hint">Next you’ll choose a time for the visit.</p>
  </div>`;
  res.send(page({ title: `Book your ${TYPES[c.type].name}`, user: req.user, body }));
}));

router.post('/rebook/:cid', requireLogin, wrap(async (req, res) => {
  const c = await ownedCert(req);
  if (!c) return res.redirect('/dashboard');
  const t = TYPES[c.type];
  // Don't make a second request if one is already open for this renewal.
  const open = (await query(
    `SELECT id FROM jobs WHERE customer_id = $1 AND title = $2 AND postcode IS NOT DISTINCT FROM $3 AND status IN ('request', 'inspection_required', 'inspection_booked') LIMIT 1`,
    [c.customer_id, `${t.name} renewal`, c.postcode])).rows[0];
  if (open) return res.redirect(`/jobs/${open.id}/inspection`);
  const client = await pool.connect();
  let jobId;
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `INSERT INTO jobs (customer_id, title, work_type, description, address_line, town, postcode, preferred_start, status)
       VALUES ($1, $2, 'Something else', $3, $4, $5, $6, current_date + 1, 'request') RETURNING id`,
      [c.customer_id, `${t.name} renewal`, `Renewal of ${t.prefix}-${String(c.id).padStart(5, '0')}, due ${day(c.next_due)}.`, c.address_line, c.town, c.postcode]);
    jobId = rows[0].id;
    await setStatus(client, jobId, null, 'request', req.user.id, 'Renewal booked from a reminder');
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyOffice(`Renewal booked: ${t.name} (${ref(jobId)})`, `A customer has asked to renew their ${t.name}.\n\n${baseUrlOf(req)}/jobs/${jobId}`, jobId);
  res.redirect(`/jobs/${jobId}/inspection`);
}));

// ---------- Office: reminders ----------
router.get('/admin/reminders', requireRole('admin'), wrap(async (req, res) => {
  const s = (await query('SELECT reminder_days_before, review_link, texts_enabled FROM settings WHERE id = 1')).rows[0];
  const upcoming = (await query(
    `SELECT c.id, c.type, c.next_due, c.job_id, u.name, j.postcode,
       (SELECT r.sent_at FROM reminders_sent r WHERE r.kind = 'cert_due' AND r.ref_id = c.id) AS reminded
     FROM certificates c JOIN jobs j ON j.id = c.job_id JOIN users u ON u.id = j.customer_id
     WHERE c.status = 'issued' AND c.next_due IS NOT NULL AND c.next_due <= current_date + 90 AND c.next_due >= current_date - 30
     ORDER BY c.next_due`)).rows;
  const log = (await query(
    `SELECT r.*, CASE WHEN r.kind = 'cert_due' THEN (SELECT job_id FROM certificates WHERE id = r.ref_id) ELSE r.ref_id END AS job_id
     FROM reminders_sent r ORDER BY r.sent_at DESC LIMIT 50`)).rows;
  const KIND = { cert_due: 'Renewal reminder email', inspection_text: 'Visit reminder text', job_text: 'Start-day reminder text', review: 'Review request email' };
  const setup = [
    emailReady() ? '' : '<li>Email sending isn’t set up, so emails are saved but not sent.</li>',
    smsReady() ? '' : '<li>Text messages aren’t set up, so texts are saved but not sent. Add your Twilio details to .env.</li>',
    s.review_link ? '' : '<li>No review link is set, so review requests are off. Add your Google review link in Settings.</li>',
    s.texts_enabled ? '' : '<li>Texts are switched off in Settings.</li>',
  ].join('');
  const tabs = `<nav class="subnav"><a href="/admin/emails">Customer emails</a><a href="/admin/emails/texts">Text messages</a><a href="/admin/reminders" aria-current="page">Reminders</a><a href="/admin/emails/log">Sent emails</a><a href="/admin/emails/texts/log">Sent texts</a></nav>`;
  const body = `${tabs}
    ${setup ? `<ul class="error">${setup}</ul>` : ''}
    <p class="lead">These go out by themselves every hour: renewal emails ${Number(s.reminder_days_before)} days before a certificate is due, a text the day before a visit or start date (between 9am and 8pm), and a review request a few days after a job is paid.</p>
    <form method="post" action="/admin/reminders/run" class="inline"><button class="small">Check and send now</button></form>
    <h2>Certificates due in the next 90 days</h2>
    ${upcoming.length ? `<div class="scroll"><table><thead><tr><th>Certificate</th><th>Customer</th><th>Postcode</th><th>Due</th><th>Reminder</th></tr></thead><tbody>
      ${upcoming.map((c) => `<tr><td><a href="/jobs/${c.job_id}/certs/${c.id}">${esc(TYPES[c.type] ? TYPES[c.type].name : c.type)}</a></td><td>${esc(c.name)}</td><td>${esc(c.postcode)}</td>
        <td>${new Date(c.next_due) < new Date(new Date().toDateString()) ? '<span class="tag urgent">Overdue</span> ' : ''}${day(c.next_due)}</td>
        <td>${c.reminded ? `Sent ${day(c.reminded)}` : '<span class="muted">Not yet</span>'}</td></tr>`).join('')}
    </tbody></table></div>` : '<p class="empty">Nothing due in the next 90 days.</p>'}
    <h2>Recently sent</h2>
    ${log.length ? `<ul class="certlist">${log.map((r) => `<li>${when(r.sent_at)} <strong>${esc(KIND[r.kind] || r.kind)}</strong> ${r.job_id ? `<a href="/jobs/${r.job_id}">${ref(r.job_id)}</a>` : ''} <span class="tag ${r.status === 'sent' ? 'ok' : ''}">${esc(r.status || 'pending')}</span></li>`).join('')}</ul>` : '<p class="empty">Nothing sent yet.</p>'}`;
  const ran = req.query.ran ? String(req.query.ran).slice(0, 120) : null;
  res.send(page({ title: 'Reminders', user: req.user, notice: ran, body }));
}));

router.post('/admin/reminders/run', requireRole('admin'), wrap(async (req, res) => {
  const r = await runReminders();
  const msg = r ? `Checked: ${r.certificates} renewal email${r.certificates === 1 ? '' : 's'}, ${r.texts} text${r.texts === 1 ? '' : 's'}, ${r.reviews} review request${r.reviews === 1 ? '' : 's'} sent.` : 'Already running, try again in a minute.';
  res.redirect('/admin/reminders?ran=' + encodeURIComponent(msg));
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
const { smsReady } = require('../sms');

const router = express.Router();
const admin = requireRole('admin');
const ORDER = [...STATUSES.map(([k]) => k), 'inspection_cancelled', 'cert_issued', 'cert_due', 'review_request'];
const nameOf = (k) => ({ cert_issued: 'Certificate issued (PDF attached)', inspection_cancelled: 'Inspection cancelled', cert_due: 'Renewal reminder', review_request: 'Review request' }[k] || label(k));

const sample = {
  first_name: 'Sam', customer_name: 'Sam Jones', job_ref: 'HT-00042', job_title: 'Hang an internal door',
  stage: 'Quote sent', due_date: '14 Mar 2027', address: '12 High Street, CF10 1AA', landlord_note: ' and keeps you legal as a landlord', book_link: 'https://example.com/rebook/7', review_link: 'https://g.page/r/your-business/review', inspection_time: 'Tuesday 14 January at 10:00 am', booked_dates: '20 Jan 2027 to 22 Jan 2027', cert_name: 'Landlord Gas Safety Record', cert_number: 'GSR-00007', price_guide: '£215.00 to £295.00 including VAT', job_link: 'https://example.com/jobs/42',
};

const tabs = (active) => `<nav class="subnav">
  <a href="/admin/emails" ${active === 'templates' ? 'aria-current="page"' : ''}>Customer emails</a>
  <a href="/admin/emails/texts" ${active === 'texts' ? 'aria-current="page"' : ''}>Text messages</a>
  <a href="/admin/reminders" ${active === 'reminders' ? 'aria-current="page"' : ''}>Reminders</a>
  <a href="/admin/emails/log" ${active === 'log' ? 'aria-current="page"' : ''}>Sent emails</a>
  <a href="/admin/emails/texts/log" ${active === 'textlog' ? 'aria-current="page"' : ''}>Sent texts</a></nav>`;

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

// ---------- Text messages ----------
const SMS_NAMES = { inspection_reminder: 'Day before an inspection visit', job_reminder: 'Day before a job starts' };

router.get('/admin/emails/texts', admin, wrap(async (req, res) => {
  const rows = (await query('SELECT * FROM sms_templates ORDER BY key')).rows;
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  const vars = { ...sample, business_name: s.business_name };
  const body = `${tabs('texts')}
    ${smsReady() ? '' : '<div class="error">Text messages aren’t set up yet, so texts are only saved under Sent texts. Add your Twilio details to the .env file to start sending.</div>'}
    <p class="lead">Sent automatically the day before, between 9am and 8pm, to customers with a UK mobile number. Customers can turn texts off in their account.
    Keep them short: one text is 160 characters, and longer messages cost more. You can use: ${['first_name', 'job_title', 'inspection_time', 'booked_dates', 'job_link', 'business_name'].map((p) => `<code>{${p}}</code>`).join(' ')}</p>
    ${rows.map((t) => {
      const preview = fill(t.body, vars);
      return `<form method="post" action="/admin/emails/texts/${t.key}" class="panel">
        <h3>${esc(SMS_NAMES[t.key] || t.key)}</h3>
        <label class="check"><input type="checkbox" name="enabled" ${t.enabled ? 'checked' : ''}> Send this text</label>
        <label>Message<textarea name="body" rows="3" maxlength="640" required>${esc(t.body)}</textarea></label>
        <p class="hint">Preview (${preview.length} characters, about ${Math.max(1, Math.ceil(preview.length / 153))} text${preview.length > 160 ? 's' : ''}):</p>
        <div class="preview">${esc(preview)}</div>
        <button class="small">Save</button>
      </form>`;
    }).join('')}`;
  res.send(page({ title: 'Text messages', user: req.user, notice: req.query.saved ? 'Saved.' : null, body }));
}));

router.post('/admin/emails/texts/:key', admin, wrap(async (req, res) => {
  const body = String(req.body.body || '').replace(/\r?\n/g, ' ').trim().slice(0, 640);
  if (body) await query('UPDATE sms_templates SET body = $1, enabled = $2 WHERE key = $3', [body, req.body.enabled === 'on', req.params.key]);
  res.redirect('/admin/emails/texts?saved=1');
}));

router.get('/admin/emails/texts/log', admin, wrap(async (req, res) => {
  const rows = (await query('SELECT * FROM sms_log ORDER BY created_at DESC LIMIT 100')).rows;
  const body = `${tabs('textlog')}
    ${rows.length ? `<ul class="certlist">${rows.map((t) => `<li>${when(t.created_at)} <span class="tag ${t.status === 'sent' ? 'ok' : 'urgent'}">${esc(t.status)}</span> ${esc(t.to_number)}
      ${t.job_id ? `<a href="/jobs/${t.job_id}">Job</a>` : ''}<br><span class="muted">${esc(t.body)}</span>${t.error ? `<br><span class="muted small">${esc(t.error)}</span>` : ''}</li>`).join('')}</ul>` : '<p class="empty">No texts yet.</p>'}`;
  res.send(page({ title: 'Sent texts', user: req.user, body }));
}));

module.exports = router;
HANDYTRIO_EOF

cat > src/routes/account.js <<'HANDYTRIO_EOF'
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
      ${u.role === 'customer' ? `<h2>Messages from us</h2>
      <form method="post" action="/account/messages" class="panel">
        <label class="check"><input type="checkbox" name="texts" ${u.sms_opt_out ? '' : 'checked'}> Text me the day before a visit</label>
        <label class="check"><input type="checkbox" name="reminders" ${u.marketing_opt_out ? '' : 'checked'}> Email me when a safety check or service is due, and ask for feedback after a job</label>
        <p class="hint">You’ll always get emails about jobs you’ve booked, like quotes and invoices.</p>
        <button class="small">Save</button>
      </form>
      <h2>Your data</h2>` : ''}
      ${u.role === 'customer' ? `
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

router.post('/account/messages', requireLogin, wrap(async (req, res) => {
  await query('UPDATE users SET sms_opt_out = $1, marketing_opt_out = $2 WHERE id = $3', [req.body.texts !== 'on', req.body.reminders !== 'on', req.user.id]);
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
HANDYTRIO_EOF

cat > src/routes/users.js <<'HANDYTRIO_EOF'
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
  ['Reminders and reviews', [
    ['reminder_days_before', 'Email customers this many days before a certificate is due', 'int', '1'],
    ['texts_enabled', 'Send day-before text reminders', 'bool'],
    ['review_link', 'Your Google (or other) review link, e.g. https://g.page/r/…/review', 'text'],
    ['review_delay_days', 'Ask for a review this many days after a job is paid', 'int', '1'],
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

/* Update 3: reports */
.stats { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: .75rem; margin-bottom: 1rem; }
.stat { background: var(--surface); border: 1px solid var(--line); border-radius: 6px; padding: .75rem 1rem; display: flex; flex-direction: column; gap: .2rem; }
.stat strong { font: 700 1.7rem/1.1 "Barlow Condensed", Barlow, sans-serif; }
.bars { display: grid; grid-template-columns: repeat(12, 1fr); gap: .4rem; align-items: end; height: 180px; background: var(--surface); border: 1px solid var(--line); border-radius: 6px; padding: .75rem .75rem 0; }
.bar { display: flex; flex-direction: column; justify-content: flex-end; height: 100%; }
.bar .fill { display: block; background: var(--slate); border-top: 4px solid var(--hivis); border-radius: 3px 3px 0 0; min-height: 2px; }
.bar .lbl { text-align: center; font-size: .75rem; color: var(--muted); padding: .3rem 0; }
td.neg { color: var(--bad-ink); font-weight: 600; }
tr.sumrow td { font-weight: 700; border-top: 2px solid var(--ink); }
ul.error { padding-left: 2rem; }
HANDYTRIO_EOF

if ! grep -q "TWILIO_ACCOUNT_SID" .env; then
  printf "\n# Text messages with Twilio. Fill these in, remove the #, then restart the app.\n# TWILIO_ACCOUNT_SID=\n# TWILIO_AUTH_TOKEN=\n# TWILIO_FROM=\n" >> .env
fi
echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "Update 3 installed. The app restarts by itself; otherwise run: npm run dev"
