#!/usr/bin/env bash
# New look: light greys, white and light blue, with a sidebar menu and card dashboards. Run with: bash newlook.sh
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

-- New look: light greys and white with a light blue brand colour
ALTER TABLE settings ALTER COLUMN brand_primary SET DEFAULT '#2e6fb7';
ALTER TABLE settings ALTER COLUMN brand_accent SET DEFAULT '#dbe8f5';
UPDATE settings SET brand_primary = '#2e6fb7' WHERE brand_primary = '#24414f';
UPDATE settings SET brand_accent = '#dbe8f5' WHERE brand_accent = '#f2c300';
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
  const primary = HEX.test(s.brand_primary || '') ? s.brand_primary : '#2e6fb7';
  const accent = HEX.test(s.brand_accent || '') ? s.brand_accent : '#dbe8f5';
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

const brand = () => cache || { name: 'SWAT Maintenance', primary: '#2e6fb7', accent: '#dbe8f5', primaryInk: '#ffffff', accentInk: '#1d2529', hasLogo: false, logoVersion: 0 };

module.exports = { loadBrand, brand, HEX };
HANDYTRIO_EOF

cat > src/layout.js <<'HANDYTRIO_EOF'
// The page shell: a sidebar on desktop, a tab bar on phones, and a simple centred card when logged out.
const { AsyncLocalStorage } = require('async_hooks');
const { brand } = require('./brand');

// Remembers which page is being shown, so the menu can highlight it.
const requestContext = new AsyncLocalStorage();

const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin', manager: 'Manager' };

// Simple line icons (24px grid, drawn with strokes).
const ICON_PATHS = {
  home: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V20h14V9.5"/><path d="M10 20v-6h4v6"/>',
  plus: '<circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/>',
  jobs: '<rect x="3" y="7" width="18" height="13" rx="2"/><path d="M9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2"/><path d="M3 12h18"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  cert: '<path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5"/><path d="m10 14 2 2 4-4"/>',
  badge: '<circle cx="12" cy="9" r="5"/><path d="m9 13-2 8 5-3 5 3-2-8"/>',
  chart: '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
  tag: '<path d="M3 12V4h8l10 10-8 8z"/><circle cx="7.5" cy="7.5" r="1.5"/>',
  people: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6 6 0 0 1 3.5 6"/>',
  mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
  backup: '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v6c0 1.7 3.6 3 8 3s8-1.3 8-3V6"/><path d="M4 12v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  more: '<circle cx="5" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="19" cy="12" r="1.5"/>',
  logout: '<path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3"/><path d="M10 17l-5-5 5-5M5 12h11"/>',
  shield: '<path d="M12 3 4 6v6c0 4.5 3.4 8.3 8 9 4.6-.7 8-4.5 8-9V6z"/>',
};
const icon = (name) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON_PATHS[name] || ''}</svg>`;

// Menu items for each kind of person: [section, href, label, icon, showOnPhoneTabBar]
function navItems(user) {
  if (!user) return [];
  if (user.role === 'customer') {
    return [
      ['', '/dashboard', 'Dashboard', 'home', true],
      ['', '/jobs/new', 'Request a job', 'plus', true],
      ['', '/account', 'My account', 'user', true],
      ['', '/privacy', 'Privacy', 'shield', false],
    ];
  }
  if (user.role === 'builder') {
    return [
      ['', '/dashboard', 'Dashboard', 'home', true],
      ['', '/jobs', 'My jobs', 'jobs', true],
      ['', '/calendar', 'My diary', 'calendar', true],
      ['', '/availability', 'My availability', 'clock', false],
      ['', '/certify', 'Certify', 'badge', false],
      ['', '/account', 'My account', 'user', false],
    ];
  }
  const items = [
    ['', '/dashboard', 'Dashboard', 'home', true],
    ['', '/jobs', 'All jobs', 'jobs', true],
    ['', '/calendar', 'Calendar', 'calendar', true],
    ['', '/admin/certificates', 'Certificates', 'cert', false],
    ['', '/admin/reports', 'Reports', 'chart', true],
  ];
  if (user.isManager) items.push(['My work', '/availability', 'My availability', 'clock', false], ['My work', '/certify', 'Certify', 'badge', false]);
  items.push(
    ['Business', '/admin/templates', 'Pricing', 'tag', false],
    ['Business', '/admin/users', 'People', 'people', false],
    ['Business', '/admin/emails', 'Messages', 'mail', false],
    ['Business', '/admin/backups', 'Backups', 'backup', false],
    ['Business', '/admin/settings', 'Settings', 'settings', false],
    ['Business', '/account', 'My account', 'user', false],
  );
  return items;
}

// The menu item that best matches the current address.
function activeHref(items, path) {
  let best = '';
  for (const [, href] of items) {
    const match = href === '/dashboard' ? path === '/dashboard' || path === '/' : path === href || path.startsWith(href + '/');
    if (match && href.length > best.length) best = href;
  }
  // Pricing covers all its tabs; Messages covers reminders too.
  if (!best && /^\/admin\/(price-list|suppliers|access-options)/.test(path)) best = '/admin/templates';
  if (!best && path.startsWith('/admin/reminders')) best = '/admin/emails';
  return best;
}

const initials = (name) => String(name || '?').trim().split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase();

function brandBlock(b) {
  const logo = b.hasLogo ? `/brand/logo?v=${b.logoVersion}` : '';
  return `<a class="brand" href="/">${logo ? `<img src="${logo}" alt="">` : `<span class="mark">${esc(initials(b.name))}</span>`}<span>${esc(b.name)}</span></a>`;
}

function sidebar(user, items, current) {
  let lastSection = '';
  const links = items.map(([section, href, label, ic]) => {
    const head = section && section !== lastSection ? `<div class="navsection">${esc(section)}</div>` : '';
    lastSection = section || lastSection;
    return `${head}<a href="${href}" ${href === current ? 'aria-current="page"' : ''}>${icon(ic)}<span>${esc(label)}</span></a>`;
  }).join('');
  return `<aside class="side">
    ${brandBlock(brand())}
    <nav class="navlist" aria-label="Main">${links}</nav>
    <div class="sidefoot">
      <a class="usercard" href="/account"><span class="avatar">${esc(initials(user.name))}</span>
        <span class="who2"><strong>${esc(user.name)}</strong><span>${esc(user.email || ROLE_LABELS[user.realRole || user.role])}</span></span></a>
      <form method="post" action="/logout" class="navlist"><button>${icon('logout')}<span>Log out</span></button></form>
    </div>
  </aside>`;
}

function tabbar(items, current) {
  const tabs = items.filter((i) => i[4]).slice(0, 4);
  const onMore = current && !tabs.some((t) => t[1] === current);
  return `<nav class="tabbar" aria-label="Main">
    ${tabs.map(([, href, label, ic]) => `<a href="${href}" ${href === current ? 'aria-current="page"' : ''}>${icon(ic)}<span>${esc(label.replace('Request a job', 'Request'))}</span></a>`).join('')}
    <a href="/menu" ${onMore || current === '/menu' ? 'aria-current="page"' : ''}>${icon('more')}<span>More</span></a>
  </nav>`;
}

function head(title, b) {
  const logo = b.hasLogo ? `/brand/logo?v=${b.logoVersion}` : '';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title)} | ${esc(b.name)}</title>${logo ? `\n<link rel="icon" href="${logo}">` : ''}
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap">
<link rel="stylesheet" href="/style.css">
<style>:root { --brand: ${b.primary}; --brand-ink: ${b.primaryInk}; }</style>
<script src="/js/photos.js" defer></script>
</head>`;
}

