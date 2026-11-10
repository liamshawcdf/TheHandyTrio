#!/usr/bin/env bash
# Rebrand to SWAT Maintenance: name, colours and logo all set from Settings. Run with: bash rebrand.sh
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
HANDYTRIO_EOF

cat > src/brand.js <<'HANDYTRIO_EOF'
// The business's name, colours and logo, kept in memory so every page can use them.
// Reloaded whenever Settings are saved.
const { query } = require('./db');

let cache = null;
const HEX = /^#[0-9a-f]{6}$/i;

// Dark text on light colours, white text on dark ones.
function inkFor(hex) {
  const n = parseInt(hex.slice(1), 16);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => {
    const v = c / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.4 ? '#1d2529' : '#ffffff';
}

async function loadBrand() {
  const s = (await query(
    `SELECT business_name, brand_primary, brand_accent, logo IS NOT NULL AS has_logo,
       coalesce(extract(epoch FROM logo_updated_at)::bigint, 0) AS logo_version FROM settings WHERE id = 1`)).rows[0] || {};
  const primary = HEX.test(s.brand_primary || '') ? s.brand_primary : '#24414f';
  const accent = HEX.test(s.brand_accent || '') ? s.brand_accent : '#f2c300';
  cache = {
    name: s.business_name || 'SWAT Maintenance',
    primary, accent,
    primaryInk: inkFor(primary),
    accentInk: inkFor(accent),
    hasLogo: Boolean(s.has_logo),
    logoVersion: s.logo_version || 0,
  };
  return cache;
}

const brand = () => cache || { name: 'SWAT Maintenance', primary: '#24414f', accent: '#f2c300', primaryInk: '#ffffff', accentInk: '#1d2529', hasLogo: false, logoVersion: 0 };

module.exports = { loadBrand, brand, HEX };
HANDYTRIO_EOF

cat > src/layout.js <<'HANDYTRIO_EOF'
const { brand } = require('./brand');

const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin' };

function nav(user) {
  if (!user) return '<a href="/login">Log in</a><a href="/register">Create account</a>';
  const links = ['<a href="/dashboard">Dashboard</a>'];
  if (user.role !== 'customer') links.push(`<a href="/jobs">${user.role === 'admin' ? 'All jobs' : 'My jobs'}</a>`, `<a href="/calendar">${user.role === 'admin' ? 'Calendar' : 'My diary'}</a>`);
  if (user.role === 'builder') links.push('<a href="/availability">My availability</a>', '<a href="/certify">Certify</a>');
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
    const s = (await query('SELECT business_email, business_name FROM settings WHERE id = 1')).rows[0];
    if (!s.business_email) return;
    await sendEmail({ to: s.business_email, subject: `[${s.business_name}] ${subject}`, body, jobId });
  } catch (e) {
    console.error('Office email failed:', e);
  }
}

const PLACEHOLDERS = ['inspection_time', 'booked_dates', 'cert_name', 'cert_number', 'first_name', 'customer_name', 'job_ref', 'job_title', 'stage', 'price_guide', 'job_link', 'business_name'];

module.exports = { jobVars, notifyStageChange, notifyOffice, sendEmail, fill, emailReady, PLACEHOLDERS };
HANDYTRIO_EOF

cat > src/backup.js <<'HANDYTRIO_EOF'
// Backup and restore of every business table. Used by the Backups page and scripts/restore-backup.js.
const zlib = require('zlib');

// Order matters: tables are restored top to bottom so links between them line up.
const TABLES = [
  'users', 'staff_availability', 'staff_time_off', 'settings', 'suppliers', 'price_items', 'job_templates', 'template_materials', 'access_options',
  'postcode_locations', 'email_templates', 'jobs', 'job_status_history', 'job_photos', 'job_estimate_lines',
  'job_time_entries', 'quotes', 'invoices', 'payments', 'job_parts', 'staff_qualifications', 'job_team',
  'certificates', 'email_log', 'sms_templates', 'sms_log', 'reminders_sent',
];

