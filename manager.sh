#!/usr/bin/env bash
# Adds the Manager role (admin and builder in one). Run with: bash manager.sh
set -e
if [ ! -f package.json ]; then echo "Run this inside the project folder"; exit 1; fi
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

-- Staff availability: builders are available any time unless they say otherwise
CREATE TABLE IF NOT EXISTS staff_availability (
  user_id    int NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date       date NOT NULL,
  kind       text NOT NULL CHECK (kind IN ('hours','off')),
  start_time text,
  end_time   text,
  PRIMARY KEY (user_id, date)
);
CREATE TABLE IF NOT EXISTS staff_time_off (
  id         serial PRIMARY KEY,
  user_id    int NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  start_date date NOT NULL,
  end_date   date NOT NULL,
  note       text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS staff_time_off_user_idx ON staff_time_off (user_id, start_date);

-- Private certificates: engineers' own side jobs, not linked to a company job
ALTER TABLE certificates ALTER COLUMN job_id DROP NOT NULL;
ALTER TABLE certificates ADD COLUMN IF NOT EXISTS private boolean NOT NULL DEFAULT false;
ALTER TABLE certificates ADD COLUMN IF NOT EXISTS cust_name text;
ALTER TABLE certificates ADD COLUMN IF NOT EXISTS cust_address text;
ALTER TABLE certificates ADD COLUMN IF NOT EXISTS cust_postcode text;
ALTER TABLE certificates ADD COLUMN IF NOT EXISTS cust_phone text;
ALTER TABLE certificates ADD COLUMN IF NOT EXISTS cust_email text;
ALTER TABLE certificates ADD COLUMN IF NOT EXISTS trading_name text;
ALTER TABLE certificates ADD COLUMN IF NOT EXISTS trading_contact text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS private_trading_name text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS private_trading_contact text;

-- Branding: name, colours and logo all come from Settings
ALTER TABLE settings ADD COLUMN IF NOT EXISTS brand_primary text NOT NULL DEFAULT '#24414f';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS brand_accent text NOT NULL DEFAULT '#f2c300';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS logo bytea;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS logo_mime text;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS logo_updated_at timestamptz;
ALTER TABLE settings ALTER COLUMN business_name SET DEFAULT 'SWAT Maintenance';
UPDATE settings SET business_name = 'SWAT Maintenance' WHERE business_name = 'TheHandyTrio';

-- Manager: an admin who also works as a builder
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check CHECK (role IN ('customer', 'builder', 'admin', 'manager'));
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

// For the hosting's health checks: answers once the database is reachable.
app.get('/healthz', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.type('text').send('ok');
  } catch (e) {
    res.status(503).type('text').send('database unavailable');
  }
});

app.use(session({
  name: 'handytrio.sid',
  store: new PgSession({ pool, createTableIfMissing: true }),
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, sameSite: 'lax', secure: 'auto', maxAge: 1000 * 60 * 60 * 24 * 7 },
}));

// Branding (name, colours, logo) is loaded once, then refreshed whenever Settings are saved.
const { loadBrand } = require('./brand');
let brandLoaded = null;
app.use((req, res, next) => {
  if (!brandLoaded) brandLoaded = loadBrand().catch((e) => { brandLoaded = null; throw e; });
  brandLoaded.then(() => next(), next);
});

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
    // A manager has every admin permission and also works jobs like a builder.
    if (req.user) {
      req.user.realRole = req.user.role;
      req.user.isManager = req.user.role === 'manager';
      if (req.user.isManager) req.user.role = 'admin';
    }
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
app.use(require('./routes/certify'));
app.use(require('./routes/backups'));
app.use(require('./routes/calendar').router);
app.use(require('./routes/repeat'));
app.use(require('./routes/reports'));
app.use(require('./routes/availability'));
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
  console.log(`App running on port ${port}`);
  startScheduler();
});
HANDYTRIO_EOF

cat > src/layout.js <<'HANDYTRIO_EOF'
const { brand } = require('./brand');

const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin', manager: 'Manager' };

function nav(user) {
  if (!user) return '<a href="/login">Log in</a><a href="/register">Create account</a>';
  const links = ['<a href="/dashboard">Dashboard</a>'];
  if (user.role !== 'customer') links.push(`<a href="/jobs">${user.role === 'admin' ? 'All jobs' : 'My jobs'}</a>`, `<a href="/calendar">${user.role === 'admin' ? 'Calendar' : 'My diary'}</a>`);
  if (user.role === 'builder' || user.isManager) links.push('<a href="/availability">My availability</a>', '<a href="/certify">Certify</a>');
  if (user.role === 'admin') {
    links.push('<a href="/admin/reports">Reports</a>', '<a href="/admin/certificates">Certificates</a>', '<a href="/admin/templates">Pricing</a>', '<a href="/admin/users">People</a>', '<a href="/admin/emails">Messages</a>', '<a href="/admin/backups">Backups</a>', '<a href="/admin/settings">Settings</a>');
  }
  links.push('<a href="/account">My account</a>');
  links.push('<form method="post" action="/logout" class="inline"><button class="linkish">Log out</button></form>');
  return links.join('');
}

function page({ title, user, body, notice, error }) {
  const b = brand();
  const logo = b.hasLogo ? `/brand/logo?v=${b.logoVersion}` : '';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} | ${esc(b.name)}</title>${logo ? `\n<link rel="icon" href="${logo}">` : ''}
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow:wght@400;500;600&family=Barlow+Condensed:wght@600;700&display=swap">
<link rel="stylesheet" href="/style.css">
<style>:root { --slate: ${b.primary}; --slate-ink: ${b.primaryInk}; --hivis: ${b.accent}; --hivis-ink: ${b.accentInk}; }</style>
<script src="/js/photos.js" defer></script>
</head>
<body>
<header class="top">
  <a class="brand" href="/">${logo ? `<img src="${logo}" alt="">` : ''}<span>${esc(b.name)}</span></a>
  <nav>${nav(user)}</nav>
</header>
<div class="stripe" aria-hidden="true"></div>
<main>
  ${user ? `<p class="who">Signed in as ${esc(user.name)} (${esc(ROLE_LABELS[user.realRole || user.role] || user.role)})</p>` : ''}
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

// Where the van leaves from: the assigned builder's home, otherwise the nearest builder's home, otherwise the base.
async function travelOrigin(s, to, builderId, warnings) {
  if (builderId) {
    const b = (await query("SELECT name, postcode FROM users WHERE id = $1 AND role IN ('builder', 'manager')", [builderId])).rows[0];
    const loc = b && b.postcode ? await locate(b.postcode) : null;
    if (loc) return { label: `${b.name}’s home`, postcode: b.postcode, loc };
    warnings.push(`${b ? b.name : 'The assigned builder'} has no usable home postcode, so travel is from the nearest builder or the base instead.`);
  }
  const builders = (await query(
    "SELECT name, postcode FROM users WHERE role IN ('builder', 'manager') AND active AND coalesce(postcode, '') <> '' ORDER BY id")).rows;
  let best = null;
  for (const b of builders) {
    const loc = await locate(b.postcode);
    if (!loc) continue;
    const d = milesBetween(loc, to);
    if (!best || d < best.d) best = { d, label: `${b.name}’s home (nearest builder)`, postcode: b.postcode, loc };
  }
  if (best) return best;
  if (s.base_postcode) {
    const loc = await locate(s.base_postcode);
    if (loc) return { label: 'Base', postcode: s.base_postcode, loc };
  }
  return null;
}

// Travel cost for a number of visits, from the assigned builder, else the nearest builder, else the base.
async function computeTravel({ s, postcode, builderId = null, visits = 1, warnings = [] }) {
  if (!s) s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const travel = { from: null, fromPostcode: null, oneWayMiles: null, visits, mileage: 0, time: 0, total: 0 };
  const to = await locate(postcode);
  const origin = to ? await travelOrigin(s, to, builderId, warnings) : null;
  if (!to) {
    warnings.push('The distance to this postcode couldn’t be found, so travel isn’t included.');
  } else if (!origin) {
    warnings.push('No builder home postcodes or base postcode are set, so travel isn’t included.');
  } else {
    const oneWay = milesBetween(origin.loc, to) * ROAD_FACTOR;
    const roundTrips = oneWay * 2 * visits;
    travel.from = origin.label;
    travel.fromPostcode = origin.postcode;
    travel.oneWayMiles = r2(oneWay);
    travel.mileage = r2(roundTrips * N(s.mileage_rate));
    travel.time = s.charge_travel_time ? r2((roundTrips / AVG_MPH) * N(s.travel_hourly_rate)) : 0;
    travel.total = r2(travel.mileage + travel.time);
    if (oneWay > N(s.service_radius_miles)) {
      warnings.push(`About ${Math.round(oneWay)} miles from ${origin.label.replace(' (nearest builder)', '')}, outside the ${N(s.service_radius_miles)}-mile service area.`);
    }
  }
  return travel;
}