function page({ title, subtitle, actions, user, body, notice, error }) {
  const b = brand();
  const flash = `${notice ? `<div class="notice" role="status">${esc(notice)}</div>` : ''}${error ? `<div class="error" role="alert">${esc(error)}</div>` : ''}`;

  if (!user) {
    return `${head(title, b)}
<body>
<div class="solo">
  ${brandBlock(b)}
  <main class="card ${/privacy/i.test(title) ? 'wide' : ''}">
    <h1>${esc(title)}</h1>
    ${subtitle ? `<p class="muted">${esc(subtitle)}</p>` : ''}
    ${flash}
    ${body}
  </main>
  <footer class="foot"><a href="/privacy">Privacy notice</a></footer>
</div>
</body>
</html>`;
  }

  const ctx = requestContext.getStore();
  const items = navItems(user);
  const current = activeHref(items, (ctx && ctx.path) || '');
  return `${head(title, b)}
<body>
<div class="app">
  ${sidebar(user, items, current)}
  <div class="main">
    <header class="pagehead">
      <div><h1>${esc(title)}</h1>${subtitle ? `<p>${esc(subtitle)}</p>` : ''}</div>
      ${actions || ''}
    </header>
    <main class="content">
      ${flash}
      ${body}
    </main>
    <footer class="foot">${esc(b.name)} · <a href="/privacy">Privacy notice</a></footer>
  </div>
</div>
${tabbar(items, current)}
</body>
</html>`;
}

module.exports = { esc, page, ROLE_LABELS, requestContext, navItems, icon, initials };
HANDYTRIO_EOF

cat > src/server.js <<'HANDYTRIO_EOF'
require('dotenv').config();
const path = require('path');
const express = require('express');
const session = require('express-session');
const PgSession = require('connect-pg-simple')(session);
const helmet = require('helmet');
const { pool, query } = require('./db');
const { page, requestContext } = require('./layout');
const { wrap } = require('./auth');

if (!process.env.SESSION_SECRET || !process.env.DATABASE_URL) {
  console.error('Missing SESSION_SECRET or DATABASE_URL in .env');
  process.exit(1);
}

const app = express();
app.set('trust proxy', 1);
app.disable('x-powered-by');

app.use(helmet());
// Lets the menu know which page is showing.
app.use((req, res, next) => requestContext.run({ path: req.path }, next));
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

cat > src/routes/dashboard.js <<'HANDYTRIO_EOF'
const express = require('express');
const { query } = require('../db');
const { page, esc, icon } = require('../layout');
const { wrap, requireLogin } = require('../auth');
const { STATUSES, CLOSED, label } = require('../statuses');
const { ref, day, ukDate, addDays, TZ } = require('../format');
const { money } = require('../estimate');

const router = express.Router();
const firstName = (n) => String(n || '').trim().split(/\s+/)[0] || 'there';

// The job list as cards: first photo (or a soft placeholder), stage, title and one useful line.
function jobCards(jobs, { who = 'staff' } = {}) {
  if (!jobs.length) return '';
  return `<div class="cards">${jobs.map((j) => {
    const when = j.scheduled_start ? `Booked ${day(j.scheduled_start)}`
      : j.inspection_at && j.status === 'inspection_booked' ? `Visit ${new Date(j.inspection_at).toLocaleDateString('en-GB', { timeZone: TZ, day: 'numeric', month: 'short' })}`
      : `Requested ${day(j.created_at)}`;
    const extra = who === 'staff' ? [j.customer_name, j.postcode].filter(Boolean).join(', ') : j.quote_total ? `Quote ${money(j.quote_total)}` : '';
    return `<a class="jobcard" href="/jobs/${j.id}">
      <div class="pic">${j.photo_id ? `<img src="/jobs/${j.id}/photos/${j.photo_id}" alt="" loading="lazy">` : icon('jobs')}
        <span class="tag ${j.urgent && !CLOSED.includes(j.status) ? 'urgent' : ''}">${esc(label(j.status))}</span></div>
      <div class="txt"><strong>${esc(j.title)}</strong><span>${esc(when)}${extra ? ` · ${esc(extra)}` : ''}</span></div>
    </a>`;
  }).join('')}</div>`;
}

const CARD_SELECT = `SELECT j.*, c.name AS customer_name, b.name AS builder_name,
    (SELECT p.id FROM job_photos p WHERE p.job_id = j.id ORDER BY p.id LIMIT 1) AS photo_id,
    (SELECT q.total FROM quotes q WHERE q.job_id = j.id AND q.status IN ('sent', 'accepted') ORDER BY q.id DESC LIMIT 1) AS quote_total
  FROM jobs j JOIN users c ON c.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id`;

function weekList(events, today) {
  const { eventChip } = require('./calendar');
  return events.length
    ? `<div class="soon">${events.map((e) => `<div><span class="muted">${e.start === today ? 'Today' : day(e.start)}</span>${eventChip(e)}</div>`).join('')}</div>`
    : '';
}