// The business's setup without any customers or jobs: staff, settings, price list, templates and messages.
const SETUP_TABLES = ['users', 'staff_availability', 'staff_time_off', 'settings', 'suppliers', 'price_items', 'job_templates',
  'template_materials', 'access_options', 'postcode_locations', 'email_templates', 'sms_templates', 'staff_qualifications'];

async function makeBackup(client, { includePhotos, setupOnly = false }) {
  const out = { app: 'TheHandyTrio', version: 1, created_at: new Date().toISOString(), include_photos: includePhotos, setup_only: setupOnly, tables: {} };
  for (const t of setupOnly ? SETUP_TABLES : TABLES) {
    const exists = (await client.query('SELECT to_regclass($1) AS r', [t])).rows[0].r;
    if (!exists) continue;
    const sql = setupOnly && t === 'users' ? "SELECT * FROM users WHERE role <> 'customer'"
      : t === 'job_photos' && !includePhotos
      ? 'SELECT id, job_id, stored_name, original_name, mime_type, size_bytes, uploaded_by, created_at FROM job_photos ORDER BY id'
      : `SELECT * FROM ${t}`;
    const rows = (await client.query(sql)).rows.map((r) => {
      for (const [k, v] of Object.entries(r)) if (Buffer.isBuffer(v)) r[k] = { $base64: v.toString('base64') };
      return r;
    });
    out.tables[t] = rows;
  }
  return zlib.gzipSync(Buffer.from(JSON.stringify(out)));
}

async function restoreBackup(client, gz) {
  const data = JSON.parse(zlib.gunzipSync(gz).toString('utf8'));
  if (data.app !== 'TheHandyTrio') throw new Error('This isn’t a backup file from this app.');
  const present = TABLES.filter((t) => data.tables[t]);
  await client.query('BEGIN');
  try {
    // A backup without photos keeps the photos already in the database, matched by photo number.
    const keepPhotos = !data.include_photos && data.tables.job_photos
      ? (await client.query('SELECT id, data FROM job_photos WHERE data IS NOT NULL')).rows : [];
    await client.query(`TRUNCATE ${present.join(', ')} RESTART IDENTITY CASCADE`);
    for (const t of present) {
      const cols = (await client.query(
        "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = $1 AND table_schema = 'public'", [t])).rows;
      const types = Object.fromEntries(cols.map((c) => [c.column_name, c.data_type]));
      for (const row of data.tables[t]) {
        const keys = Object.keys(row).filter((k) => types[k]);
        const vals = keys.map((k) => {
          const v = row[k];
          if (v && typeof v === 'object' && v.$base64 !== undefined) return Buffer.from(v.$base64, 'base64');
          if (types[k] === 'jsonb' || types[k] === 'json') return v === null ? null : JSON.stringify(v);
          return v;
        });
        await client.query(`INSERT INTO ${t} (${keys.map((k) => `"${k}"`).join(', ')}) VALUES (${keys.map((_, i) => `$${i + 1}`).join(', ')})`, vals);
      }
      // Carry on numbering after the restored rows.
      if (types.id) await client.query(`SELECT setval(pg_get_serial_sequence('${t}', 'id'), coalesce((SELECT max(id) FROM ${t}), 0) + 1, false)`);
    }
    for (const p of keepPhotos) await client.query('UPDATE job_photos SET data = $1 WHERE id = $2', [p.data, p.id]);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  }
  return { tables: present.length, created_at: data.created_at, include_photos: data.include_photos, setup_only: data.setup_only };
}

module.exports = { makeBackup, restoreBackup, TABLES, SETUP_TABLES };
HANDYTRIO_EOF

cat > src/pdf.js <<'HANDYTRIO_EOF'
// Branded A4 documents (quotes and invoices) with page numbers.
const PDFDocument = require('pdfkit');