async function calculateEstimate({ templateId, quantity, accessIds = [], postcode, urgent = false, skipTravel = false, builderId = null }) {
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
  let labourQty;
  let labourUnit;
  let labourRate;
  let estimatedHours;
  if (t.pricing_method === 'day') {
    const days = Math.max(0.5, Math.ceil(units * accessFactor * 2) / 2);
    labourBase = days * crew * N(s.day_rate);
    labourText = `${days} day${days === 1 ? '' : 's'} × ${crew} ${crew === 1 ? 'person' : 'people'} × ${money(s.day_rate, s.currency)}`;
    visits = Math.ceil(days);
    labourQty = days * crew; labourUnit = 'days'; labourRate = N(s.day_rate);
    estimatedHours = r2(days * crew * (N(s.hours_per_day) || 8));
  } else if (t.pricing_method === 'fixed') {
    labourBase = units * accessFactor;
    labourText = 'Fixed price' + (accessFactor !== 1 ? ` × access ${r2(accessFactor)}` : '');
    visits = 1;
    labourQty = 1; labourUnit = 'job'; labourRate = r2(labourBase);
    estimatedHours = null;
  } else {
    const hours = r2(units * accessFactor);
    labourBase = hours * crew * N(s.hourly_rate);
    labourText = `${hours} hr${hours === 1 ? '' : 's'} × ${crew} ${crew === 1 ? 'person' : 'people'} × ${money(s.hourly_rate, s.currency)}`;
    visits = Math.max(1, Math.ceil(hours / (N(s.hours_per_day) || 8)));
    labourQty = r2(hours * crew); labourUnit = 'hrs'; labourRate = N(s.hourly_rate);
    estimatedHours = labourQty;
  }
  labourBase = r2(labourBase);
  const urgentPremium = urgent ? r2(labourBase * pct(s.urgent_premium_pct)) : 0;
  const labour = r2(labourBase + urgentPremium);

  // Travel
  const travel = skipTravel
    ? { from: null, fromPostcode: null, oneWayMiles: null, visits, mileage: 0, time: 0, total: 0 }
    : await computeTravel({ s, postcode, builderId, visits, warnings });

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
    labour: { text: labourText, accessFactor: r2(accessFactor), base: labourBase, urgentPremium, total: labour, qty: labourQty, unit: labourUnit, rate: labourRate, estimatedHours },
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
        : `${e.travel.from ? row(`From ${esc(e.travel.from)}, ${esc(e.travel.fromPostcode)}`, '') : ''}
           ${row(`${e.travel.oneWayMiles} miles each way × ${e.travel.visits} visit${e.travel.visits === 1 ? '' : 's'}, mileage`, m(e.travel.mileage))}
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

module.exports = { calculateEstimate, computeTravel, customerSummary, renderBreakdown, money, locate };
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
const { loadAvailability, dayStatus, freeBetween, statusLabel } = require('../availability');

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
  const builders = (await query("SELECT id, name, postcode FROM users WHERE role IN ('builder', 'manager') AND active ORDER BY id")).rows;
  const inspections = (await query(
    `SELECT inspection_at, inspection_minutes, inspection_builder_id FROM jobs
     WHERE inspection_at IS NOT NULL AND inspection_at >= now() - interval '1 day' AND id <> $1 AND status NOT IN ('cancelled', 'declined')`, [excludeJobId])).rows;
  const work = (await query(
    `SELECT assigned_builder_id, scheduled_start, coalesce(scheduled_end, scheduled_start) AS scheduled_end FROM jobs
     WHERE status = ANY($1) AND scheduled_start IS NOT NULL AND assigned_builder_id IS NOT NULL`, [ACTIVE_WORK])).rows;
  const av = await loadAvailability(builders.map((b) => b.id), today, lastDay);
  const busyOnDay = (bid, iso) => work.some((w) => w.assigned_builder_id === bid && ukDate(w.scheduled_start) <= iso && iso <= ukDate(w.scheduled_end));

  const days = [];
  for (let iso = today; iso <= lastDay; iso = addDays(iso, 1)) {
    if (!r.days.includes(weekdayOf(iso))) continue;
    const slots = [];
    const endAt = ukTime(iso, r.end).getTime();
    for (let t = ukTime(iso, r.start).getTime(); t + r.slot * 60000 <= endAt; t += r.slot * 60000) {
      if (t < earliest) continue;
      const tEnd = t + r.slot * 60000;
      const free = builders.filter((b) => !busyOnDay(b.id, iso) && freeBetween(av, b.id, new Date(t), new Date(tEnd)) && !inspections.some((i) => i.inspection_builder_id === b.id
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
  const builders = isAdmin ? (await query("SELECT id, name FROM users WHERE role IN ('builder', 'manager') AND active ORDER BY name")).rows : [];
  const manual = isAdmin ? `<h2>Book a time by hand</h2>
    <form method="post" action="/jobs/${job.id}/inspection" class="panel schedule">
      <label>Date<input type="date" name="date" required></label>
      <label>Time<input type="time" name="time" required step="300"></label>
      <label>Inspector<select name="builder_id">${builders.map((b) => `<option value="${b.id}" ${b.id === job.assigned_builder_id ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}</select></label>
      <label class="check"><input type="checkbox" name="override"> Book anyway, even if they’re off</label>
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
    builder = (await query("SELECT id, name FROM users WHERE id = $1 AND role IN ('builder', 'manager') AND active", [Number(req.body.builder_id) || 0])).rows[0];
    if (!builder) return res.redirect(`/jobs/${job.id}/inspection?error=${encodeURIComponent('Choose an inspector.')}`);
    const av = await loadAvailability([builder.id], req.body.date, req.body.date);
    if (!freeBetween(av, builder.id, at, new Date(at.getTime() + rules.slot * 60000)) && req.body.override !== 'on') {
      const st = statusLabel(dayStatus(av, builder.id, req.body.date));
      return res.redirect(`/jobs/${job.id}/inspection?error=${encodeURIComponent(`${builder.name} isn’t available then (${st}). Tick “Book anyway” to go ahead.`)}`);
    }
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

  const avChip = (uid, d, av) => {
    const st = dayStatus(av, uid, d);
    return st.state === 'any' ? '' : `<span class="avchip ${st.state}">${esc(statusLabel(st))}</span>`;
  };
  let grid;
  if (isAdmin) {
    const builders = (await query("SELECT id, name FROM users WHERE role IN ('builder', 'manager') AND active ORDER BY name")).rows;
    const av = await loadAvailability(builders.map((b) => b.id), days[0], days[6]);
    grid = `<div class="scroll"><table class="week">
      <thead><tr><th>Builder</th>${days.map((d) => `<th class="${d === today ? 'today' : ''}">${dayHead(d)}</th>`).join('')}</tr></thead>
      <tbody>${builders.map((b) => `<tr><th>${esc(b.name)}</th>${days.map((d) => `<td class="${d === today ? 'today' : ''}">${avChip(b.id, d, av)}${on(events.filter((e) => e.builder_id === b.id), d).map(eventChip).join('')}</td>`).join('')}</tr>`).join('')}
      </tbody></table></div>`;
  } else {
    const av = await loadAvailability([user.id], days[0], days[6]);
    grid = `<div class="agenda">${days.map((d) => {
      const list = on(events, d);
      return `<section class="aday ${d === today ? 'today' : ''}"><h3>${dayHead(d)}${d === today ? ' <span class="tag">Today</span>' : ''} ${avChip(user.id, d, av)}</h3>
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

  const body = `${nav}<h2>Week of ${day(start)}</h2>
    <p><a href="/availability">${isAdmin ? 'Set working hours and holidays for anyone' : 'Set my working hours and holidays'}</a></p>${grid}${feed}`;
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
  const u = /^[a-f0-9]{48}$/.test(token) ? (await query("SELECT id, role, name FROM users WHERE calendar_token = $1 AND active AND role IN ('admin', 'builder', 'manager')", [token])).rows[0] : null;
  if (!u) return res.sendStatus(404);
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  const today = ukDate(new Date());
  const events = await eventsBetween(addDays(today, -30), addDays(today, 180), u.role === 'admin' ? null : u.id);
  const base = baseUrlOf(req);
  const names = Object.fromEntries((await query("SELECT id, name FROM users WHERE role IN ('builder', 'manager')")).rows.map((b) => [b.id, b.name]));
  const now = icsStamp(new Date());
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', `PRODID:-//${s.business_name.replace(/[^\w ]/g, '')}//Jobs//EN`, 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
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
  const people = u.role === 'admin' ? Object.keys(names).map(Number) : [u.id];
  const hols = (await query(
    `SELECT id, user_id, to_char(start_date, 'YYYY-MM-DD') AS s, to_char(end_date, 'YYYY-MM-DD') AS e, note FROM staff_time_off
     WHERE user_id = ANY($1) AND end_date >= $2::date AND start_date <= $3::date`, [people, addDays(today, -30), addDays(today, 180)])).rows;
  for (const h of hols) {
    lines.push('BEGIN:VEVENT', `UID:timeoff-${h.id}@thehandytrio`, `DTSTAMP:${now}`, `DTSTART;VALUE=DATE:${icsDate(h.s)}`, `DTEND;VALUE=DATE:${icsDate(addDays(h.e, 1))}`,
      `SUMMARY:${icsEscape(`${u.role === 'admin' ? `${names[h.user_id] || 'Staff'}: ` : ''}Time off${h.note ? ` (${h.note})` : ''}`)}`, 'TRANSP:TRANSPARENT', 'END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  res.setHeader('Content-Type', 'text/calendar; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  res.send(lines.map(fold).join('\r\n') + '\r\n');
}));

module.exports = { router, inspectionPanel, openSlots, eventsBetween, eventChip };
HANDYTRIO_EOF

cat > src/routes/joblist.js <<'HANDYTRIO_EOF'
// All jobs, past and present, with search and filters. Nothing is ever deleted:
// finished jobs simply drop off the dashboard and live here.
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin } = require('../auth');
const { STATUSES, CLOSED, label } = require('../statuses');
const { ref, day } = require('../format');
const { money } = require('../estimate');

const router = express.Router();
const PER_PAGE = 50;

router.get('/jobs', requireLogin, wrap(async (req, res) => {
  const user = req.user;
  if (user.role === 'customer') return res.redirect('/dashboard');
  const isAdmin = user.role === 'admin';

  const q = String(req.query.q || '').trim().slice(0, 80);
  const show = ['open', 'finished', 'all'].includes(req.query.show) ? req.query.show : 'all';
  const status = STATUSES.some(([k]) => k === req.query.status) ? req.query.status : '';
  const builder = isAdmin ? Number(req.query.builder) || 0 : 0;
  const pageNo = Math.max(1, Number(req.query.page) || 1);

  const where = [];
  const params = [];
  const add = (sql, v) => { params.push(v); where.push(sql.replace('?', `$${params.length}`)); };
  if (!isAdmin) add('(j.assigned_builder_id = ? OR j.id IN (SELECT job_id FROM job_team WHERE user_id = $Y))'.replace('$Y', `$${params.length + 1}`), user.id);
  if (builder) add('j.assigned_builder_id = ?', builder);
  if (status) add('j.status = ?', status);
  else if (show === 'open') add('j.status <> ALL(?)', CLOSED);
  else if (show === 'finished') add('j.status = ANY(?)', CLOSED);
  if (q) {
    const refNo = q.match(/^(?:ht-?)?0*(\d+)$/i);
    if (refNo) add('j.id = ?', Number(refNo[1]));
    else add(`(j.title ILIKE ? OR c.name ILIKE $X OR j.postcode ILIKE $X OR j.address_line ILIKE $X OR c.email ILIKE $X)`.replace(/\$X/g, `$${params.length + 1}`), `%${q}%`);
  }
  const whereSql = where.length ? 'WHERE ' + where.join(' AND ') : '';

  const total = (await query(`SELECT count(*)::int AS n FROM jobs j JOIN users c ON c.id = j.customer_id ${whereSql}`, params)).rows[0].n;
  const rows = (await query(
    `SELECT j.id, j.title, j.status, j.postcode, j.urgent, j.created_at, j.scheduled_start, j.completed_at, j.updated_at,
       c.name AS customer_name, b.name AS builder_name,
       coalesce(
         (SELECT i.total FROM invoices i WHERE i.job_id = j.id AND i.kind = 'final' AND i.status <> 'void' ORDER BY i.id DESC LIMIT 1),
         (SELECT qq.total FROM quotes qq WHERE qq.job_id = j.id AND qq.status = 'accepted' ORDER BY qq.id DESC LIMIT 1)
       ) AS value
     FROM jobs j JOIN users c ON c.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id
     ${whereSql}
     ORDER BY j.updated_at DESC
     LIMIT ${PER_PAGE} OFFSET ${(pageNo - 1) * PER_PAGE}`, params)).rows;
  const cur = (await query('SELECT currency FROM settings WHERE id = 1')).rows[0].currency;
  const builders = isAdmin ? (await query("SELECT id, name FROM users WHERE role IN ('builder', 'manager') ORDER BY name")).rows : [];

  const keep = (extra) => {
    const p = new URLSearchParams({ q, show, status, builder: builder || '', ...extra });
    for (const [k, v] of [...p]) if (!v) p.delete(k);
    return '/jobs?' + p.toString();
  };

  const filters = `<form method="get" action="/jobs" class="filters">
    <label>Search<input name="q" value="${esc(q)}" placeholder="Job, customer, postcode or HT number"></label>
    <label>Show<select name="show">
      <option value="all" ${show === 'all' ? 'selected' : ''}>All jobs</option>
      <option value="open" ${show === 'open' ? 'selected' : ''}>Open jobs</option>
      <option value="finished" ${show === 'finished' ? 'selected' : ''}>Finished and closed</option>
    </select></label>
    <label>Stage<select name="status"><option value="">Any stage</option>${STATUSES.map(([k, l]) => `<option value="${k}" ${k === status ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
    ${isAdmin ? `<label>Builder<select name="builder"><option value="">Any builder</option>${builders.map((b) => `<option value="${b.id}" ${b.id === builder ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}</select></label>` : ''}
    <button class="small">Find</button>
    ${q || status || builder || show !== 'all' ? '<a href="/jobs">Clear</a>' : ''}
  </form>`;

  const table = rows.length ? `<div class="scroll"><table>
    <thead><tr><th>Job</th><th>Work</th><th>Customer</th><th>Postcode</th><th>Stage</th>${isAdmin ? '<th>Builder</th>' : ''}<th class="num">Value</th><th>Finished</th><th>Last change</th></tr></thead>
    <tbody>${rows.map((j) => `<tr class="${CLOSED.includes(j.status) ? 'closedjob' : ''}">
      <td><a href="/jobs/${j.id}">${ref(j.id)}</a></td>
      <td><a href="/jobs/${j.id}">${esc(j.title)}</a></td>
      <td>${esc(j.customer_name)}</td>
      <td>${esc(j.postcode)}</td>
      <td><span class="tag ${j.status === 'paid' ? 'ok' : ''}">${esc(label(j.status))}</span></td>
      ${isAdmin ? `<td>${esc(j.builder_name || '')}</td>` : ''}
      <td class="num">${j.value !== null ? money(j.value, cur) : ''}</td>
      <td>${day(j.completed_at)}</td>
      <td>${day(j.updated_at)}</td>
    </tr>`).join('')}</tbody></table></div>`
    : '<p class="empty">No jobs match. Try a different search or clear the filters.</p>';

  const pages = Math.ceil(total / PER_PAGE);
  const pager = pages > 1 ? `<nav class="pager">
    ${pageNo > 1 ? `<a href="${esc(keep({ page: pageNo - 1 }))}">Newer</a>` : ''}
    <span>Page ${pageNo} of ${pages}</span>
    ${pageNo < pages ? `<a href="${esc(keep({ page: pageNo + 1 }))}">Older</a>` : ''}
  </nav>` : '';

  const body = `${filters}<p class="muted">${total} job${total === 1 ? '' : 's'}</p>${table}${pager}`;
  res.send(page({ title: isAdmin ? 'All jobs' : 'My jobs', user, body }));
}));

module.exports = router;
HANDYTRIO_EOF

cat > src/routes/availability.js <<'HANDYTRIO_EOF'
// Builders set their own working hours, days off and holidays. The office can do it for anyone.
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { day, ukDate, addDays } = require('../format');
const { loadAvailability, dayStatus, validTime } = require('../availability');
const { notifyOffice } = require('../notify');
const { baseUrlOf } = require('../jobs-shared');

const router = express.Router();
const staff = requireRole('admin', 'builder');
const isDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d || '');
const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const weekday = (iso) => new Date(`${iso}T12:00:00Z`).getUTCDay();
const dayLabel = (iso) => new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' });

// Builders manage their own; the office can pick anyone on the team.
async function whoFor(req, raw) {
  if (req.user.role !== 'admin') return { id: req.user.id, name: req.user.name };
  const id = Number(raw) || req.user.id;
  return (await query("SELECT id, name FROM users WHERE id = $1 AND role IN ('builder', 'admin', 'manager')", [id])).rows[0] || { id: req.user.id, name: req.user.name };
}
const backTo = (who, month, extra = '') => `/availability?user=${who.id}${month ? `&month=${month}` : ''}${extra}`;

router.get('/availability', staff, wrap(async (req, res) => {
  const who = await whoFor(req, req.query.user);
  const today = ukDate(new Date());
  const month = /^\d{4}-\d{2}$/.test(req.query.month || '') ? req.query.month : today.slice(0, 7);
  const first = `${month}-01`;
  const next = addDays(addDays(first, 32).slice(0, 7) + '-01', 0);
  const last = addDays(next, -1);
  const prev = addDays(first, -1).slice(0, 7);
  const av = await loadAvailability([who.id], first, last);
  const holidays = (await query(
    `SELECT id, to_char(start_date, 'YYYY-MM-DD') AS s, to_char(end_date, 'YYYY-MM-DD') AS e, note FROM staff_time_off
     WHERE user_id = $1 AND end_date >= current_date - 30 ORDER BY start_date`, [who.id])).rows;

  const staffPick = req.user.role === 'admin' ? `<form method="get" action="/availability" class="filters">
      <label>Person<select name="user">${(await query("SELECT id, name FROM users WHERE role IN ('builder', 'admin', 'manager') AND active ORDER BY name")).rows
        .map((u) => `<option value="${u.id}" ${u.id === who.id ? 'selected' : ''}>${esc(u.name)}</option>`).join('')}</select></label>
      <input type="hidden" name="month" value="${month}"><button class="small">Show</button></form>` : '';

  const days = [];
  for (let d = first; d <= last; d = addDays(d, 1)) days.push(d);
  const rows = days.map((d) => {
    const st = dayStatus(av, who.id, d);
    const past = d < today;
    if (st.state === 'holiday') {
      return `<div class="avrow holiday ${past ? 'past' : ''}"><span class="avday">${dayLabel(d)}</span><span class="tag urgent">Holiday</span><span class="muted">${esc(st.note || '')}</span></div>`;
    }
    const kind = st.state === 'hours' ? 'hours' : st.state === 'off' ? 'off' : 'any';
    return `<div class="avrow ${kind} ${past ? 'past' : ''} ${weekday(d) === 0 || weekday(d) === 6 ? 'weekend' : ''}">
      <span class="avday">${dayLabel(d)}</span>
      <select name="k_${d}" ${past ? 'disabled' : ''}>
        <option value="any" ${kind === 'any' ? 'selected' : ''}>Any time</option>
        <option value="hours" ${kind === 'hours' ? 'selected' : ''}>Set hours</option>
        <option value="off" ${kind === 'off' ? 'selected' : ''}>Not working</option>
      </select>
      <input type="time" name="s_${d}" value="${esc(st.start || '')}" step="900" ${past ? 'disabled' : ''} aria-label="Start">
      <input type="time" name="e_${d}" value="${esc(st.end || '')}" step="900" ${past ? 'disabled' : ''} aria-label="Finish">
    </div>`;
  }).join('');

  const body = `${staffPick}
    <p class="lead">${req.user.role === 'admin' && who.id !== req.user.id ? esc(who.name) + ' is' : 'You’re'} treated as available any time, day or night, unless a day is set otherwise here. Inspection bookings and job bookings respect this.</p>
    <div class="twocol">
      <section>
        <nav class="weeknav">
          <a class="button" href="${backTo(who, prev)}">Previous month</a>
          <a class="button" href="${backTo(who, today.slice(0, 7))}">This month</a>
          <a class="button" href="${backTo(who, next.slice(0, 7))}">Next month</a>
        </nav>
        <h2>${new Date(`${first}T12:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })}</h2>
        <form method="post" action="/availability" class="avmonth">
          <input type="hidden" name="user" value="${who.id}"><input type="hidden" name="month" value="${month}">
          ${rows}
          <button class="primary">Save this month</button>
        </form>
      </section>
      <section>
        <h2>Fill lots of days at once</h2>
        <form method="post" action="/availability/fill" class="panel">
          <input type="hidden" name="user" value="${who.id}"><input type="hidden" name="month" value="${month}">
          <div class="row"><label>From<input type="date" name="from" value="${today}" required></label><label>To<input type="date" name="to" value="${addDays(today, 27)}" required></label></div>
          <p class="fieldlabel">On these days</p>
          <div class="dows">${[1, 2, 3, 4, 5, 6, 0].map((i) => `<label class="check"><input type="checkbox" name="dow" value="${i}" ${i >= 1 && i <= 5 ? 'checked' : ''}> ${DOW[i]}</label>`).join('')}</div>
          <label>Set to<select name="kind"><option value="hours">Working hours</option><option value="off">Not working</option><option value="any">Any time (clear)</option></select></label>
          <div class="row"><label>Start<input type="time" name="start" value="08:00" step="900"></label><label>Finish<input type="time" name="end" value="17:00" step="900"></label></div>
          <p class="hint">For example: full time Mon to Fri 06:00 to 21:00, or part time Tue and Thu 09:00 to 14:00, for the next 4 weeks.</p>
          <button class="primary">Apply</button>
        </form>

        <h2>Holidays</h2>
        <form method="post" action="/availability/holiday" class="panel">
          <input type="hidden" name="user" value="${who.id}"><input type="hidden" name="month" value="${month}">
          <div class="row"><label>First day off<input type="date" name="from" required></label><label>Last day off<input type="date" name="to" required></label></div>
          <label>Note (optional)<input name="note" maxlength="100" placeholder="Holiday, training, appointment"></label>
          <button class="primary">Book time off</button>
        </form>
        ${holidays.length ? `<ul class="certlist">${holidays.map((h) => `<li><strong>${day(h.s)}${h.e !== h.s ? ` to ${day(h.e)}` : ''}</strong> <span class="muted">${esc(h.note || '')}</span>
          <form method="post" action="/availability/holiday/${h.id}/delete" class="inline"><input type="hidden" name="user" value="${who.id}"><input type="hidden" name="month" value="${month}"><button class="small">Remove</button></form></li>`).join('')}</ul>`
          : '<p class="empty">No time off booked.</p>'}
      </section>
    </div>`;
  const notice = req.query.saved ? 'Saved.' : req.query.clash ? 'Time off booked. It clashes with some bookings, so the office has been told.' : null;
  res.send(page({ title: who.id === req.user.id ? 'My availability' : `Availability: ${who.name}`, user: req.user, notice, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
}));

async function setDay(userId, iso, kind, start, end) {
  if (kind === 'any') return query('DELETE FROM staff_availability WHERE user_id = $1 AND date = $2', [userId, iso]);
  return query(
    `INSERT INTO staff_availability (user_id, date, kind, start_time, end_time) VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (user_id, date) DO UPDATE SET kind = EXCLUDED.kind, start_time = EXCLUDED.start_time, end_time = EXCLUDED.end_time`,
    [userId, iso, kind, kind === 'hours' ? start : null, kind === 'hours' ? end : null]);
}
const hoursOk = (s, e) => validTime(s) && validTime(e) && s < e;

router.post('/availability', staff, wrap(async (req, res) => {
  const who = await whoFor(req, req.body.user);
  const month = /^\d{4}-\d{2}$/.test(req.body.month || '') ? req.body.month : '';
  const today = ukDate(new Date());
  let bad = 0;
  for (const [k, v] of Object.entries(req.body)) {
    const m = k.match(/^k_(\d{4}-\d{2}-\d{2})$/);
    if (!m || m[1] < today || (month && !m[1].startsWith(month))) continue;
    const iso = m[1];
    const kind = ['any', 'hours', 'off'].includes(v) ? v : 'any';
    const s = req.body[`s_${iso}`];
    const e = req.body[`e_${iso}`];
    if (kind === 'hours' && !hoursOk(s, e)) { bad++; continue; }
    await setDay(who.id, iso, kind, s, e);
  }
  res.redirect(backTo(who, month, bad ? `&error=${encodeURIComponent(`${bad} day${bad === 1 ? '' : 's'} with set hours need a start before the finish, so weren’t changed.`)}` : '&saved=1'));
}));

router.post('/availability/fill', staff, wrap(async (req, res) => {
  const who = await whoFor(req, req.body.user);
  const { from, to, kind, start, end } = req.body;
  const dows = [].concat(req.body.dow || []).map(Number);
  if (!isDate(from) || !isDate(to) || from > to) return res.redirect(backTo(who, req.body.month, `&error=${encodeURIComponent('Choose a from and to date.')}`));
  if (!['any', 'hours', 'off'].includes(kind)) return res.redirect(backTo(who, req.body.month));
  if (kind === 'hours' && !hoursOk(start, end)) return res.redirect(backTo(who, req.body.month, `&error=${encodeURIComponent('The start time must be before the finish time.')}`));
  const today = ukDate(new Date());
  let n = 0;
  for (let d = from < today ? today : from; d <= to && n < 400; d = addDays(d, 1)) {
    if (!dows.includes(weekday(d))) continue;
    await setDay(who.id, d, kind, start, end);
    n++;
  }
  res.redirect(backTo(who, from.slice(0, 7), '&saved=1'));
}));

router.post('/availability/holiday', staff, wrap(async (req, res) => {
  const who = await whoFor(req, req.body.user);
  const { from, to } = req.body;
  if (!isDate(from) || !isDate(to) || from > to) return res.redirect(backTo(who, req.body.month, `&error=${encodeURIComponent('Choose the first and last day off.')}`));
  const note = String(req.body.note || '').trim().slice(0, 100) || null;
  await query('INSERT INTO staff_time_off (user_id, start_date, end_date, note) VALUES ($1, $2, $3, $4)', [who.id, from, to, note]);

  // Tell the office about anything already booked in those dates.
  const clashes = (await query(
    `SELECT id, title, 'job' AS what FROM jobs WHERE status IN ('scheduled', 'in_progress', 'parts_ordered') AND assigned_builder_id = $1
       AND scheduled_start <= $3::date AND coalesce(scheduled_end, scheduled_start) >= $2::date
     UNION ALL
     SELECT id, title, 'inspection' FROM jobs WHERE status = 'inspection_booked' AND inspection_builder_id = $1
       AND (inspection_at AT TIME ZONE 'Europe/London')::date BETWEEN $2::date AND $3::date`, [who.id, from, to])).rows;
  await notifyOffice(`${who.name} has booked time off: ${day(from)}${to !== from ? ` to ${day(to)}` : ''}`,
    `${who.name} won’t be working ${day(from)}${to !== from ? ` to ${day(to)}` : ''}${note ? ` (${note})` : ''}.${clashes.length
      ? `\n\nThese bookings clash and need moving:\n${clashes.map((c) => `- ${c.what === 'job' ? 'Job' : 'Inspection'}: ${c.title} ${baseUrlOf(req)}/jobs/${c.id}`).join('\n')}`
      : '\n\nNothing already booked clashes.'}`);
  res.redirect(backTo(who, from.slice(0, 7), clashes.length ? '&clash=1' : '&saved=1'));
}));

router.post('/availability/holiday/:id/delete', staff, wrap(async (req, res) => {
  const who = await whoFor(req, req.body.user);
  await query('DELETE FROM staff_time_off WHERE id = $1 AND user_id = $2', [Number(req.params.id) || 0, who.id]);
  res.redirect(backTo(who, req.body.month, '&saved=1'));
}));

module.exports = router;
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
    const builders = (await query("SELECT id, name FROM users WHERE role IN ('builder', 'manager') AND active ORDER BY name")).rows;
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
    const ok = (await query("SELECT 1 FROM users WHERE id = $1 AND role IN ('builder', 'manager') AND active", [builderId])).rows.length;
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

cat > src/routes/certs.js <<'HANDYTRIO_EOF'
// Gas and electrical certificates: engineers fill them in on the job, issuing locks them,
// the customer is emailed a PDF copy and the office keeps the record.
const express = require('express');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day } = require('../format');
const { loadJob, notFound, baseUrlOf } = require('../jobs-shared');
const { sendEmail, fill, jobVars } = require('../notify');
const { TYPES, QUAL_KINDS, typeOptions } = require('../certtypes');
const { buildCertificatePdf } = require('../certpdf');

const router = express.Router();
const staff = requireRole('admin', 'builder');
const certNo = (c) => `${TYPES[c.type] ? TYPES[c.type].prefix : 'CERT'}-${String(c.id).padStart(5, '0')}`;
const todayISO = () => new Date().toISOString().slice(0, 10);

// Current (in-date) qualifications for a person, keyed by kind.
async function currentQuals(userId) {
  const rows = (await query('SELECT * FROM staff_qualifications WHERE user_id = $1 AND expires >= current_date ORDER BY expires DESC', [userId])).rows;
  const byKind = {};
  for (const q of rows) if (!byKind[q.kind]) byKind[q.kind] = q;
  return byKind;
}
const qualFor = (type, quals) => TYPES[type].requires.map((k) => quals[k]).find(Boolean) || null;

// ---------- Panel on the job page ----------
async function certificatesPanel(job, user) {
  const certs = (await query(
    `SELECT c.*, u.name AS by_name FROM certificates c JOIN users u ON u.id = c.engineer_id
     WHERE c.job_id = $1 ${user.role === 'customer' ? "AND c.status = 'issued'" : ''} ORDER BY c.id`, [job.id])).rows;
  let start = '';
  if (user.role !== 'customer') {
    const quals = await currentQuals(user.id);
    const allowed = Object.entries(TYPES).filter(([k]) => qualFor(k, quals));
    start = allowed.length
      ? `<form method="post" action="/jobs/${job.id}/certs" class="inline-form">
          <label>New certificate<select name="type">${allowed.map(([k, t]) => `<option value="${k}">${esc(t.name)}</option>`).join('')}</select></label>
          <button class="small">Start</button>
        </form>`
      : `<p class="hint">You need an in-date Gas Safe, electrical or PAT qualification on your profile to fill in certificates. The office adds these on the People page.</p>`;
  }
  if (!certs.length && user.role === 'customer') return '';
  const list = certs.length ? `<ul class="certlist">${certs.map((c) => {
    const t = TYPES[c.type] || { name: c.type, bad: () => false };
    const tag = c.status === 'draft' ? '<span class="tag">Draft</span>' : c.status === 'void' ? '<span class="tag">Cancelled</span>'
      : `<span class="tag ${t.bad(c.outcome || '') ? 'urgent' : 'ok'}">${esc(c.outcome)}</span>`;
    return `<li>
      <a href="/jobs/${job.id}/certs/${c.id}"><strong>${esc(t.name)}</strong> ${certNo(c)}</a> ${tag}
      <span class="muted">${c.status === 'issued' ? `issued ${day(c.issued_at)}` : `started ${day(c.created_at)}`}${user.role !== 'customer' ? ` by ${esc(c.by_name)}` : ''}${c.next_due ? `, next due ${day(c.next_due)}` : ''}</span>
      ${c.status !== 'draft' ? `<a class="button small" href="/jobs/${job.id}/certs/${c.id}/pdf" target="_blank" rel="noopener">PDF</a>` : ''}
    </li>`;
  }).join('')}</ul>` : '<p class="empty">No certificates on this job yet.</p>';
  return `<section class="panel" id="certs"><h2>Certificates</h2>${list}${start}</section>`;
}

// Engineers on the job (beyond the main builder), so a gas engineer or electrician can open it.
async function teamPanel(job, user) {
  if (user.role !== 'admin') return '';
  const team = (await query('SELECT u.id, u.name FROM job_team t JOIN users u ON u.id = t.user_id WHERE t.job_id = $1 ORDER BY u.name', [job.id])).rows;
  const engineers = (await query(
    `SELECT DISTINCT u.id, u.name, string_agg(DISTINCT q.kind, ', ') AS kinds FROM users u JOIN staff_qualifications q ON q.user_id = u.id
     WHERE u.active AND u.role IN ('builder', 'admin', 'manager') AND q.expires >= current_date GROUP BY u.id, u.name ORDER BY u.name`)).rows
    .filter((e) => !team.some((t) => t.id === e.id) && e.id !== job.assigned_builder_id);
  return `<section class="panel staffonly"><h2>Engineers on this job <span class="tag">Office only</span></h2>
    ${team.length ? `<ul class="certlist">${team.map((t) => `<li>${esc(t.name)}
      <form method="post" action="/jobs/${job.id}/team/${t.id}/remove" class="inline"><button class="small">Remove</button></form></li>`).join('')}</ul>`
      : '<p class="muted">Only the main builder can see this job. Add a gas engineer or electrician so they can open it and fill in certificates.</p>'}
    ${engineers.length ? `<form method="post" action="/jobs/${job.id}/team" class="inline-form">
      <label>Add engineer<select name="user_id">${engineers.map((e) => `<option value="${e.id}">${esc(e.name)} (${esc(e.kinds)})</option>`).join('')}</select></label>
      <button class="small">Add</button></form>` : ''}
  </section>`;
}

router.post('/jobs/:id/team', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const uid = Number(req.body.user_id) || 0;
  if (uid) await query('INSERT INTO job_team (job_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [job.id, uid]);
  res.redirect(`/jobs/${job.id}#certs`);
}));

router.post('/jobs/:id/team/:uid/remove', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  await query('DELETE FROM job_team WHERE job_id = $1 AND user_id = $2', [job.id, Number(req.params.uid) || 0]);
  res.redirect(`/jobs/${job.id}#certs`);
}));