router.get('/dashboard', requireLogin, wrap(async (req, res) => {
  const user = req.user;
  const today = ukDate(new Date());
  const { eventsBetween } = require('./calendar');

  // ---------------- Customers ----------------
  if (user.role === 'customer') {
    const jobs = (await query(`${CARD_SELECT} WHERE j.customer_id = $1 ORDER BY j.updated_at DESC`, [user.id])).rows;
    const active = jobs.filter((j) => !CLOSED.includes(j.status));
    const past = jobs.filter((j) => CLOSED.includes(j.status));
    const invoices = (await query(
      `SELECT i.*, j.title, i.amount_due - coalesce((SELECT sum(amount) FROM payments p WHERE p.invoice_id = i.id), 0) AS left_to_pay
       FROM invoices i JOIN jobs j ON j.id = i.job_id WHERE j.customer_id = $1 AND i.status = 'issued' ORDER BY i.created_at`, [user.id])).rows
      .filter((i) => Number(i.left_to_pay) > 0.004);
    const certs = (await query(
      `SELECT c.id, c.job_id, c.type, c.issued_at, c.next_due FROM certificates c JOIN jobs j ON j.id = c.job_id
       WHERE j.customer_id = $1 AND c.status = 'issued' AND NOT c.private ORDER BY c.issued_at DESC LIMIT 10`, [user.id])).rows;
    const { TYPES } = require('../certtypes');

    const body = `
      <h2>Active jobs</h2>
      ${jobCards(active, { who: 'customer' }) || `<div class="panel callout"><p><strong>No jobs on the go.</strong> Tell us what you need, add a few photos, and we’ll get back to you with a price.</p><a class="button primary" href="/jobs/new">Request a job</a></div>`}

      ${invoices.length ? `<h2>Open invoices</h2>
      <div class="scroll"><table>
        <thead><tr><th>Invoice</th><th>Job</th><th class="num">Left to pay</th><th>Invoiced</th><th>Due</th><th></th></tr></thead>
        <tbody>${invoices.map((i) => `<tr>
          <td>INV-${String(i.id).padStart(5, '0')}</td><td>${esc(i.title)}</td><td class="num">${money(i.left_to_pay)}</td>
          <td>${day(i.created_at)}</td><td>${i.due_date ? day(i.due_date) : 'On receipt'}</td>
          <td><a href="/jobs/${i.job_id}#invoices">View and pay</a></td></tr>`).join('')}</tbody></table></div>` : ''}

      ${certs.length ? `<h2>Your certificates</h2>
      <div class="scroll"><table>
        <thead><tr><th>Certificate</th><th>Issued</th><th>Next due</th><th></th></tr></thead>
        <tbody>${certs.map((c) => `<tr><td>${esc(TYPES[c.type] ? TYPES[c.type].name : c.type)}</td><td>${day(c.issued_at)}</td><td>${c.next_due ? day(c.next_due) : ''}</td>
          <td><a href="/jobs/${c.job_id}/certs/${c.id}/pdf" target="_blank" rel="noopener">PDF</a></td></tr>`).join('')}</tbody></table></div>` : ''}

      ${past.length ? `<h2>Past jobs</h2>
      <div class="scroll"><table>
        <thead><tr><th>Job</th><th>Stage</th><th>Last update</th></tr></thead>
        <tbody>${past.map((j) => `<tr><td><a href="/jobs/${j.id}">${esc(j.title)}</a></td><td><span class="tag ${j.status === 'paid' ? 'ok' : ''}">${esc(label(j.status))}</span></td><td>${day(j.updated_at)}</td></tr>`).join('')}</tbody></table></div>` : ''}`;
    return res.send(page({
      title: `Welcome back, ${firstName(user.name)}!`, subtitle: 'This is your private portal.', user, body,
      actions: '<a class="button primary" href="/jobs/new">Request a job</a>',
    }));
  }

  // ---------------- Builders ----------------
  if (user.role === 'builder') {
    const jobs = (await query(
      `${CARD_SELECT} WHERE (j.assigned_builder_id = $1 OR j.id IN (SELECT job_id FROM job_team WHERE user_id = $1)) AND j.status <> ALL($2)
       ORDER BY coalesce(j.scheduled_start, j.preferred_start) NULLS LAST, j.created_at`, [user.id, CLOSED])).rows;
    const clocked = (await query(
      `SELECT t.job_id, t.started_at, j.title FROM job_time_entries t JOIN jobs j ON j.id = t.job_id
       WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
    const myQuals = (await query(
      `SELECT kind, expires FROM staff_qualifications WHERE user_id = $1 AND expires <= current_date + 30 ORDER BY expires`, [user.id])).rows;
    const qualWarn = myQuals.map((q) => `<div class="error">Your ${esc(q.kind === 'gas' ? 'Gas Safe' : q.kind === 'pat' ? 'PAT' : 'electrical scheme')} qualification ${new Date(q.expires) < new Date(new Date().toDateString()) ? 'has expired' : 'expires'} on ${day(q.expires)}. Send the office your renewal.</div>`).join('');
    const soon = (await eventsBetween(today, addDays(today, 6), user.id)).sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));

    const body = `${qualWarn}
      ${clocked ? `<div class="notice">You’re clocked on to <a href="/jobs/${clocked.job_id}#time">${esc(clocked.title)}</a> since ${new Date(clocked.started_at).toLocaleTimeString('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit' })}.</div>` : ''}
      <h2>This week</h2>
      ${weekList(soon, today) || '<p class="empty">Nothing booked in the next 7 days.</p>'}
      <h2>Your jobs</h2>
      ${jobCards(jobs) || '<p class="empty">No jobs assigned to you yet. The office will add them here.</p>'}
      <p><a class="button" href="/jobs?show=finished">See my past jobs</a></p>`;
    return res.send(page({ title: `Welcome back, ${firstName(user.name)}!`, subtitle: 'Here’s your week.', user, body, actions: '<a class="button" href="/calendar">Open my diary</a>' }));
  }

  // ---------------- Office (admins and managers) ----------------
  const counts = await query('SELECT status, count(*)::int AS n FROM jobs GROUP BY status');
  const byStatus = Object.fromEntries(counts.rows.map((r) => [r.status, r.n]));
  const openCount = STATUSES.filter(([k]) => !CLOSED.includes(k)).reduce((a, [k]) => a + (byStatus[k] || 0), 0);
  const pipeline = STATUSES.filter(([k]) => !CLOSED.includes(k))
    .map(([k, l]) => `<li class="${byStatus[k] ? 'has' : ''}"><span class="n">${byStatus[k] || 0}</span><span>${esc(l)}</span></li>`).join('');
  const recent = (await query(`${CARD_SELECT} WHERE j.status <> ALL($1) ORDER BY j.urgent DESC, j.updated_at DESC LIMIT 8`, [CLOSED])).rows;
  const s = (await query(
    `SELECT base_postcode, (SELECT count(*)::int FROM users WHERE role IN ('builder', 'manager') AND active AND coalesce(postcode, '') <> '') AS builder_postcodes
     FROM settings WHERE id = 1`)).rows[0];
  const owed = (await query(
    `SELECT coalesce(sum(i.amount_due - coalesce((SELECT sum(amount) FROM payments p WHERE p.invoice_id = i.id), 0)), 0) AS n
     FROM invoices i WHERE i.status = 'issued'`)).rows[0].n;

  const ACTIONS = [
    ['request', 'Check the price guide'],
    ['inspection_required', 'Book an inspection'],
    ['inspected', 'Send the quote'],
    ['accepted', 'Request the deposit'],
    ['deposit_paid', 'Order parts and book the job in'],
    ['parts_ordered', 'Book the job in'],
    ['complete', 'Send the final invoice'],
  ];
  const actionRows = (await query(`SELECT id, title, status, urgent FROM jobs WHERE status = ANY($1) ORDER BY urgent DESC, updated_at`, [ACTIONS.map((a) => a[0])])).rows;
  const overdue = (await query(
    `SELECT i.id, i.job_id, j.title FROM invoices i JOIN jobs j ON j.id = i.job_id WHERE i.status = 'issued' AND i.due_date < current_date ORDER BY i.due_date`)).rows;
  const quals = (await query(
    `SELECT q.kind, q.expires, u.id AS user_id, u.name FROM staff_qualifications q JOIN users u ON u.id = q.user_id
     WHERE u.active AND q.expires <= current_date + 30 ORDER BY q.expires`)).rows;
  const certsDue = (await query(`SELECT count(*)::int AS n FROM certificates WHERE status = 'issued' AND NOT private AND next_due <= current_date + 30`)).rows[0].n;
  const lastBackup = (await query('SELECT max(created_at) AS t FROM backup_log')).rows[0].t;
  const backupDue = !lastBackup || Date.now() - new Date(lastBackup) > 7 * 86400000;
  const todoItems = [
    ...actionRows.map((j) => `<li><a href="/jobs/${j.id}"><strong>${esc(ACTIONS.find((a) => a[0] === j.status)[1])}</strong> · ${esc(j.title)} <span class="muted">${ref(j.id)}</span></a>${j.urgent ? ' <span class="tag urgent">Urgent</span>' : ''}</li>`),
    ...overdue.map((i) => `<li><a href="/jobs/${i.job_id}#invoices"><strong>Chase overdue invoice</strong> · ${esc(i.title)} <span class="muted">${ref(i.job_id)}</span></a></li>`),
    ...quals.map((q) => `<li><a href="/admin/users/${q.user_id}"><strong>${new Date(q.expires) < new Date(new Date().toDateString()) ? 'Qualification expired' : 'Qualification expiring'}</strong> · ${esc(q.name)}, ${esc(q.kind === 'gas' ? 'Gas Safe' : q.kind === 'pat' ? 'PAT' : 'electrical scheme')}, ${day(q.expires)}</a></li>`),
    ...(certsDue ? [`<li><a href="/admin/certificates?due=1"><strong>Certificates due for renewal</strong> · ${certsDue} in the next 30 days or overdue</a></li>`] : []),
    ...(backupDue ? [`<li><a href="/admin/backups"><strong>Download a backup</strong> · ${lastBackup ? `last one was ${day(lastBackup)}` : 'you haven’t made one yet'}</a></li>`] : []),
  ];

  const todays = await eventsBetween(today, today);
  const { loadAvailability, dayStatus, statusLabel } = require('../availability');
  const staffRows = (await query("SELECT id, name FROM users WHERE role IN ('builder', 'manager') AND active ORDER BY name")).rows;
  const avToday = await loadAvailability(staffRows.map((b) => b.id), today, today);
  const notAny = staffRows.map((b) => ({ b, st: dayStatus(avToday, b.id, today) })).filter((x) => x.st.state !== 'any');
  const whoOff = notAny.length ? `<p class="muted">${notAny.map((x) => `${esc(x.b.name)}: ${esc(statusLabel(x.st))}`).join(' · ')}</p>` : '';

  let myWeek = '';
  if (user.isManager) {
    const mine = (await eventsBetween(today, addDays(today, 6), user.id)).sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));
    const clockedOn = (await query(
      `SELECT t.job_id, j.title FROM job_time_entries t JOIN jobs j ON j.id = t.job_id WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
    myWeek = `${clockedOn ? `<div class="notice">You’re clocked on to <a href="/jobs/${clockedOn.job_id}#time">${esc(clockedOn.title)}</a>.</div>` : ''}
      <h2>My jobs this week</h2>${weekList(mine, today) || '<p class="empty">Nothing booked for you in the next 7 days.</p>'}`;
  }

  const dateLine = new Date().toLocaleDateString('en-GB', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long' });
  const body = `
    ${!s.base_postcode && !s.builder_postcodes ? '<div class="error">Add your builders’ home postcodes on the <a href="/admin/users">People</a> page so travel costs can be worked out.</div>' : ''}
    <div class="stats">
      <a class="stat" href="#attention"><span class="muted">Needs your attention</span><strong>${todoItems.length}</strong></a>
      <a class="stat" href="/calendar"><span class="muted">Booked today</span><strong>${todays.length}</strong></a>
      <a class="stat" href="/jobs?show=open"><span class="muted">Open jobs</span><strong>${openCount}</strong></a>
      <a class="stat" href="/admin/reports"><span class="muted">Owed to you</span><strong>${money(owed)}</strong></a>
    </div>
    ${myWeek}
    <h2>Today</h2>${whoOff}
    ${todays.length ? `<div class="soon">${todays.map((e) => require('./calendar').eventChip(e)).join('')}</div>` : '<p class="empty">Nothing booked today.</p>'}
    <h2 id="attention">Needs your attention</h2>
    ${todoItems.length ? `<ul class="todo">${todoItems.join('')}</ul>` : '<p class="empty">Nothing waiting on you right now.</p>'}
    <h2>Active jobs</h2>
    ${jobCards(recent) || '<p class="empty">No open jobs. New customer requests will appear here.</p>'}
    <p class="buttons"><a class="button" href="/jobs?show=open">All open jobs</a><a class="button" href="/jobs?show=finished">Finished and closed</a></p>
    <h2>Job pipeline</h2>
    <ol class="pipeline">${pipeline}</ol>`;
  res.send(page({ title: `Welcome back, ${firstName(user.name)}!`, subtitle: dateLine, user, body, actions: '<a class="button" href="/calendar">Open the calendar</a>' }));
}));

module.exports = router;
HANDYTRIO_EOF

cat > src/routes/account.js <<'HANDYTRIO_EOF'
const express = require('express');
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const rateLimit = require('express-rate-limit');
const { query, pool } = require('../db');
const { page, esc, navItems, icon } = require('../layout');
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

// ---------- Menu (phones): every page the person can open ----------
router.get('/menu', requireLogin, (req, res) => {
  let last = '';
  const links = navItems(req.user).map(([section, href, label, ic]) => {
    const head = section && section !== last ? `<div class="navsection">${esc(section)}</div>` : '';
    last = section || last;
    return `${head}<a href="${href}">${icon(ic)}<span>${esc(label)}</span></a>`;
  }).join('');
  res.send(page({ title: 'Menu', user: req.user, body: `<nav class="menulist">${links}
    <div class="navsection">Account</div>
    <a href="/privacy">${icon('shield')}<span>Privacy notice</span></a>
    <form method="post" action="/logout"><button>${icon('logout')}<span>Log out</span></button></form></nav>` }));
});

// ---------- Privacy notice ----------
router.get('/privacy', wrap(async (req, res) => {
  const s = (await query('SELECT business_name, business_email, privacy_notice FROM settings WHERE id = 1')).rows[0];
  const text = s.privacy_notice || privacyDefault(s);
  res.send(page({ title: 'Privacy notice', user: req.user, body: `<div class="panel prose pre">${esc(text)}</div>` }));
}));

module.exports = router;
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
    ['brand_primary', 'Brand colour (buttons, links, highlights, PDF headers)', 'color'],
    ['brand_accent', 'Soft colour (the thin stripe under PDF headers)', 'color'],
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
    else if (type === 'color') values.push(HEX.test(String(raw || '')) ? String(raw).toLowerCase() : (key === 'brand_accent' ? '#dbe8f5' : '#2e6fb7'));
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

cat > public/style.css <<'HANDYTRIO_EOF'
/* ==========================================================================
   Design: light greys and white, with a hint of light blue.
   The brand colour (--brand) comes from Settings; everything else is neutral.
   ========================================================================== */
:root {
  --brand: #2e6fb7;                 /* replaced by the Settings colour */
  --brand-ink: #ffffff;
  --brand-soft: color-mix(in srgb, var(--brand) 9%, #ffffff);
  --brand-line: color-mix(in srgb, var(--brand) 28%, #ffffff);
  --bg: #eef3f8;                    /* page: very light blue-grey */
  --side: #f5f7fa;                  /* sidebar */
  --surface: #ffffff;
  --sunken: #f5f7fa;
  --line: #e3e8ee;
  --ink: #111827;
  --muted: #6b7280;
  --ok-bg: #e7f6ec; --ok-ink: #1e6b3a;
  --bad-bg: #fdecec; --bad-ink: #9b2c2c;
  --warn-bg: #fff4e0; --warn-ink: #8a5a00;
  --radius: 10px;
  --shadow: 0 1px 2px rgba(16, 24, 40, .05), 0 1px 3px rgba(16, 24, 40, .06);
  /* older names some pages still use */
  --slate: var(--brand); --hivis: var(--brand); --hivis-ink: var(--brand-ink);
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --brand-soft: color-mix(in srgb, var(--brand) 22%, #161b22);
    --brand-line: color-mix(in srgb, var(--brand) 45%, #161b22);
    --bg: #0f1318; --side: #13181e; --surface: #161b22; --sunken: #1c222b; --line: #2a313b;
    --ink: #e6eaf0; --muted: #9aa4b2;
    --ok-bg: #173523; --ok-ink: #a8e2bb; --bad-bg: #3d1d1d; --bad-ink: #f5b5b5; --warn-bg: #3a2c10; --warn-ink: #f3d08a;
    --shadow: none;
    color-scheme: dark;
  }
}

* { box-sizing: border-box; }
html, body { margin: 0; }
body { background: var(--bg); color: var(--ink); font: 15px/1.55 Inter, "Segoe UI", system-ui, -apple-system, sans-serif; -webkit-font-smoothing: antialiased; }
a { color: var(--brand); text-decoration: none; }
a:hover { text-decoration: underline; }
:focus-visible { outline: 2px solid var(--brand); outline-offset: 2px; border-radius: 4px; }
h1 { font-size: 1.75rem; line-height: 1.2; font-weight: 700; letter-spacing: -.01em; margin: 0; }
h2 { font-size: 1.2rem; font-weight: 650; margin: 2rem 0 .85rem; letter-spacing: -.005em; }
h3 { font-size: 1rem; font-weight: 600; margin: 1rem 0 .5rem; }
code { background: var(--sunken); padding: .05rem .35rem; border-radius: 4px; font-size: .88em; }
.muted { color: var(--muted); }
.small { font-size: .88rem; }
.empty { color: var(--muted); background: var(--surface); border: 1px dashed var(--line); border-radius: var(--radius); padding: 1rem 1.25rem; }
.hint { color: var(--muted); font-size: .88rem; margin: .25rem 0 .75rem; }
.lead { color: var(--muted); max-width: 70ch; }
.pre { white-space: pre-wrap; }
.prose { max-width: 75ch; line-height: 1.65; }

/* ---------- App shell ---------- */
.app { display: grid; grid-template-columns: 248px 1fr; min-height: 100vh; }
.side { position: sticky; top: 0; height: 100vh; background: var(--side); border-right: 1px solid var(--line); display: flex; flex-direction: column; padding: 1rem .75rem; }
.side .brand { display: flex; align-items: center; gap: .6rem; padding: .35rem .6rem 1.1rem; color: var(--ink); font-weight: 700; font-size: 1rem; }
.side .brand:hover { text-decoration: none; }
.side .brand img { height: 30px; width: auto; max-width: 150px; object-fit: contain; }
.side .brand .mark { width: 28px; height: 28px; border-radius: 8px; background: var(--brand); color: var(--brand-ink); display: grid; place-items: center; font-size: .8rem; font-weight: 800; flex: none; }
.navlist { display: flex; flex-direction: column; gap: 2px; overflow-y: auto; }
.navlist a, .navlist button { display: flex; align-items: center; gap: .65rem; padding: .5rem .65rem; border-radius: 8px; color: var(--ink); font: inherit; font-size: .93rem; background: none; border: 0; width: 100%; text-align: left; cursor: pointer; }
.navlist a:hover, .navlist button:hover { background: color-mix(in srgb, var(--ink) 5%, transparent); text-decoration: none; }
.navlist a[aria-current="page"] { background: var(--surface); box-shadow: var(--shadow); font-weight: 600; }
.navlist a[aria-current="page"] svg { color: var(--brand); }
.navlist svg, .tabbar svg { width: 18px; height: 18px; flex: none; color: var(--muted); }
.navsection { font-size: .72rem; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); padding: .9rem .65rem .3rem; }
.sidefoot { margin-top: auto; border-top: 1px solid var(--line); padding-top: .75rem; }
.usercard { display: flex; align-items: center; gap: .6rem; padding: .4rem .6rem; color: var(--ink); border-radius: 8px; }
.usercard:hover { background: color-mix(in srgb, var(--ink) 5%, transparent); text-decoration: none; }
.avatar { width: 34px; height: 34px; border-radius: 50%; background: var(--brand-soft); color: var(--brand); display: grid; place-items: center; font-weight: 700; font-size: .85rem; flex: none; border: 1px solid var(--brand-line); }
.usercard .who2 { display: flex; flex-direction: column; min-width: 0; }
.usercard .who2 strong { font-size: .9rem; font-weight: 600; }
.usercard .who2 span { font-size: .78rem; color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.main { min-width: 0; background: var(--surface); }
.pagehead { padding: 2rem 2.5rem 1.5rem; border-bottom: 1px solid var(--line); display: flex; flex-wrap: wrap; gap: 1rem; align-items: flex-end; justify-content: space-between; }
.pagehead p { margin: .35rem 0 0; color: var(--muted); }
.content { padding: 1.5rem 2.5rem 3rem; max-width: 1200px; }
.content > h2:first-child, .content > .notice:first-child + h2, .content > .error:first-child + h2 { margin-top: .5rem; }
.foot { padding: 1.5rem 2.5rem 2rem; color: var(--muted); font-size: .85rem; border-top: 1px solid var(--line); }

/* Mobile: tab bar along the bottom */
.tabbar { display: none; }
@media (max-width: 860px) {
  .app { grid-template-columns: 1fr; }
  .side { display: none; }
  .pagehead { padding: 1.4rem 1.1rem 1.1rem; }
  .content { padding: 1.1rem 1.1rem 6rem; }
  .foot { padding: 1rem 1.1rem 6.5rem; }
  .tabbar { display: grid; grid-template-columns: repeat(5, 1fr); position: fixed; inset: auto 0 0 0; background: color-mix(in srgb, var(--surface) 92%, transparent); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); border-top: 1px solid var(--line); padding: .35rem .25rem calc(.35rem + env(safe-area-inset-bottom)); z-index: 20; }
  .tabbar a { display: flex; flex-direction: column; align-items: center; gap: .15rem; padding: .35rem .2rem; border-radius: 10px; color: var(--muted); font-size: .7rem; }
  .tabbar a:hover { text-decoration: none; }
  .tabbar a[aria-current="page"] { color: var(--ink); background: var(--sunken); }
  .tabbar a[aria-current="page"] svg { color: var(--brand); }
  h1 { font-size: 1.45rem; }
}

/* Logged-out pages: one centred column */
.solo { min-height: 100vh; display: flex; flex-direction: column; align-items: center; padding: 3rem 1rem; }
.solo .brand { display: flex; align-items: center; gap: .6rem; color: var(--ink); font-weight: 700; font-size: 1.15rem; margin-bottom: 1.5rem; }
.solo .brand img { height: 40px; width: auto; max-width: 200px; }
.solo .brand .mark { width: 34px; height: 34px; border-radius: 9px; background: var(--brand); color: var(--brand-ink); display: grid; place-items: center; font-weight: 800; }
.solo .card { width: 100%; max-width: 460px; background: var(--surface); border: 1px solid var(--line); border-radius: 14px; box-shadow: var(--shadow); padding: 1.75rem; }
.solo .card.wide { max-width: 760px; }
.solo .card h1 { font-size: 1.4rem; margin-bottom: 1rem; }
.solo .card .panel { border: 0; padding: 0; box-shadow: none; background: none; }
.solo .foot { border: 0; text-align: center; }

/* ---------- Building blocks ---------- */
.panel { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: 1.1rem 1.25rem; margin: 0 0 1rem; box-shadow: var(--shadow); }
.panel > h2:first-child, .panel > h3:first-child { margin-top: 0; }
.callout { background: var(--brand-soft); border-color: var(--brand-line); box-shadow: none; }
.staffonly { border-left: 3px solid var(--brand-line); }
.staffonly h2 { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin-top: 0; }
.staffonly h2 .tag { font-size: .72rem; font-weight: 500; }
.narrow { max-width: 480px; }
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 0 1rem; }
.twocol { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 1.5rem; align-items: start; }
.twocol h2:first-child { margin-top: 0; }
.buttons { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin: .5rem 0; }
.bigprice { font-size: 1.9rem; font-weight: 700; letter-spacing: -.01em; margin: .25rem 0 .5rem; }

label { display: block; font-weight: 500; font-size: .9rem; margin: 0 0 .9rem; }
input, select, textarea { display: block; width: 100%; margin-top: .3rem; padding: .6rem .75rem; font: inherit; font-size: .95rem; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 8px; transition: border-color .15s, box-shadow .15s; }
input:focus, select:focus, textarea:focus { outline: none; border-color: var(--brand); box-shadow: 0 0 0 3px color-mix(in srgb, var(--brand) 18%, transparent); }
textarea { resize: vertical; }
input[type="file"] { padding: .5rem; background: var(--sunken); }
input[readonly] { background: var(--sunken); }
label.check { display: flex; gap: .55rem; align-items: center; font-weight: 400; }
label.check input { width: auto; margin: 0; accent-color: var(--brand); }
.fieldlabel { font-weight: 500; font-size: .9rem; margin: 0 0 .4rem; }
fieldset { border: 1px solid var(--line); }
legend { font-weight: 600; font-size: 1rem; padding: 0 .35rem; }

button { font: inherit; cursor: pointer; }
button.primary, a.button.primary { background: var(--brand); color: var(--brand-ink); border: 1px solid var(--brand); border-radius: 8px; padding: .6rem 1.15rem; font-weight: 600; font-size: .93rem; }
button.primary:hover, a.button.primary:hover { filter: brightness(1.06); text-decoration: none; }
a.button, button.small { display: inline-flex; align-items: center; gap: .4rem; background: var(--surface); color: var(--ink); border: 1px solid var(--line); border-radius: 8px; padding: .5rem .95rem; font-weight: 500; font-size: .9rem; box-shadow: var(--shadow); }
button.small { padding: .38rem .75rem; font-size: .86rem; }
a.button.small { padding: .3rem .65rem; font-size: .84rem; }
a.button:hover, button.small:hover { background: var(--sunken); text-decoration: none; }
button.danger { color: var(--bad-ink); border-color: color-mix(in srgb, var(--bad-ink) 35%, transparent); }
button.linkish { background: none; border: 0; color: inherit; padding: 0; }
form.inline { display: inline; }
.inline-form { display: flex; flex-wrap: wrap; gap: .6rem; align-items: end; margin: 0 0 1rem; }
.inline-form label { margin: 0; }
.inline-form input[type="file"] { width: auto; flex: 1 1 220px; margin: 0; }

.notice, .error { padding: .75rem 1rem; border-radius: 8px; margin: 0 0 1rem; font-size: .93rem; }
.notice { background: var(--ok-bg); color: var(--ok-ink); }
.error { background: var(--bad-bg); color: var(--bad-ink); }
ul.error { padding-left: 2rem; }
.warnings { background: var(--warn-bg); color: var(--warn-ink); border-radius: 8px; padding: .6rem 1rem .6rem 2rem; margin: .75rem 0 0; }

.tag { display: inline-flex; align-items: center; padding: .12rem .55rem; border-radius: 999px; font-size: .75rem; font-weight: 600; letter-spacing: .01em; background: var(--sunken); color: var(--muted); border: 1px solid var(--line); white-space: nowrap; }
.tag.ok { background: var(--ok-bg); color: var(--ok-ink); border-color: transparent; }
.tag.urgent { background: var(--warn-bg); color: var(--warn-ink); border-color: transparent; }
.tag.brand { background: var(--brand-soft); color: var(--brand); border-color: var(--brand-line); }

/* Tables */
.scroll { overflow-x: auto; background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); box-shadow: var(--shadow); margin-bottom: 1rem; }
table { width: 100%; border-collapse: collapse; font-size: .92rem; }
th, td { text-align: left; padding: .7rem .9rem; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { font-weight: 500; color: var(--muted); font-size: .82rem; background: var(--sunken); }
tbody tr:hover td { background: color-mix(in srgb, var(--brand) 3%, transparent); }
tr:last-child td { border-bottom: 0; }
td.num, th.num { text-align: right; }
td.neg { color: var(--bad-ink); font-weight: 600; }
tr.off td, tr.closedjob td { color: var(--muted); }
tr.closedjob td a { color: var(--ink); }
tr.sumrow td { font-weight: 700; border-top: 2px solid var(--line); }
dl { margin: 0; display: grid; grid-template-columns: max-content 1fr; gap: .55rem 1.25rem; font-size: .93rem; }
dt { color: var(--muted); }
dd { margin: 0; overflow-wrap: anywhere; }

.subnav { display: flex; flex-wrap: wrap; gap: .25rem; margin: 0 0 1.25rem; padding: .25rem; background: var(--sunken); border-radius: 10px; width: fit-content; max-width: 100%; }
.subnav a { padding: .4rem .8rem; border-radius: 8px; color: var(--muted); font-size: .9rem; font-weight: 500; }
.subnav a:hover { text-decoration: none; color: var(--ink); }
.subnav a[aria-current="page"] { background: var(--surface); color: var(--ink); box-shadow: var(--shadow); }
.filters { display: flex; flex-wrap: wrap; gap: .75rem; align-items: end; margin: 0 0 1.25rem; }
.filters label { margin: 0; }
.filters input, .filters select { width: auto; min-width: 170px; }
.pager { display: flex; gap: 1rem; align-items: center; justify-content: center; margin: 1rem 0; }

/* ---------- Dashboard cards ---------- */
.cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 1rem; margin-bottom: .5rem; }
.jobcard { display: flex; flex-direction: column; background: var(--surface); border: 1px solid var(--line); border-radius: 12px; overflow: hidden; color: var(--ink); box-shadow: var(--shadow); transition: transform .12s, box-shadow .12s; }
.jobcard:hover { text-decoration: none; transform: translateY(-2px); box-shadow: 0 6px 18px rgba(16, 24, 40, .08); }
.jobcard .pic { position: relative; aspect-ratio: 16 / 10; background: linear-gradient(135deg, var(--brand-soft), var(--sunken)); display: grid; place-items: center; }
.jobcard .pic img { width: 100%; height: 100%; object-fit: cover; display: block; }
.jobcard .pic svg { width: 42px; height: 42px; color: var(--brand-line); }
.jobcard .pic .tag { position: absolute; top: .6rem; left: .6rem; background: var(--surface); color: var(--ink); border: 0; box-shadow: var(--shadow); text-transform: uppercase; font-size: .68rem; letter-spacing: .04em; }
.jobcard .pic .tag.urgent { background: var(--warn-bg); color: var(--warn-ink); }
.jobcard .txt { padding: .85rem 1rem 1rem; display: flex; flex-direction: column; gap: .2rem; }
.jobcard .txt strong { font-weight: 600; font-size: .98rem; line-height: 1.35; }
.jobcard .txt span { color: var(--muted); font-size: .85rem; }

.stats { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: .9rem; margin-bottom: 1rem; }
.stat { background: var(--surface); border: 1px solid var(--line); border-radius: 12px; padding: .9rem 1.1rem; display: flex; flex-direction: column; gap: .2rem; box-shadow: var(--shadow); color: var(--ink); }
a.stat:hover { text-decoration: none; border-color: var(--brand-line); }
.stat strong { font-size: 1.6rem; font-weight: 700; letter-spacing: -.01em; }
.todo { list-style: none; padding: 0; margin: 0 0 1rem; background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); box-shadow: var(--shadow); overflow: hidden; }
.todo li { padding: .7rem 1rem; border-bottom: 1px solid var(--line); display: flex; gap: .5rem; align-items: center; flex-wrap: wrap; }
.todo li:last-child { border-bottom: 0; }
.todo li::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--brand); flex: none; }
.todo a { color: var(--ink); }
.pipeline { list-style: none; padding: 0; margin: 0 0 1rem; display: flex; overflow-x: auto; gap: .5rem; }
.pipeline li { flex: 1 0 110px; background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: .7rem .75rem; display: flex; flex-direction: column; gap: .15rem; font-size: .8rem; color: var(--muted); }
.pipeline li.has { color: var(--ink); border-color: var(--brand-line); background: var(--brand-soft); }
.pipeline .n { font-size: 1.5rem; font-weight: 700; }
.soon { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: .6rem; margin-bottom: .5rem; }
.soon > div { display: flex; flex-direction: column; gap: .25rem; }
.soon > div > .muted { font-size: .8rem; }
.who { display: none; }