// Dark text on light header colours, white on dark ones.
function inkFor(hex) {
  const n = parseInt(hex.slice(1), 16);
  const lum = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => { const v = c / 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * lum[0] + 0.7152 * lum[1] + 0.0722 * lum[2] > 0.4 ? '#1d2529' : '#ffffff';
}

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

  const primary = /^#[0-9a-f]{6}$/i.test(s.brand_primary || '') ? s.brand_primary : '#24414f';
  const accent = /^#[0-9a-f]{6}$/i.test(s.brand_accent || '') ? s.brand_accent : '#f2c300';
  const headInk = inkFor(primary);
  doc.rect(0, 0, W, 86).fill(primary);
  doc.rect(0, 86, W, 6).fill(accent);
  let nameX = L;
  if (s.logo && ['image/png', 'image/jpeg'].includes(s.logo_mime)) {
    try { doc.image(s.logo, L, 16, { fit: [150, 54], valign: 'center' }); nameX = L + 160; } catch (e) { nameX = L; }
  }
  doc.fillColor(headInk).font('Helvetica-Bold').fontSize(nameX === L ? 22 : 16).text(s.business_name, nameX, nameX === L ? 28 : 34, { width: 300 - (nameX - L) });
  const contact = [s.business_address, s.business_phone, s.business_email].filter(Boolean).join('\n');
  if (contact) doc.font('Helvetica').fontSize(9).fillColor(headInk).text(contact, R - 200, 26, { width: 200, align: 'right' });

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

cat > src/certpdf.js <<'HANDYTRIO_EOF'
// Builds a certificate PDF in memory, so it can be downloaded or attached to an email.
const PDFDocument = require('pdfkit');

// Dark text on light header colours, white on dark ones.
function inkFor(hex) {
  const n = parseInt(hex.slice(1), 16);
  const lum = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => { const v = c / 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * lum[0] + 0.7152 * lum[1] + 0.0722 * lum[2] > 0.4 ? '#1d2529' : '#ffffff';
}
const { TYPES } = require('./certtypes');

const fmtDate = (d) => (d ? new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '');

function buildCertificatePdf({ cert, number, job, customer, s }) {
  const t = TYPES[cert.type];
  const d = cert.data || {};
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 40, bufferPages: true, info: { Title: `${t.name} ${number}`, Author: s.business_name } });
    const chunks = [];
    doc.on('data', (c) => chunks.push(c));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);

    const W = doc.page.width;
    const L = 40;
    const R = W - 40;
    const ink = '#1d2529';
    const muted = '#5d6a70';
    const line = '#c9d0cd';
    const ensure = (h) => { if (doc.y + h > doc.page.height - 60) { doc.addPage(); doc.y = 50; } };

    // Header
    const primary = /^#[0-9a-f]{6}$/i.test(s.brand_primary || '') ? s.brand_primary : '#24414f';
    const accent = /^#[0-9a-f]{6}$/i.test(s.brand_accent || '') ? s.brand_accent : '#f2c300';
    const headInk = inkFor(primary);
    doc.rect(0, 0, W, 78).fill(primary);
    doc.rect(0, 78, W, 5).fill(accent);
    let nameX = L;
    if (s.logo && ['image/png', 'image/jpeg'].includes(s.logo_mime)) {
      try { doc.image(s.logo, L, 14, { fit: [140, 50], valign: 'center' }); nameX = L + 150; } catch (e) { nameX = L; }
    }
    doc.fillColor(headInk).font('Helvetica-Bold').fontSize(nameX === L ? 18 : 14).text(s.business_name, nameX, nameX === L ? 22 : 30, { width: 280 - (nameX - L) });
    const contact = [s.business_address, s.business_phone, s.business_email].filter(Boolean).join('\n');
    if (contact) doc.font('Helvetica').fontSize(8).fillColor(headInk).text(contact, R - 200, 20, { width: 200, align: 'right' });

    doc.fillColor(ink).font('Helvetica-Bold').fontSize(16).text(t.name, L, 98, { width: R - L - 170 });
    const meta = [['Number', number], ['Issued', fmtDate(cert.issued_at) || 'Draft'], ['Next due', fmtDate(cert.next_due) || 'n/a'], ...(job.ref ? [['Job', job.ref]] : [])];
    let my = 98;
    for (const [k, v] of meta) {
      doc.font('Helvetica').fontSize(8).fillColor(muted).text(k, R - 160, my, { width: 60 });
      doc.font('Helvetica-Bold').fontSize(9).fillColor(ink).text(String(v), R - 100, my, { width: 100, align: 'right' });
      my += 13;
    }
    doc.y = Math.max(doc.y, my) + 8;

    // Outcome banner
    const bad = cert.outcome && t.bad(cert.outcome);
    const by = doc.y;
    doc.rect(L, by, R - L, 24).fill(bad ? '#fbe4e1' : '#e2f1e4');
    doc.fillColor(bad ? '#8a2418' : '#1f5a2a').font('Helvetica-Bold').fontSize(11).text(`Outcome: ${cert.outcome || 'Not yet issued'}`, L + 10, by + 7, { width: R - L - 20 });
    doc.y = by + 34;

    // Parties
    const colW = (R - L - 20) / 2;
    const py = doc.y;
    const party = (x, title, lines) => {
      doc.font('Helvetica-Bold').fontSize(8).fillColor(muted).text(title, x, py, { width: colW });
      doc.font('Helvetica').fontSize(9).fillColor(ink).text(lines.filter(Boolean).join('\n'), x, doc.y + 2, { width: colW });
      return doc.y;
    };
    const y1 = party(L, 'Installation address', [customer.name, job.address_line, job.town, job.postcode, customer.phone, customer.email]);
    const y2 = party(L + colW + 20, 'Engineer', [cert.engineer_name, cert.engineer_scheme && cert.engineer_number ? `${cert.engineer_scheme} no. ${cert.engineer_number}` : '', cert.engineer_categories]);
    doc.y = Math.max(y1, y2) + 14;

    // Sections
    const sectionTitle = (title) => {
      ensure(40);
      const y = doc.y;
      doc.rect(L, y, R - L, 18).fill('#e9ecea');
      doc.fillColor(ink).font('Helvetica-Bold').fontSize(10).text(title, L + 6, y + 4, { width: R - L - 12 });
      doc.y = y + 24;
    };
    const kvGrid = (fields, values) => {
      const filled = fields.filter(([k]) => values[k] !== undefined && String(values[k]).trim() !== '');
      const cw = (R - L - 16) / 2;
      for (let i = 0; i < filled.length; i += 2) {
        const pair = filled.slice(i, i + 2);
        const heights = pair.map(([k, lbl]) => doc.font('Helvetica').fontSize(8.5).heightOfString(String(values[k]), { width: cw * 0.5 }));
        const h = Math.max(12, ...heights);
        ensure(h + 4);
        const y = doc.y;
        pair.forEach(([k, lbl], j) => {
          const x = L + j * (cw + 16);
          doc.font('Helvetica').fontSize(8).fillColor(muted).text(lbl, x, y, { width: cw * 0.5 - 4 });
          doc.font('Helvetica-Bold').fontSize(8.5).fillColor(ink).text(String(values[k]), x + cw * 0.5, y, { width: cw * 0.5 });
        });
        doc.y = y + h + 4;
      }
      if (!filled.length) doc.font('Helvetica').fontSize(8.5).fillColor(muted).text('Nothing recorded.', L, doc.y).moveDown(0.5);
    };
    const table = (fields, rows) => {
      const widths = fields.map(([, , type]) => (type === 'textarea' ? 3 : type === 'text' ? 1.6 : 1));
      const sum = widths.reduce((a, b) => a + b, 0);
      const cols = widths.map((w) => ((R - L) * w) / sum);
      const head = () => {
        const hh = Math.max(...fields.map(([, lbl], i) => doc.font('Helvetica-Bold').fontSize(7).heightOfString(lbl, { width: cols[i] - 4 }))) + 6;
        ensure(hh + 14);
        const y = doc.y;
        doc.rect(L, y, R - L, hh).fill('#f3f5f4');
        let x = L;
        fields.forEach(([, lbl], i) => { doc.fillColor(ink).font('Helvetica-Bold').fontSize(7).text(lbl, x + 2, y + 3, { width: cols[i] - 4 }); x += cols[i]; });
        doc.y = y + hh + 2;
      };
      head();
      for (const r of rows) {
        const h = Math.max(11, ...fields.map(([k], i) => doc.font('Helvetica').fontSize(7.5).heightOfString(String(r[k] ?? ''), { width: cols[i] - 4 }))) + 4;
        if (doc.y + h > doc.page.height - 60) { doc.addPage(); doc.y = 50; head(); }
        const y = doc.y;
        let x = L;
        fields.forEach(([k], i) => {
          const v = String(r[k] ?? '');
          const red = v === 'Fail' || v === 'C1' || v === 'C2' || v === 'FI';
          doc.fillColor(red ? '#8a2418' : ink).font(red ? 'Helvetica-Bold' : 'Helvetica').fontSize(7.5).text(v, x + 2, y + 2, { width: cols[i] - 4 });
          x += cols[i];
        });
        doc.y = y + h;
        doc.moveTo(L, doc.y).lineTo(R, doc.y).lineWidth(0.4).strokeColor(line).stroke();
      }
      if (!rows.length) doc.font('Helvetica').fontSize(8.5).fillColor(muted).text('None recorded.', L, doc.y + 2);
      doc.y += 6;
    };

    for (const sec of t.sections) {
      sectionTitle(sec.title);
      if (!sec.group) { kvGrid(sec.fields, d); continue; }
      const items = d[sec.group] || [];
      if (sec.table) table(sec.fields, items);
      else if (!items.length) doc.font('Helvetica').fontSize(8.5).fillColor(muted).text('None recorded.', L, doc.y).moveDown(0.5);
      else items.forEach((item, i) => {
        ensure(30);
        doc.font('Helvetica-Bold').fontSize(9).fillColor(ink).text(`${sec.itemLabel} ${i + 1}${item.location ? `: ${item.location}` : ''}`, L, doc.y);
        doc.moveDown(0.2);
        kvGrid(sec.fields, item);
        doc.moveDown(0.3);
      });
      if (sec.group === 'observations' && t.codesNote) {
        doc.font('Helvetica').fontSize(7).fillColor(muted).text(t.codesNote, L, doc.y, { width: R - L });
        doc.moveDown(0.5);
      }
    }

    // Declaration
    ensure(70);
    sectionTitle('Declaration');
    doc.font('Helvetica').fontSize(8.5).fillColor(ink).text(
      `I confirm the inspection and tests recorded above were carried out by me, and the results are a true record at the time of the visit.`,
      L, doc.y, { width: R - L });
    doc.moveDown(0.6);
    doc.font('Helvetica').fontSize(8).fillColor(muted).text('Signed (typed)', L, doc.y, { continued: true }).fillColor(ink).font('Helvetica-Bold').text(`   ${cert.declaration_name || ''}`);
    doc.font('Helvetica').fontSize(8).fillColor(muted).text('Date', L, doc.y + 2, { continued: true }).fillColor(ink).font('Helvetica-Bold').text(`   ${fmtDate(cert.issued_at)}`);
    if (cert.status === 'void') {
      doc.moveDown(0.6).font('Helvetica-Bold').fontSize(12).fillColor('#8a2418').text(`CANCELLED: ${cert.void_reason || ''}`, L, doc.y, { width: R - L });
    }

    const range = doc.bufferedPageRange();
    for (let i = 0; i < range.count; i++) {
      doc.switchToPage(range.start + i);
      const bottom = doc.page.margins.bottom;
      doc.page.margins.bottom = 0;
      doc.font('Helvetica').fontSize(7.5).fillColor(muted)
        .text(`${s.business_name}  |  ${t.name} ${number}  |  Page ${i + 1} of ${range.count}`, L, doc.page.height - 28, { width: R - L, align: 'center' });
      if (cert.status === 'draft') {
        doc.save().rotate(-35, { origin: [W / 2, doc.page.height / 2] }).font('Helvetica-Bold').fontSize(90).fillColor('#e9ecea', 0.6)
          .text('DRAFT', 0, doc.page.height / 2 - 50, { width: W, align: 'center' }).restore();
      }
      doc.page.margins.bottom = bottom;
    }
    doc.end();
  });
}