// ---------- Create ----------
router.post('/jobs/:id/certs', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const type = String(req.body.type || '');
  if (!TYPES[type]) return res.redirect(`/jobs/${job.id}#certs`);
  if (!qualFor(type, await currentQuals(req.user.id))) {
    return res.redirect(`/jobs/${job.id}?error=${encodeURIComponent('You don’t have an in-date qualification for that certificate.')}#certs`);
  }
  // Start with what we already know about the customer and site.
  const data = {};
  if (type === 'gas_safety') data.tenant_name = job.customer_name;
  if (type === 'eicr') { data.client_name = job.customer_name; data.occupier = job.customer_name; }
  if (type === 'pat') { data.client_name = job.customer_name; data.site = [job.address_line, job.town, job.postcode].filter(Boolean).join(', '); }
  const { rows } = await query('INSERT INTO certificates (job_id, type, engineer_id, data) VALUES ($1, $2, $3, $4) RETURNING id',
    [job.id, type, req.user.id, JSON.stringify(data)]);
  res.redirect(`/jobs/${job.id}/certs/${rows[0].id}`);
}));

async function loadCert(req, job) {
  return (await query('SELECT * FROM certificates WHERE id = $1 AND job_id = $2', [Number(req.params.cid) || 0, job.id])).rows[0] || null;
}