/* Job requests */
.choices { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: .75rem; }
.choice { display: flex; flex-direction: column; gap: .25rem; background: var(--surface); border: 1px solid var(--line); border-radius: 12px; padding: 1rem 1.1rem; color: var(--ink); box-shadow: var(--shadow); }
.choice:hover { border-color: var(--brand); text-decoration: none; }
.choice span { color: var(--muted); font-size: .9rem; }
.picked { display: flex; gap: .75rem; align-items: baseline; margin: 0 0 .75rem; }
.request { max-width: 680px; }
.request legend, .settings legend, .certform legend { font-weight: 600; }

/* Job page */
.jobhead { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin: 0 0 1rem; }
.jobhead .ref { font-weight: 600; color: var(--muted); font-size: .9rem; }
.jobgrid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1rem; margin-bottom: 1rem; }
.jobgrid .panel { margin: 0; }
.jobgrid h2 { margin-top: 0; }
.photos { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: .6rem; margin-bottom: .75rem; }
.photos img { width: 100%; aspect-ratio: 4 / 3; object-fit: cover; border-radius: 10px; border: 1px solid var(--line); display: block; }
.history { list-style: none; padding: 0; margin: 0 0 1rem; border-left: 2px solid var(--line); }
.history li { padding: .3rem 0 .7rem 1rem; position: relative; font-size: .93rem; }
.history li::before { content: ""; position: absolute; left: -6px; top: .65rem; width: 10px; height: 10px; border-radius: 50%; background: var(--surface); border: 2px solid var(--brand-line); }
.admin-actions { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 1rem; margin-top: 1rem; }
.admin-actions .panel { margin: 0; }