module.exports = { buildCertificatePdf };
HANDYTRIO_EOF

cat > src/routes/settings.js <<'HANDYTRIO_EOF'
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const privacyDefault = require('../privacy-default');
const multer = require('multer');
const { loadBrand, HEX } = require('../brand');

const logoUpload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 2 * 1024 * 1024, files: 1 } });

const router = express.Router();

// One list drives both the form and the save, so adding a setting is one line here plus a column in schema.sql.
const GROUPS = [
  ['Business', [
    ['business_name', 'Business name (shown everywhere: website, emails, quotes, invoices, certificates)', 'text'],
    ['brand_primary', 'Main brand colour (header, PDF headers)', 'color'],
    ['brand_accent', 'Highlight colour (buttons, stripes)', 'color'],
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
      : type === 'color'
      ? `<label class="colour">${esc(lbl)}<span><input type="color" name="${key}" value="${esc(s[key])}"> <code>${esc(s[key])}</code></span></label>`
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
  const logoPanel = `<section class="panel branding" id="branding">
    <h2>Logo</h2>
    ${s.logo ? `<p><img class="logoprev" src="/brand/logo?v=${s.logo_updated_at ? new Date(s.logo_updated_at).getTime() : 0}" alt="Current logo"></p>` : '<p class="muted">No logo yet, so the business name is shown on its own.</p>'}
    <form method="post" action="/admin/settings/logo" enctype="multipart/form-data" class="inline-form">
      <input type="file" name="logo" accept="image/png,image/jpeg" required>
      <button class="small">${s.logo ? 'Replace logo' : 'Upload logo'}</button>
    </form>
    ${s.logo ? '<form method="post" action="/admin/settings/logo/remove" class="inline"><button class="small danger">Remove logo</button></form>' : ''}
    <p class="hint">PNG or JPEG, under 2 MB. A wide logo on a transparent background works best. It appears in the website header, as the browser icon, and on quotes, invoices and certificates.</p>
  </section>`;
  res.send(page({ title: 'Rates & settings', user: req.user, notice: req.query.saved ? 'Settings saved.' : null, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body: logoPanel + form(s) }));
}));