// ---------- Form ----------
function input(name, f, value) {
  const [, lbl, type] = f;
  const v = value ?? '';
  if (type === 'textarea') return `<label>${esc(lbl)}<textarea name="${name}" rows="2" maxlength="3000">${esc(v)}</textarea></label>`;
  if (['yn', 'pf', 'select'].includes(type)) {
    const opts = typeOptions(f);
    return `<label>${esc(lbl)}<select name="${name}"><option value=""></option>${opts.map((o) => `<option ${o === v ? 'selected' : ''}>${esc(o)}</option>`).join('')}</select></label>`;
  }
  if (type === 'date') return `<label>${esc(lbl)}<input type="date" name="${name}" value="${esc(v)}"></label>`;
  if (type === 'number') return `<label>${esc(lbl)}<input type="text" inputmode="decimal" name="${name}" value="${esc(v)}" maxlength="20"></label>`;
  return `<label>${esc(lbl)}<input name="${name}" value="${esc(v)}" maxlength="300"></label>`;
}

function readForm(t, body) {
  const data = {};
  const clean = (v) => String(v ?? '').trim().slice(0, 3000);
  for (const sec of t.sections) {
    if (!sec.group) {
      for (const [k] of sec.fields) { const v = clean(body[k]); if (v) data[k] = v; }
      continue;
    }
    const count = Math.min(Number(body[`${sec.group}__count`]) || 0, 300);
    const items = [];
    for (let i = 0; i < count; i++) {
      if (body[`${sec.group}__${i}__del`] === 'on') continue;
      const item = {};
      for (const [k] of sec.fields) { const v = clean(body[`${sec.group}__${i}__${k}`]); if (v) item[k] = v; }
      if (Object.keys(item).length) items.push(item);
    }
    data[sec.group] = items;
  }
  return data;
}