/* Estimates, quotes, invoices */
.estimate details { margin: .75rem 0; }
.estimate summary, .sendquote summary, .recordpay summary, .respond details summary, .feed summary, .qual summary, .emailtpl summary { cursor: pointer; font-weight: 600; }
.breakdown td { white-space: normal; }
.breakdown tr.group th { background: var(--sunken); color: var(--ink); }
.breakdown tr.sum td { font-weight: 600; }
.breakdown tr.grand td { font-weight: 700; font-size: 1.05rem; border-top: 2px solid var(--ink); }
.quote { border-top: 3px solid var(--brand); }
.quotehead { display: flex; flex-wrap: wrap; gap: .75rem; align-items: center; justify-content: space-between; }
.quotehead h2, .quotehead h3 { margin: 0; }
.quote h3 { margin: 1rem 0 .3rem; }
.quotetable td { white-space: normal; }
.respond { display: flex; flex-wrap: wrap; gap: 1rem; align-items: start; margin-top: 1rem; padding-top: 1rem; border-top: 1px solid var(--line); }
.respond details summary { padding: .55rem 0; color: var(--muted); font-weight: 500; }
.sendquote { margin: 1rem 0 0; background: var(--sunken); box-shadow: none; }
.sendquote form { margin-top: 1rem; }
.wtotals { max-width: 380px; margin: 1rem 0 1rem auto; font-size: .93rem; }
.wtotals div { display: flex; justify-content: space-between; padding: .25rem 0; }
.wtotals .sum { border-top: 1px solid var(--line); font-weight: 600; margin-top: .3rem; padding-top: .45rem; }
.wtotals .grand { font-weight: 700; font-size: 1.12rem; border-top: 2px solid var(--ink); margin-top: .3rem; padding-top: .45rem; }
.invoices .invoice { border-top: 1px solid var(--line); padding-top: .9rem; margin-top: .9rem; }
.invoices .invoice:first-of-type { border-top: 0; margin-top: 0; padding-top: 0; }
.invoices .invoice.void { opacity: .6; }
.invoices .wtotals { margin: .5rem 0 .75rem auto; }
.payhow { background: var(--sunken); border-radius: 8px; padding: .6rem 1rem; margin-top: .75rem; }
.recordpay { margin-top: .75rem; }
.recordpay .panel { margin-top: .5rem; }
.payments { margin: 0; padding-left: 1.2rem; }
.nextstep h3:first-of-type { margin-top: .25rem; }
.nextstep form.inline { display: inline-block; margin: .25rem .5rem .25rem 0; }
.schedule { display: grid; grid-template-columns: 1.2fr 1fr 1fr auto; gap: .75rem; align-items: end; }
.schedule label { margin: 0; }
.route .stops { padding-left: 1.3rem; margin: 0 0 1rem; }
.route .stops li { margin-bottom: .6rem; }