router.post('/admin/settings', requireRole('admin'), wrap(async (req, res) => {
  const values = [];
  for (const [key, lbl, type] of FIELDS) {
    const raw = req.body[key];
    if (type === 'bool') values.push(raw === 'on');
    else if (type === 'color') values.push(HEX.test(String(raw || '')) ? String(raw).toLowerCase() : (key === 'brand_accent' ? '#f2c300' : '#24414f'));
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
  await loadBrand();
  res.redirect('/admin/settings?saved=1');
}));

// ---------- Logo ----------
router.get('/brand/logo', wrap(async (req, res) => {
  const r = (await query('SELECT logo, logo_mime FROM settings WHERE id = 1')).rows[0];
  if (!r || !r.logo) return res.sendStatus(404);
  res.set('Cache-Control', 'public, max-age=31536000, immutable');
  res.type(r.logo_mime);
  res.send(r.logo);
}));

router.post('/admin/settings/logo', requireRole('admin'), (req, res, next) => {
  logoUpload.single('logo')(req, res, async (err) => {
    try {
      if (err) return res.redirect('/admin/settings?error=' + encodeURIComponent(err.code === 'LIMIT_FILE_SIZE' ? 'The logo must be under 2 MB.' : 'The logo couldn’t be uploaded.') + '#branding');
      const f = req.file;
      if (!f || !['image/png', 'image/jpeg'].includes(f.mimetype)) {
        return res.redirect('/admin/settings?error=' + encodeURIComponent('Upload the logo as a PNG or JPEG image.') + '#branding');
      }
      await query('UPDATE settings SET logo = $1, logo_mime = $2, logo_updated_at = now() WHERE id = 1', [f.buffer, f.mimetype]);
      await loadBrand();
      res.redirect('/admin/settings?saved=1#branding');
    } catch (e) {
      next(e);
    }
  });
});

router.post('/admin/settings/logo/remove', requireRole('admin'), wrap(async (req, res) => {
  await query('UPDATE settings SET logo = NULL, logo_mime = NULL, logo_updated_at = now() WHERE id = 1');
  await loadBrand();
  res.redirect('/admin/settings?saved=1#branding');
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
     WHERE u.active AND u.role IN ('builder','admin') AND q.expires >= current_date GROUP BY u.id, u.name ORDER BY u.name`)).rows
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
  const builders = (await query("SELECT id, name, postcode FROM users WHERE role = 'builder' AND active ORDER BY id")).rows;
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
  const builders = isAdmin ? (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows : [];
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
    builder = (await query("SELECT id, name FROM users WHERE id = $1 AND role = 'builder' AND active", [Number(req.body.builder_id) || 0])).rows[0];
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
    const builders = (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows;
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
  const u = /^[a-f0-9]{48}$/.test(token) ? (await query("SELECT id, role, name FROM users WHERE calendar_token = $1 AND active AND role IN ('admin', 'builder')", [token])).rows[0] : null;
  if (!u) return res.sendStatus(404);
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  const today = ukDate(new Date());
  const events = await eventsBetween(addDays(today, -30), addDays(today, 180), u.role === 'admin' ? null : u.id);
  const base = baseUrlOf(req);
  const names = Object.fromEntries((await query("SELECT id, name FROM users WHERE role = 'builder'")).rows.map((b) => [b.id, b.name]));
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

/* Availability */
.avmonth { display: grid; gap: .25rem; margin-bottom: 1rem; }
.avrow { display: grid; grid-template-columns: 110px 140px 1fr 1fr; gap: .5rem; align-items: center; padding: .3rem .5rem; border-radius: 4px; background: var(--surface); border: 1px solid var(--line); }
.avrow select, .avrow input { margin: 0; padding: .35rem .5rem; }
.avrow.weekend { background: var(--bg); }
.avrow.off { border-left: 4px solid var(--muted); }
.avrow.hours { border-left: 4px solid var(--slate); }
.avrow.holiday { border-left: 4px solid var(--hivis); grid-template-columns: 110px auto 1fr; }
.avrow.past { opacity: .5; }
.avday { font-weight: 600; font-size: .9rem; }
.dows { display: flex; flex-wrap: wrap; gap: .25rem 1rem; margin-bottom: .75rem; }
.dows label { margin: 0; }
.avchip { display: block; font-size: .75rem; padding: .15rem .4rem; border-radius: 3px; margin-bottom: .3rem; background: var(--bg); color: var(--muted); }
.avchip.holiday { background: var(--hivis); color: var(--hivis-ink); }
.avchip.off { background: var(--line); color: var(--ink); }
.rateform { display: flex; align-items: center; gap: .25rem; }
.rateform input { width: 80px; margin: 0; padding: .3rem .4rem; }
@media (max-width: 560px) {
  .avrow { grid-template-columns: 1fr 1fr; }
  .avrow .avday { grid-column: 1 / -1; }
}

/* Branding */
.top { color: var(--slate-ink, #fff); }
.top nav a, .top .linkish { color: var(--slate-ink, #fff); }
.brand { display: inline-flex; align-items: center; gap: .6rem; color: var(--slate-ink, #fff); }
.brand img { height: 40px; width: auto; max-width: 160px; object-fit: contain; }
.logoprev { max-height: 80px; max-width: 100%; background: var(--slate); padding: .5rem; border-radius: 4px; }
.branding { margin-bottom: 1rem; }
.branding h2 { margin-top: 0; }
label.colour span { display: flex; align-items: center; gap: .5rem; margin-top: .3rem; }
label.colour input[type="color"] { width: 3rem; height: 2.2rem; padding: .1rem; margin: 0; }
HANDYTRIO_EOF

echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "Rebrand installed. The app restarts by itself; otherwise run: npm run dev"