function certFormSections(t, d) {
  return t.sections.map((sec) => {
    if (!sec.group) {
      return `<fieldset class="panel"><legend>${esc(sec.title)}</legend><div class="certgrid">${sec.fields.map((f) => input(f[0], f, d[f[0]])).join('')}</div></fieldset>`;
    }
    const items = d[sec.group] || [];
    const count = items.length + sec.blank;
    const rows = [];
    for (let i = 0; i < count; i++) {
      const item = items[i] || {};
      rows.push(`<div class="certitem ${items[i] ? '' : 'new'}">
        <p class="fieldlabel">${esc(sec.itemLabel)} ${i + 1}${items[i] ? '' : ' (leave blank if not needed)'}</p>
        <div class="certgrid">${sec.fields.map((f) => input(`${sec.group}__${i}__${f[0]}`, f, item[f[0]])).join('')}</div>
        ${items[i] ? `<label class="check"><input type="checkbox" name="${sec.group}__${i}__del"> Remove</label>` : ''}
      </div>`);
    }
    return `<fieldset class="panel"><legend>${esc(sec.title)}</legend><input type="hidden" name="${sec.group}__count" value="${count}">${rows.join('')}
      <p class="hint">Save to get more blank ${esc(sec.itemLabel.toLowerCase())} rows.</p>${sec.group === 'observations' && t.codesNote ? `<p class="hint">${esc(t.codesNote)}</p>` : ''}</fieldset>`;
  }).join('');
}