/* Worksheet and parts */
.worksheet { max-width: 1050px; }
.wline, .pline { display: grid; gap: .5rem; align-items: end; padding: .6rem 0; border-bottom: 1px solid var(--line); }
.wline { grid-template-columns: 120px 1fr 80px 80px 100px 90px 90px; }
.pline { grid-template-columns: 1fr 80px 160px 150px 1fr 90px; }
.wline label, .pline label { margin: 0; font-size: .82rem; }
.wline.new, .pline.new { opacity: .8; }
.wline .ltotal { text-align: right; padding-bottom: .65rem; font-weight: 600; }
.wline .del, .pline .del { padding-bottom: .6rem; }
.addmat { display: grid; grid-template-columns: 1fr 120px auto; gap: .75rem; align-items: end; margin-top: .75rem; }
.addmat label { margin: 0; }
.clock { display: flex; flex-wrap: wrap; gap: .75rem; align-items: end; margin-bottom: .75rem; }
.clock p { margin: 0; flex-basis: 100%; }
.clock label { margin: 0; flex: 1 1 220px; }
.clock.on { background: var(--ok-bg); color: var(--ok-ink); padding: .85rem; border-radius: 10px; }

/* Settings, pricing, people */
.settings { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 1rem; align-items: start; }
.settings .panel, .settings fieldset { margin: 0; }
.settings > button { justify-self: start; }
.accessrow { display: grid; grid-template-columns: 1fr 120px auto auto; gap: .75rem; align-items: end; margin-bottom: .5rem; }
.accessrow label { margin: 0; }
.accessrow.off { opacity: .6; }
.rateform { display: flex; align-items: center; gap: .3rem; }
.rateform input { width: 84px; margin: 0; padding: .35rem .5rem; }
.qual .qualform { margin: .75rem 0 .5rem; background: var(--sunken); box-shadow: none; }
.branding { margin-bottom: 1rem; }
.logoprev { max-height: 80px; max-width: 100%; background: var(--sunken); padding: .5rem; border-radius: 8px; }
label.colour span { display: flex; align-items: center; gap: .5rem; margin-top: .3rem; }
label.colour input[type="color"] { width: 3rem; height: 2.3rem; padding: .15rem; margin: 0; }
.preview { white-space: pre-wrap; background: var(--sunken); border: 1px solid var(--line); border-radius: 8px; padding: .75rem 1rem; font-size: .93rem; }
.emailtpl summary { display: flex; flex-wrap: wrap; gap: .5rem; align-items: baseline; }
.emailtpl form { margin-top: 1rem; }