router.get('/jobs/:id/certs/:cid', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const c = await loadCert(req, job);
  if (!c || (req.user.role === 'customer' && c.status !== 'issued')) return notFound(req, res);
  const t = TYPES[c.type];
  const d = c.data || {};
  const editable = c.status === 'draft' && c.engineer_id === req.user.id;

  if (!editable) {
    const actions = req.user.role === 'admin' && c.status === 'issued' ? `
      <form method="post" action="/jobs/${job.id}/certs/${c.id}/resend" class="inline"><button class="small">Email the customer again</button></form>
      <details class="recordpay"><summary>Cancel this certificate</summary>
        <form method="post" action="/jobs/${job.id}/certs/${c.id}/void" class="panel">
          <label>Reason<input name="reason" required maxlength="300"></label>
          <button class="small danger">Cancel certificate</button>
        </form></details>` : '';
    const body = `<p class="jobhead"><a href="/jobs/${job.id}#certs">Back to the job</a></p>
      <section class="panel quote">
        <div class="quotehead"><h2>${certNo(c)}</h2><span class="tag ${c.status === 'issued' && !t.bad(c.outcome || '') ? 'ok' : 'urgent'}">${esc(c.status === 'issued' ? c.outcome : c.status === 'void' ? 'Cancelled' : 'Draft')}</span></div>
        <p class="muted">${c.status === 'issued' ? `Issued ${day(c.issued_at)} by ${esc(c.engineer_name)}` : 'Not issued yet'}${c.next_due ? `. Next due ${day(c.next_due)}` : ''}${c.sent_to && req.user.role !== 'customer' ? `. Emailed to ${esc(c.sent_to)} ${day(c.sent_at)}` : ''}</p>
        ${c.status === 'void' ? `<p class="error">Cancelled: ${esc(c.void_reason)}</p>` : ''}
        <div class="buttons">
          <a class="button primary" href="/jobs/${job.id}/certs/${c.id}/pdf" target="_blank" rel="noopener">View or print</a>
          <a class="button" href="/jobs/${job.id}/certs/${c.id}/pdf?download=1">Download PDF</a>
        </div>
        ${actions}
      </section>`;
    return res.send(page({ title: t.name, user: req.user, notice: req.query.issued ? 'Certificate issued and sent.' : req.query.sent ? 'Sent again.' : null, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
  }

  const sections = certFormSections(t, d);

  const body = `<p class="jobhead"><a href="/jobs/${job.id}#certs">Back to the job</a> <span class="ref">${certNo(c)}</span> <span class="tag">Draft</span></p>
    <form method="post" action="/jobs/${job.id}/certs/${c.id}" class="certform">
      ${sections}
      <div class="buttons"><button name="action" value="save" class="small">Save draft</button>
        <a class="button" href="/jobs/${job.id}/certs/${c.id}/pdf" target="_blank" rel="noopener">Preview PDF</a></div>
      <fieldset class="panel issue">
        <legend>Issue the certificate</legend>
        <p>Issuing locks the certificate, emails a PDF copy to the customer (${esc(job.customer_email)}) and keeps the office copy on the system.</p>
        <label class="check"><input type="checkbox" name="declare"> I confirm the inspection and tests recorded were carried out by me and are a true record.</label>
        <label>Your full name<input name="declaration_name" value="${esc(req.user.name)}" maxlength="120"></label>
        <button name="action" value="issue" class="primary">Issue and send</button>
      </fieldset>
      <p><button name="action" value="delete" class="small danger">Delete this draft</button></p>
    </form>`;
  res.send(page({ title: t.name, user: req.user, notice: req.query.saved ? 'Draft saved.' : null, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
}));

async function emailCertificate(req, job, c) {
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const t = TYPES[c.type];
  const cust = (await query('SELECT name, email FROM users WHERE id = $1', [job.customer_id])).rows[0];
  const pdf = await buildCertificatePdf({ cert: c, number: certNo(c), job: { ...job, ref: ref(job.id) }, customer: cust, s });
  const tpl = (await query("SELECT * FROM email_templates WHERE status = 'cert_issued'")).rows[0];
  const data = await jobVars(job.id, job.status, baseUrlOf(req));
  const vars = { ...data.vars, cert_name: t.name, cert_number: certNo(c) };
  const attachments = [{ filename: `${certNo(c)}.pdf`, content: pdf, contentType: 'application/pdf' }];
  let result = { status: 'skipped' };
  if (tpl && tpl.enabled) {
    result = await sendEmail({ to: cust.email, subject: fill(tpl.subject, vars), body: fill(tpl.body, vars), jobId: job.id, attachments });
  }
  // Office copy.
  if (s.business_email) {
    await sendEmail({ to: s.business_email, subject: `[${s.business_name}] Office copy: ${t.name} ${certNo(c)} (${ref(job.id)})`,
      body: `${t.name} ${certNo(c)} issued by ${c.engineer_name}. Outcome: ${c.outcome}.\n\n${baseUrlOf(req)}/jobs/${job.id}/certs/${c.id}`, jobId: job.id, attachments });
  }
  await query('UPDATE certificates SET sent_to = $1, sent_at = now() WHERE id = $2', [cust.email, c.id]);
  return result;
}

router.post('/jobs/:id/certs/:cid', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const c = await loadCert(req, job);
  if (!c || c.status !== 'draft' || c.engineer_id !== req.user.id) return res.redirect(`/jobs/${job.id}#certs`);
  const t = TYPES[c.type];

  if (req.body.action === 'delete') {
    await query("DELETE FROM certificates WHERE id = $1 AND status = 'draft'", [c.id]);
    return res.redirect(`/jobs/${job.id}#certs`);
  }

  const data = readForm(t, req.body);
  await query('UPDATE certificates SET data = $1, updated_at = now() WHERE id = $2', [JSON.stringify(data), c.id]);
  if (req.body.action !== 'issue') return res.redirect(`/jobs/${job.id}/certs/${c.id}?saved=1`);

  const qual = qualFor(c.type, await currentQuals(req.user.id));
  const name = String(req.body.declaration_name || '').trim().slice(0, 120);
  let error = null;
  if (!qual) error = 'Your qualification for this certificate has expired or is missing, so it can’t be issued.';
  else if (req.body.declare !== 'on' || !name) error = 'Tick the declaration and type your name to issue.';
  else if (t.nextDueField && !data[t.nextDueField]) error = 'Fill in the recommended next inspection date.';
  else if (t.sections.some((sec) => sec.group && sec.blank && ['appliances', 'items'].includes(sec.group) && !(data[sec.group] || []).length)) error = 'Add at least one appliance.';
  if (error) return res.redirect(`/jobs/${job.id}/certs/${c.id}?error=${encodeURIComponent(error)}`);

  let nextDue = null;
  if (t.nextDueField) nextDue = data[t.nextDueField];
  else if (t.nextDueFromItems) {
    const months = Math.min(...(data.items || []).map((i) => Number(i[t.nextDueFromItems]) || 12));
    nextDue = addMonths(Number.isFinite(months) ? months : 12);
  } else if (t.nextDueMonths) nextDue = addMonths(t.nextDueMonths);

  const outcome = t.outcome(data);
  const updated = (await query(
    `UPDATE certificates SET status = 'issued', outcome = $1, issued_at = now(), next_due = $2, declaration_name = $3,
       engineer_name = $4, engineer_scheme = $5, engineer_number = $6, engineer_categories = $7, updated_at = now()
     WHERE id = $8 AND status = 'draft' RETURNING *`,
    [outcome, nextDue, name, req.user.name, qual.scheme || QUAL_KINDS[qual.kind].scheme, qual.number, qual.categories, c.id])).rows[0];
  if (updated) await emailCertificate(req, job, updated);
  res.redirect(`/jobs/${job.id}/certs/${c.id}?issued=1`);
}));

function addMonths(m) {
  const d = new Date();
  d.setMonth(d.getMonth() + m);
  return d.toISOString().slice(0, 10);
}

router.post('/jobs/:id/certs/:cid/resend', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const c = await loadCert(req, job);
  if (c && c.status === 'issued') await emailCertificate(req, job, c);
  res.redirect(`/jobs/${job.id}/certs/${req.params.cid}?sent=1`);
}));

router.post('/jobs/:id/certs/:cid/void', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const reason = String(req.body.reason || '').trim().slice(0, 300);
  if (reason) await query("UPDATE certificates SET status = 'void', void_reason = $1, updated_at = now() WHERE id = $2 AND job_id = $3 AND status = 'issued'", [reason, Number(req.params.cid) || 0, job.id]);
  res.redirect(`/jobs/${job.id}/certs/${req.params.cid}`);
}));

router.get('/jobs/:id/certs/:cid/pdf', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const c = await loadCert(req, job);
  if (!c || (req.user.role === 'customer' && c.status !== 'issued')) return notFound(req, res);
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const cust = (await query('SELECT name FROM users WHERE id = $1', [job.customer_id])).rows[0];
  let cert = c;
  if (c.status === 'draft') {
    // Preview shows the engineer's details as they will appear.
    const q = qualFor(c.type, await currentQuals(c.engineer_id));
    const eng = (await query('SELECT name FROM users WHERE id = $1', [c.engineer_id])).rows[0];
    cert = { ...c, outcome: TYPES[c.type].outcome(c.data || {}), engineer_name: eng.name, engineer_scheme: q && q.scheme, engineer_number: q && q.number, engineer_categories: q && q.categories };
  }
  const pdf = await buildCertificatePdf({ cert, number: certNo(c), job: { ...job, ref: ref(job.id) }, customer: cust, s });
  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `${req.query.download ? 'attachment' : 'inline'}; filename="${certNo(c)}.pdf"`);
  res.send(pdf);
}));

// ---------- Office register of all certificates ----------
router.get('/admin/certificates', requireRole('admin'), wrap(async (req, res) => {
  const type = TYPES[req.query.type] ? req.query.type : '';
  const due = req.query.due === '1';
  const params = [];
  const where = ["c.status <> 'draft'", 'NOT c.private'];
  if (type) { params.push(type); where.push(`c.type = $${params.length}`); }
  if (due) where.push("c.status = 'issued' AND c.next_due <= current_date + 60");
  const rows = (await query(
    `SELECT c.*, j.title, j.postcode, cu.name AS customer_name FROM certificates c JOIN jobs j ON j.id = c.job_id JOIN users cu ON cu.id = j.customer_id
     WHERE ${where.join(' AND ')} ORDER BY ${due ? 'c.next_due' : 'c.issued_at DESC'} LIMIT 300`, params)).rows;
  const body = `<p><a class="button primary" href="/certify">Certify (my own private work)</a></p>
    <form method="get" action="/admin/certificates" class="filters">
      <label>Type<select name="type"><option value="">All types</option>${Object.entries(TYPES).map(([k, t]) => `<option value="${k}" ${k === type ? 'selected' : ''}>${esc(t.name)}</option>`).join('')}</select></label>
      <label class="check"><input type="checkbox" name="due" value="1" ${due ? 'checked' : ''}> Due in the next 60 days or overdue</label>
      <button class="small">Show</button>
    </form>
    ${rows.length ? `<div class="scroll"><table>
      <thead><tr><th>Number</th><th>Type</th><th>Customer</th><th>Postcode</th><th>Outcome</th><th>Engineer</th><th>Issued</th><th>Next due</th></tr></thead>
      <tbody>${rows.map((c) => {
        const t = TYPES[c.type];
        const overdue = c.next_due && new Date(c.next_due) < new Date(new Date().toDateString());
        return `<tr class="${c.status === 'void' ? 'off' : ''}">
          <td><a href="/jobs/${c.job_id}/certs/${c.id}">${certNo(c)}</a></td><td>${esc(t ? t.name : c.type)}</td>
          <td><a href="/jobs/${c.job_id}">${esc(c.customer_name)}</a></td><td>${esc(c.postcode)}</td>
          <td>${c.status === 'void' ? 'Cancelled' : `<span class="tag ${t && t.bad(c.outcome || '') ? 'urgent' : 'ok'}">${esc(c.outcome)}</span>`}</td>
          <td>${esc(c.engineer_name)}</td><td>${day(c.issued_at)}</td>
          <td>${c.next_due ? `${overdue ? '<span class="tag urgent">Overdue</span> ' : ''}${day(c.next_due)}` : ''}</td></tr>`;
      }).join('')}</tbody></table></div>` : '<p class="empty">No certificates match.</p>'}`;
  res.send(page({ title: 'Certificates', user: req.user, body }));
}));