/* Certificates */
.certlist { list-style: none; padding: 0; margin: 0 0 1rem; }
.certlist li { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; padding: .6rem 0; border-bottom: 1px solid var(--line); }
.certlist li:last-child { border-bottom: 0; }
.certform { max-width: 1050px; }
.certgrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(210px, 1fr)); gap: 0 1rem; }
.certitem { border-top: 1px solid var(--line); padding-top: .75rem; margin-top: .5rem; }
.certitem:first-of-type { border-top: 0; margin-top: 0; padding-top: 0; }
.certitem.new { opacity: .85; }
.certform .issue { border-top: 3px solid var(--brand); }

/* Calendar and availability */
.weeknav { display: flex; flex-wrap: wrap; gap: .5rem; margin-bottom: .5rem; }
table.week { table-layout: fixed; min-width: 900px; }
table.week th, table.week td { white-space: normal; vertical-align: top; width: 12.5%; }
table.week td { padding: .45rem; }
table.week .today { background: var(--brand-soft); }
.ev { display: flex; flex-direction: column; gap: .05rem; color: var(--ink); font-size: .8rem; line-height: 1.3; padding: .4rem .5rem; border-radius: 7px; margin-bottom: .35rem; background: var(--sunken); border-left: 3px solid var(--muted); }
.ev:hover { text-decoration: none; background: var(--brand-soft); }
.ev.insp { border-left-color: var(--brand); }
.ev.work.live { border-left-color: #2e9d5b; }
.agenda { display: grid; gap: .75rem; }
.aday { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: .75rem .9rem; box-shadow: var(--shadow); }
.aday.today { border-color: var(--brand-line); background: var(--brand-soft); }
.aday h3 { margin: 0 0 .45rem; }
.slotday h3 { margin: 1.25rem 0 .5rem; }
.slots { display: flex; flex-wrap: wrap; gap: .45rem; }
button.slot { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: .55rem .95rem; font-weight: 600; color: var(--ink); }
button.slot:hover, button.slot:focus-visible { background: var(--brand); color: var(--brand-ink); border-color: var(--brand); }
.feed { margin-top: 1.5rem; }
.avmonth { display: grid; gap: .3rem; margin-bottom: 1rem; }
.avrow { display: grid; grid-template-columns: 110px 140px 1fr 1fr; gap: .5rem; align-items: center; padding: .35rem .6rem; border-radius: 8px; background: var(--surface); border: 1px solid var(--line); }
.avrow select, .avrow input { margin: 0; padding: .35rem .5rem; }
.avrow.weekend { background: var(--sunken); }
.avrow.off { border-left: 3px solid var(--muted); }
.avrow.hours { border-left: 3px solid var(--brand); }
.avrow.holiday { border-left: 3px solid #d99a1c; grid-template-columns: 110px auto 1fr; }
.avrow.past { opacity: .5; }
.avday { font-weight: 600; font-size: .88rem; }
.dows { display: flex; flex-wrap: wrap; gap: .25rem 1rem; margin-bottom: .75rem; }
.dows label { margin: 0; }
.avchip { display: block; font-size: .74rem; padding: .15rem .45rem; border-radius: 6px; margin-bottom: .3rem; background: var(--sunken); color: var(--muted); }
.avchip.holiday { background: var(--warn-bg); color: var(--warn-ink); }
.avchip.off { background: var(--line); color: var(--ink); }

/* Reports */
.bars { display: grid; grid-template-columns: repeat(12, 1fr); gap: .45rem; align-items: end; height: 190px; background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: .85rem .85rem 0; box-shadow: var(--shadow); margin-bottom: 1rem; }
.bar { display: flex; flex-direction: column; justify-content: flex-end; height: 100%; }
.bar .fill { display: block; background: color-mix(in srgb, var(--brand) 70%, #ffffff); border-radius: 5px 5px 0 0; min-height: 2px; }
.bar .lbl { text-align: center; font-size: .72rem; color: var(--muted); padding: .35rem 0; }

@media (max-width: 760px) {
  .row { grid-template-columns: 1fr; }
  dl { grid-template-columns: 1fr; gap: .1rem; }
  dd { margin-bottom: .55rem; }
  .schedule, .wline, .pline { grid-template-columns: 1fr 1fr; }
  .wline .desc, .pline .desc { grid-column: 1 / -1; grid-row: 1; }
  .wline .ltotal { text-align: left; }
  .addmat, .accessrow { grid-template-columns: 1fr; }
  .avrow { grid-template-columns: 1fr 1fr; }
  .avrow .avday { grid-column: 1 / -1; }
  .filters input, .filters select { min-width: 0; width: 100%; }
  .filters label { flex: 1 1 140px; }
}
@media (max-width: 860px) {
  .tabbar:has(> a:nth-child(4):last-child) { grid-template-columns: repeat(4, 1fr); }
  .tabbar:has(> a:nth-child(3):last-child) { grid-template-columns: repeat(3, 1fr); }
}
.menulist { display: grid; gap: .35rem; max-width: 520px; }
.menulist a, .menulist button { display: flex; align-items: center; gap: .75rem; padding: .85rem 1rem; background: var(--surface); border: 1px solid var(--line); border-radius: 10px; color: var(--ink); font: inherit; width: 100%; text-align: left; box-shadow: var(--shadow); }
.menulist a:hover { text-decoration: none; border-color: var(--brand-line); }
.menulist svg { width: 20px; height: 20px; color: var(--brand); }
.menulist .navsection { padding: .9rem .25rem .2rem; }
HANDYTRIO_EOF

echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "New look installed. Refresh the page (the app restarts by itself; otherwise run: npm run dev)"