module.exports = { router, certificatesPanel, teamPanel, currentQuals, qualFor, certFormSections, readForm, addMonths, certNo };
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
    `SELECT base_postcode, (SELECT count(*)::int FROM users WHERE role IN ('builder', 'manager') AND active AND coalesce(postcode, '') <> '') AS builder_postcodes
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
    `SELECT count(*)::int AS n FROM certificates WHERE status = 'issued' AND NOT private AND next_due <= current_date + 30`)).rows[0].n;
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
  const { loadAvailability, dayStatus, statusLabel } = require('../availability');
  const staffRows = (await query("SELECT id, name FROM users WHERE role IN ('builder', 'manager') AND active ORDER BY name")).rows;
  const avToday = await loadAvailability(staffRows.map((b) => b.id), todayISO, todayISO);
  const notAny = staffRows.map((b) => ({ b, st: dayStatus(avToday, b.id, todayISO) })).filter((x) => x.st.state !== 'any');
  const whoOff = notAny.length ? `<p class="muted">${notAny.map((x) => `${esc(x.b.name)}: ${esc(statusLabel(x.st))}`).join(' · ')}</p>` : '';
  let myWeek = '';
  if (user.isManager) {
    const mine = (await eventsBetween(todayISO, addDays(todayISO, 6), user.id)).sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));
    const clockedOn = (await query(
      `SELECT t.job_id, j.title FROM job_time_entries t JOIN jobs j ON j.id = t.job_id WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
    myWeek = `${clockedOn ? `<div class="notice">You’re clocked on to <a href="/jobs/${clockedOn.job_id}#time">${esc(clockedOn.title)}</a>.</div>` : ''}
      <h2>My jobs this week</h2>${mine.length ? `<div class="soon">${mine.map((e) => `<div><span class="muted">${e.start === todayISO ? 'Today' : day(e.start)}</span>${eventChip(e)}</div>`).join('')}</div>` : '<p class="empty">Nothing booked for you in the next 7 days.</p>'}`;
  }
  const todayBox = `${myWeek}<h2>Today</h2>${whoOff}${todays.length ? `<div class="soon">${todays.map(eventChip).join('')}</div>` : '<p class="empty">Nothing booked today.</p>'}<p><a href="/calendar">Open the calendar</a></p>`;
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
     WHERE u.role IN ('builder', 'admin', 'manager') AND u.active GROUP BY u.id ORDER BY u.name`, [fromTs, toTs])).rows.filter((b) => N(b.hours) > 0 || b.finished > 0);

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
const { loadAvailability, blockedDates } = require('../availability');

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
    const builders = (await query("SELECT id, name FROM users WHERE role IN ('builder', 'manager') AND active ORDER BY name")).rows;
    const iso = (d) => (d ? new Date(d).toLocaleDateString('en-CA') : '');
    parts.push(`<h3>${job.status === 'scheduled' ? 'Change the booking' : 'Book the job in'}</h3>
      <form method="post" action="/jobs/${job.id}/schedule" class="schedule">
        <label>Builder<select name="builder_id" required>${builders.map((b) => `<option value="${b.id}" ${b.id === job.assigned_builder_id ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}</select></label>
        <label>Start<input type="date" name="start" value="${iso(job.scheduled_start)}" required></label>
        <label>Finish (optional)<input type="date" name="end" value="${iso(job.scheduled_end)}"></label>
        <label class="check"><input type="checkbox" name="override"> Book anyway, even if they’re off</label>
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
  const b = builderId && (await query("SELECT id, name FROM users WHERE id = $1 AND role IN ('builder', 'manager') AND active", [builderId])).rows[0];
  if (!b) return errorBack(res, job, 'Choose a builder.');
  const av = await loadAvailability([b.id], start, end || start);
  const blocked = blockedDates(av, b.id, start, end || start);
  if (blocked.length && req.body.override !== 'on') {
    return errorBack(res, job, `${b.name} is off on ${blocked.map((x) => `${day(x.date)}${x.state === 'holiday' ? ' (holiday)' : ''}`).join(', ')}. Choose other dates or tick “Book anyway”.`);
  }
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
  const roleOpt = (r) => `<option value="${r}" ${v.role === r ? 'selected' : ''}>${ROLE_LABELS[r]}${r === 'manager' ? ' (admin and builder)' : ''}</option>`;
  return `
    <label>Full name<input name="name" value="${esc(v.name)}" required maxlength="120"></label>
    <label>Email<input type="email" name="email" value="${esc(v.email)}" required></label>
    <label>Phone<input type="tel" name="phone" value="${esc(v.phone)}"></label>
    ${isSelf ? `<label>Role<select name="role">${['admin', 'manager'].map(roleOpt).join('')}</select></label>` : `<label>Role<select name="role">${['builder', 'manager', 'admin', 'customer'].map(roleOpt).join('')}</select></label>`}
    <label>Address<input name="address_line" value="${esc(v.address_line)}"></label>
    <div class="row">
      <label>Town<input name="town" value="${esc(v.town)}"></label>
      <label>Postcode<input name="postcode" value="${esc(v.postcode)}"></label>
    </div>
    <p class="hint">For builders this is their home postcode. Travel costs are worked out from it.</p>
    ${v.role === 'customer' ? '' : `<label>Pay rate per hour (£, used for profit reports)<input name="cost_rate" type="number" step="0.01" min="0" value="${esc(v.cost_rate ?? '')}"></label>`}
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
  if (['builder', 'manager'].includes(v.role) && v.postcode && !(await locate(v.postcode))) {
    return `The postcode ${v.postcode} couldn’t be found. Check it, or leave it blank for now.`;
  }
  return null;
}

async function renderList(req, res, { notice, error, v = {} } = {}) {
  const { rows } = await query(
    `SELECT u.id, u.role, u.name, u.email, u.phone, u.postcode, u.active, u.cost_rate,
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
    <td>${['builder', 'manager'].includes(u.role) && !u.postcode ? '<span class="tag urgent">Needs postcode</span>' : esc(u.postcode)}</td>
    <td>${qualTags(u.quals)}</td>
    <td>${u.role === 'customer' ? '' : `<form method="post" action="/admin/users/${u.id}/rate" class="rateform"><span>£</span><input name="cost_rate" type="number" step="0.01" min="0" value="${u.cost_rate === null ? '' : Number(u.cost_rate)}" aria-label="Pay rate per hour for ${esc(u.name)}"><span>/hr</span><button class="small">Save</button></form>`}</td>
    <td>${u.active ? 'Active' : 'Switched off'}</td>
    <td>${u.id === req.user.id ? '<span class="muted">You</span>' : `<form method="post" action="/admin/users/${u.id}/toggle" class="inline"><button class="small">${u.active ? 'Switch off' : 'Switch on'}</button></form>`}</td>
  </tr>`).join('');
  const body = `
    <div class="scroll"><table>
      <thead><tr><th>Name</th><th>Email</th><th>Phone</th><th>Role</th><th>Postcode</th><th>Qualifications</th><th>Pay rate</th><th>Status</th><th></th></tr></thead>
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
    ${u.role !== 'customer' ? `<p><a class="button" href="/availability?user=${u.id}">Working hours and holidays</a></p>` : ''}
    <p><a href="/admin/users">Back to people</a></p>`;
  res.send(page({ title: `Edit ${u.name}`, user: req.user, error: req.query.error ? clean(req.query.error) : null, body }));
}));

router.post('/admin/users/:id', admin, wrap(async (req, res) => {
  const id = Number(req.params.id);
  const existing = Number.isInteger(id) && (await query('SELECT id, role FROM users WHERE id = $1', [id])).rows[0];
  if (!existing) return res.redirect('/admin/users');
  const v = readPerson(req.body);
  // You can switch yourself between Admin and Manager, but never lock yourself out of the office side.
  if (id === req.user.id && !['admin', 'manager'].includes(v.role)) v.role = existing.role;
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

router.post('/admin/users/:id/rate', admin, wrap(async (req, res) => {
  const raw = String(req.body.cost_rate ?? '').trim();
  const rate = raw === '' ? null : Math.max(0, Number(raw) || 0);
  await query("UPDATE users SET cost_rate = $1 WHERE id = $2 AND role <> 'customer'", [rate, Number(req.params.id) || 0]);
  res.redirect('/admin/users?saved=1');
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

echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "Manager role installed. The app restarts by itself; otherwise run: npm run dev"
