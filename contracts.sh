#!/usr/bin/env bash
# SWAT update A: contracts with online signing, cancellation rights, and approved extras. Run with: bash contracts.sh
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

-- Contracts and variations
ALTER TABLE users ADD COLUMN IF NOT EXISTS customer_type text NOT NULL DEFAULT 'home';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS contract_terms text NOT NULL DEFAULT '';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS company_number text NOT NULL DEFAULT '';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS vat_number text NOT NULL DEFAULT '';
ALTER TABLE settings ADD COLUMN IF NOT EXISTS guarantee_months int NOT NULL DEFAULT 12;
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS terms text;
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS consumer boolean;
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS signed_name text;
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS signed_at timestamptz;
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS signed_ip text;
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS signed_device text;
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS early_start boolean;
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS cancel_until date;
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS contract_cancelled_at timestamptz;

CREATE TABLE IF NOT EXISTS variations (
  id            serial PRIMARY KEY,
  job_id        int NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  description   text NOT NULL,
  reason        text,
  amount_net    numeric NOT NULL CHECK (amount_net >= 0),
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','declined','withdrawn')),
  created_by    int REFERENCES users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  responded_at  timestamptz,
  responded_by  int REFERENCES users(id),
  signed_name   text,
  response_note text,
  invoice_id    int REFERENCES invoices(id)
);
CREATE INDEX IF NOT EXISTS variations_job_idx ON variations (job_id);

INSERT INTO email_templates (status, subject, body) VALUES
 ('variation_raised', 'Extra work needs your approval ({job_ref})', E'Hi {first_name},\n\nWhile working on "{job_title}" we found something that needs extra work:\n\n{variation_description}\n\nThe extra cost would be {variation_total}. We won’t go ahead until you approve it. You can approve or decline here:\n{job_link}\n\nThanks,\n{business_name}')
ON CONFLICT (status) DO NOTHING;
HANDYTRIO_EOF

cat > src/terms-default.js <<'HANDYTRIO_EOF'
// Starting terms and conditions. Review them (ideally with a solicitor) and edit under Settings.
module.exports = (s) => `1. Who we are
${s.business_name}${s.business_address ? `, ${s.business_address.replace(/\n/g, ', ')}` : ''}${s.company_number ? `. Company number ${s.company_number}` : ''}${s.vat_number ? `. VAT number ${s.vat_number}` : ''}.

2. The work
We will carry out the work described in the quote with reasonable care and skill, using suitable materials, and in line with relevant regulations. Anything not listed in the quote is not included.

3. Price
The price is as shown in the quote, which is valid until the date shown on it. If we find something that could not reasonably have been seen before work started, or you ask for changes, we will tell you the extra cost and get your approval before doing it. Approved extras are added to the final invoice.

4. Payment
A deposit, as shown on the quote, is due before we book the work in and order materials. The balance is due within ${s.payment_terms_days} days of the final invoice. Materials stay our property until they are paid for in full.

5. Access and your responsibilities
Please give us safe access to the work area, a power and water supply, and clear the area of belongings where reasonable. Tell us about anything we should know, such as hidden pipes or cables, asbestos, or access restrictions.

6. Delays
We will keep to the agreed dates where we can, and tell you as soon as possible about any delay caused by weather, illness, supply problems or other things outside our control.

7. Waste
Unless the quote says otherwise, we will remove waste we create and leave the area clean and tidy.

8. Guarantee
We guarantee our workmanship for ${s.guarantee_months} months from completion. Manufacturers' guarantees on parts and appliances are passed on to you. This does not cover damage from misuse, accidents or normal wear and tear, and does not affect your legal rights.

9. Our liability
We are responsible for loss or damage that is a foreseeable result of our breaking this contract or failing to use reasonable care and skill. We hold public liability insurance. Nothing in these terms limits liability for death or personal injury caused by negligence, or anything else the law does not allow us to limit.

10. Problems and complaints
If you are unhappy with anything, please tell us as soon as possible so we can put it right.

11. Your personal information
We use your information as set out in our privacy notice on our website.

12. Law
These terms are governed by the law of England and Wales.`;
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
  if (res.setHeader) {
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader('Content-Disposition', `${opts.download ? 'attachment' : 'inline'}; filename="${opts.filename}"`);
  }
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

// Same document, but returned as a file in memory (for email attachments).
function renderDocumentBuffer(opts) {
  const { PassThrough } = require('stream');
  return new Promise((resolve, reject) => {
    const out = new PassThrough();
    const chunks = [];
    out.on('data', (c) => chunks.push(c));
    out.on('end', () => resolve(Buffer.concat(chunks)));
    out.on('error', reject);
    renderDocument({ ...opts, res: out });
  });
}

module.exports = { renderDocument, renderDocumentBuffer };
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

const PLACEHOLDERS = ['variation_description', 'variation_total', 'inspection_time', 'booked_dates', 'cert_name', 'cert_number', 'first_name', 'customer_name', 'job_ref', 'job_title', 'stage', 'price_guide', 'job_link', 'business_name'];

module.exports = { jobVars, notifyStageChange, notifyOffice, sendEmail, fill, emailReady, PLACEHOLDERS };
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
app.use(require('./routes/contracts').router);
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

cat > src/routes/contracts.js <<'HANDYTRIO_EOF'
// Pre-work contracts (customers sign the quote online, with the UK 14-day cancellation rules for home customers)
// and variations (extra work the customer approves before it's added to the bill).
const express = require('express');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day, when, ukDate, addDays } = require('../format');
const { money } = require('../estimate');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange, notifyOffice, sendEmail, fill, jobVars } = require('../notify');
const { renderDocument, renderDocumentBuffer } = require('../pdf');
const termsDefault = require('../terms-default');

const router = express.Router();
const N = (x) => Number(x) || 0;
const r2 = (n) => Math.round(n * 100) / 100;
const qref = (id) => 'Q-' + String(id).padStart(5, '0');
const settings = async () => (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
const termsFor = (s) => s.contract_terms || termsDefault(s);
const CANCEL_DAYS = 14;

// The cancellation information home customers must be given (Consumer Contracts Regulations).
function cancellationText(q, s) {
  return `Your right to cancel
You can cancel this contract within ${CANCEL_DAYS} days without giving a reason. The cancellation period ends ${CANCEL_DAYS} days after the day you accepted it${q.cancel_until ? `, on ${day(q.cancel_until)}` : ''}.

To cancel, tell us clearly before the period ends: use the cancel button on your job page, email ${s.business_email || 'us'}${s.business_phone ? `, call ${s.business_phone}` : ''}, or write to us${s.business_address ? ` at ${s.business_address.replace(/\n/g, ', ')}` : ''}. You can use the form below, but you don't have to.

If you cancel, we will refund any payment you've made within ${CANCEL_DAYS} days of being told, using the same payment method.

${q.early_start
    ? 'You asked us to start work during the cancellation period. If you cancel, you must pay for the work done up to the time you tell us, in proportion to the full price. Once the work is fully complete, you lose the right to cancel.'
    : 'We won’t start work until the cancellation period has ended, unless you ask us to.'}

Cancellation form
To ${s.business_name}: I cancel my contract for the following work: ............
Accepted on: ............   Name: ............   Address: ............
Signature (if sent on paper): ............   Date: ............`;
}

async function acceptedQuote(jobId) {
  return (await query("SELECT * FROM quotes WHERE job_id = $1 AND status = 'accepted' ORDER BY id DESC LIMIT 1", [jobId])).rows[0] || null;
}

// ---------- Contract PDF ----------
async function contractDoc(q, job, s) {
  const { displayLines } = require('./quotes');
  const m = (n) => money(n, s.currency);
  const cust = (await query('SELECT name, email, phone FROM users WHERE id = $1', [job.customer_id])).rows[0];
  const totals = [['Net', m(q.net)]];
  if (N(q.vat)) totals.push([`VAT ${N(q.vat_rate)}%`, m(q.vat)]);
  totals.push(['Contract price', m(q.total), true]);
  const blocks = [
    { title: 'Payment', text: `${N(q.deposit) ? `Deposit of ${m(q.deposit)} (${N(q.deposit_pct)}%) due before the work is booked in. ` : ''}The balance is due within ${s.payment_terms_days} days of the final invoice. Any extra work you approve is added to the final invoice.` },
  ];
  if (q.consumer) blocks.push({ title: ' ', text: cancellationText(q, s) });
  blocks.push({ title: 'Terms and conditions', text: q.terms || termsFor(s), small: true });
  blocks.push(q.signed_at
    ? { title: 'Signed', text: `Accepted online by ${q.signed_name} on ${when(q.signed_at)} (UK time).${q.consumer ? ` ${q.early_start ? 'Asked for work to start within the cancellation period.' : 'Chose to wait until the cancellation period ends.'}` : ''}\nRecord: ${q.signed_ip || 'unknown address'}; ${String(q.signed_device || '').slice(0, 120)}` }
    : q.status === 'accepted'
      ? { title: 'Accepted', text: `Accepted on the customer’s behalf by ${s.business_name} on ${when(q.responded_at)}.` }
      : { title: 'Not yet signed', text: 'This contract has not been accepted yet.' });
  return {
    s, money: m, filename: `Contract-${qref(q.id)}.pdf`, title: 'Contract',
    meta: [['Quote', qref(q.id)], ['Date', day(q.created_at)], ['Job', ref(job.id)], ['Customer', q.consumer ? 'Home' : 'Business']],
    customer: { name: cust.name, lines: [job.address_line, job.town, job.postcode, cust.phone, cust.email] },
    heading: job.title, intro: q.scope, itemised: q.layout === 'itemised', rows: displayLines(q), totals, blocks,
  };
}

router.get('/jobs/:id/quotes/:qid/contract', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const q = (await query('SELECT * FROM quotes WHERE id = $1 AND job_id = $2', [Number(req.params.qid) || 0, job.id])).rows[0];
  if (!q) return notFound(req, res);
  renderDocument({ ...(await contractDoc(q, job, await settings())), res, download: Boolean(req.query.download) });
}));

// ---------- Signing ----------
async function signable(req) {
  const job = await loadJob(req);
  if (!job || req.user.role !== 'customer') return {};
  const q = (await query('SELECT * FROM quotes WHERE id = $1 AND job_id = $2', [Number(req.params.qid) || 0, job.id])).rows[0];
  const ok = q && q.status === 'sent' && job.status === 'quoted' && !(q.valid_until && new Date(q.valid_until) < new Date(new Date().toDateString()));
  return { job, q: ok ? q : null };
}

router.get('/jobs/:id/quotes/:qid/accept', requireLogin, wrap(async (req, res) => {
  const { job, q } = await signable(req);
  if (!job) return notFound(req, res);
  if (!q) return res.redirect(`/jobs/${job.id}#quote`);
  const s = await settings();
  const me = (await query('SELECT name, customer_type FROM users WHERE id = $1', [req.user.id])).rows[0];
  const consumer = me.customer_type !== 'business';
  const m = (n) => money(n, s.currency);
  const preview = { ...q, consumer, cancel_until: addDays(ukDate(new Date()), CANCEL_DAYS), early_start: false };
  const body = `<p class="jobhead"><a href="/jobs/${job.id}#quote">Back to the quote</a></p>
    <form method="post" action="/jobs/${job.id}/quotes/${q.id}/accept" class="signform">
      <section class="panel">
        <h2>${esc(job.title)}</h2>
        <p class="bigprice">${m(q.total)}${N(q.vat) ? ' <span class="muted small">including VAT</span>' : ''}</p>
        <p>${N(q.deposit) ? `A deposit of <strong>${m(q.deposit)}</strong> is due before we book the work in. ` : ''}The balance is due within ${s.payment_terms_days} days of the final invoice.</p>
        <p><a href="/jobs/${job.id}/quotes/${q.id}/contract" target="_blank" rel="noopener">View the full contract as a PDF</a></p>
      </section>
      ${consumer ? `<section class="panel callout">
        <h2>Your right to cancel</h2>
        <p>As this is for your home and you’re agreeing online, you can cancel within ${CANCEL_DAYS} days without giving a reason. Before then, we only start work if you ask us to.</p>
        <label class="check"><input type="radio" name="start" value="wait" required> Start after the ${CANCEL_DAYS}-day cancellation period (from ${day(preview.cancel_until)})</label>
        <label class="check"><input type="radio" name="start" value="early" required> Please start sooner. I understand that if I cancel, I’ll pay for work done up to then, and once the work is finished I can no longer cancel.</label>
      </section>` : ''}
      <section class="panel">
        <h2>Terms and conditions</h2>
        <div class="termsbox pre">${esc(q.terms || termsFor(s))}</div>
      </section>
      <section class="panel issue">
        <h2>Sign and accept</h2>
        <label class="check"><input type="checkbox" name="agree" required> I accept this quote and the terms and conditions above.</label>
        <label>Type your full name to sign<input name="signed_name" value="" required minlength="3" maxlength="120" autocomplete="name" placeholder="${esc(me.name)}"></label>
        <p class="hint">Typing your name counts as your signature. We record the date, time and device. You and we both get a copy of the signed contract by email.</p>
        <button class="primary">Sign and accept</button>
      </section>
    </form>`;
  res.send(page({ title: 'Accept your quote', user: req.user, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
}));

router.post('/jobs/:id/quotes/:qid/accept', requireLogin, wrap(async (req, res, next) => {
  if (req.user.role !== 'customer') return next(); // the office's "Mark as accepted" is handled in quotes.js
  const { job, q } = await signable(req);
  if (!job) return notFound(req, res);
  if (!q) return res.redirect(`/jobs/${job.id}#quote`);
  const me = (await query('SELECT customer_type FROM users WHERE id = $1', [req.user.id])).rows[0];
  const consumer = me.customer_type !== 'business';
  const name = String(req.body.signed_name || '').trim().slice(0, 120);
  let error = null;
  if (req.body.agree !== 'on') error = 'Tick to accept the quote and terms.';
  else if (name.length < 3) error = 'Type your full name to sign.';
  else if (consumer && !['wait', 'early'].includes(req.body.start)) error = 'Choose when you’d like us to start.';
  if (error) return res.redirect(`/jobs/${job.id}/quotes/${q.id}/accept?error=${encodeURIComponent(error)}`);

  const s = await settings();
  const early = consumer && req.body.start === 'early';
  const cancelUntil = consumer ? addDays(ukDate(new Date()), CANCEL_DAYS) : null;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(
      `UPDATE quotes SET status = 'accepted', responded_at = now(), responded_by = $1, signed_name = $2, signed_at = now(), signed_ip = $3,
         signed_device = $4, consumer = $5, early_start = $6, cancel_until = $7, terms = coalesce(terms, $8) WHERE id = $9`,
      [req.user.id, name, req.ip, String(req.get('user-agent') || '').slice(0, 300), consumer, early, cancelUntil, termsFor(s), q.id]);
    await setStatus(client, job.id, job.status, 'accepted', req.user.id,
      `Contract ${qref(q.id)} signed online by ${name}${consumer ? (early ? ', asked to start within the cancellation period' : `, cancellation period until ${day(cancelUntil)}`) : ''}`);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }

  // Signed copies for both sides.
  const signed = (await query('SELECT * FROM quotes WHERE id = $1', [q.id])).rows[0];
  const pdf = await renderDocumentBuffer(await contractDoc(signed, job, s));
  const attachments = [{ filename: `Contract-${qref(q.id)}.pdf`, content: pdf, contentType: 'application/pdf' }];
  await sendEmail({ to: job.customer_email, subject: `Your signed contract with ${s.business_name} (${qref(q.id)})`, jobId: job.id, attachments,
    body: `Hi ${job.customer_name.split(' ')[0]},\n\nThank you for accepting our quote for "${job.title}". Your signed contract is attached, please keep it safe.${consumer ? `\n\nYou can cancel until ${day(cancelUntil)}. ${early ? 'You asked us to start sooner, so we may begin before then.' : 'We won’t start before then.'}` : ''}\n\n${baseUrlOf(req)}/jobs/${job.id}\n\nThanks,\n${s.business_name}` });
  await notifyOffice(`Contract signed: ${job.title} (${ref(job.id)})`,
    `${job.customer_name} signed contract ${qref(q.id)} for ${money(q.total)}.${consumer ? `\nHome customer: ${early ? 'asked to start within the cancellation period.' : `can cancel until ${day(cancelUntil)}; don’t start before then.`}` : '\nBusiness customer.'}\n\nNext: request the deposit.\n${baseUrlOf(req)}/jobs/${job.id}`, job.id);
  await notifyStageChange(job.id, 'accepted', baseUrlOf(req));
  res.redirect(`/jobs/${job.id}?updated=1#contract`);
}));

// ---------- Cancelling within the cancellation period ----------
const canCancel = (q, job) => q && q.consumer && q.cancel_until && !q.contract_cancelled_at
  && ukDate(new Date()) <= String(q.cancel_until instanceof Date ? ukDate(q.cancel_until) : q.cancel_until).slice(0, 10)
  && !['complete', 'invoiced', 'paid', 'cancelled'].includes(job.status);

router.post('/jobs/:id/contract/cancel', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || req.user.role !== 'customer') return notFound(req, res);
  const q = await acceptedQuote(job.id);
  if (!canCancel(q, job) || req.body.confirm !== 'on') return res.redirect(`/jobs/${job.id}#contract`);
  const paid = N((await query('SELECT coalesce(sum(amount), 0) AS n FROM payments WHERE job_id = $1', [job.id])).rows[0].n);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE quotes SET contract_cancelled_at = now() WHERE id = $1', [q.id]);
    await setStatus(client, job.id, job.status, 'cancelled', req.user.id, 'Contract cancelled by the customer within the cancellation period');
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyStageChange(job.id, 'cancelled', baseUrlOf(req));
  await notifyOffice(`Contract cancelled: ${job.title} (${ref(job.id)})`,
    `${job.customer_name} has cancelled contract ${qref(q.id)} within their ${CANCEL_DAYS}-day cancellation period.\n\n${paid ? `They have paid ${money(paid)}. This must be refunded within ${CANCEL_DAYS} days${q.early_start ? ', less a fair amount for any work already done (they asked for an early start)' : ''}.` : 'No payments have been taken.'}\nCancel any parts orders that can still be cancelled.\n\n${baseUrlOf(req)}/jobs/${job.id}`, job.id);
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

// ---------- Panel on the job page ----------
async function contractPanel(job, user) {
  const q = await acceptedQuote(job.id);
  if (!q) return '';
  const can = user.role === 'customer' && canCancel(q, job);
  const cu = q.cancel_until ? day(q.cancel_until) : '';
  return `<section class="panel" id="contract">
    <div class="quotehead"><h2>Contract</h2>${q.contract_cancelled_at ? '<span class="tag urgent">Cancelled</span>' : q.signed_at ? '<span class="tag ok">Signed</span>' : '<span class="tag">Accepted by the office</span>'}</div>
    <p class="muted">${q.signed_at ? `Signed by ${esc(q.signed_name)}, ${when(q.signed_at)}` : `Accepted ${day(q.responded_at)}`}${q.consumer ? ` · Home customer${cu ? `, cancellation period until ${cu}` : ''}${q.early_start ? ', early start requested' : ''}` : ''}</p>
    ${user.role !== 'customer' && q.consumer && !q.early_start && cu && ukDate(new Date()) <= ukDate(q.cancel_until) ? `<div class="warnings">Don’t start work before ${cu}: the customer chose to wait out the cancellation period.</div>` : ''}
    <div class="buttons">
      <a class="button" href="/jobs/${job.id}/quotes/${q.id}/contract" target="_blank" rel="noopener">View contract</a>
      <a class="button" href="/jobs/${job.id}/quotes/${q.id}/contract?download=1">Download PDF</a>
    </div>
    ${can ? `<details class="recordpay"><summary>Cancel this contract</summary>
      <form method="post" action="/jobs/${job.id}/contract/cancel" class="panel">
        <p>You can cancel until ${cu} without giving a reason. Any money you’ve paid will be refunded within ${CANCEL_DAYS} days${q.early_start ? ', less a fair amount for work already done' : ''}.</p>
        <label class="check"><input type="checkbox" name="confirm" required> Yes, cancel my contract</label>
        <button class="small danger">Cancel contract</button>
      </form></details>` : ''}
  </section>`;
}

// ======================= Variations =======================
const VAR_STAGES = ['accepted', 'deposit_requested', 'deposit_paid', 'parts_ordered', 'scheduled', 'in_progress', 'complete'];
const mayRaise = (user, job) => user.role === 'admin' || (user.role === 'builder' && job.assigned_builder_id === user.id);

async function variationsPanel(job, user) {
  const s = await settings();
  const m = (n) => money(n, s.currency);
  const vatRate = s.vat_registered ? N(s.vat_rate) : 0;
  const gross = (net) => r2(N(net) * (1 + vatRate / 100));
  const list = (await query(
    `SELECT v.*, u.name AS by_name FROM variations v LEFT JOIN users u ON u.id = v.created_by WHERE v.job_id = $1 ${user.role === 'customer' ? "AND v.status <> 'withdrawn'" : ''} ORDER BY v.id`, [job.id])).rows;
  const canRaise = user.role !== 'customer' && mayRaise(user, job) && VAR_STAGES.includes(job.status);
  if (!list.length && !canRaise) return '';
  const tag = (v) => ({ pending: '<span class="tag urgent">Waiting for approval</span>', approved: '<span class="tag ok">Approved</span>', declined: '<span class="tag">Declined</span>', withdrawn: '<span class="tag">Withdrawn</span>' }[v.status]);
  const items = list.map((v) => `<li class="variation">
    <div><strong>${esc(v.description)}</strong> ${tag(v)}</div>
    ${v.reason ? `<p class="muted small">${esc(v.reason)}</p>` : ''}
    <p>${m(gross(v.amount_net))}${vatRate ? ' <span class="muted small">including VAT</span>' : ''}${v.invoice_id ? ' <span class="muted small">· on the final invoice</span>' : ''}</p>
    ${v.responded_at ? `<p class="muted small">${v.status === 'approved' ? `Approved by ${esc(v.signed_name || 'the office')}` : v.status === 'declined' ? 'Declined' : 'Withdrawn'} ${when(v.responded_at)}${v.response_note && user.role !== 'customer' ? `: ${esc(v.response_note)}` : ''}</p>` : ''}
    ${v.status === 'pending' && user.role === 'customer' ? `<div class="respond">
      <form method="post" action="/jobs/${job.id}/variations/${v.id}/approve" class="inline-form">
        <label>Type your name to approve<input name="signed_name" required minlength="3" maxlength="120" autocomplete="name"></label>
        <button class="primary">Approve</button>
      </form>
      <details><summary>Decline</summary>
        <form method="post" action="/jobs/${job.id}/variations/${v.id}/decline" class="panel">
          <label>Anything we should know? (optional)<textarea name="note" rows="2" maxlength="500"></textarea></label>
          <button class="small danger">Decline</button>
        </form></details>
    </div>` : ''}
    ${v.status === 'pending' && user.role !== 'customer' ? `<div class="buttons">
      ${user.role === 'admin' ? `<form method="post" action="/jobs/${job.id}/variations/${v.id}/approve" class="inline"><button class="small">Customer agreed by phone</button></form>` : ''}
      <form method="post" action="/jobs/${job.id}/variations/${v.id}/withdraw" class="inline"><button class="small">Withdraw</button></form></div>` : ''}
  </li>`).join('');
  return `<section class="panel" id="variations">
    <h2>Extra work</h2>
    ${items ? `<ul class="certlist">${items}</ul>` : '<p class="muted">No extra work so far.</p>'}
    ${canRaise ? `<details class="sendquote"><summary>Price some extra work</summary>
      <form method="post" action="/jobs/${job.id}/variations">
        <label>What the extra work is<input name="description" required maxlength="200" placeholder="Replace rotten joist under the bathroom floor"></label>
        <label>Why it’s needed (shown to the customer)<textarea name="reason" rows="2" maxlength="1000"></textarea></label>
        <label>Price before VAT<input name="amount" type="number" step="0.01" min="0" required></label>
        <p class="hint">The customer is emailed and approves it online. Don’t do the work until it shows Approved. Approved extras are added to the final invoice automatically.</p>
        <button class="primary">Send for approval</button>
      </form></details>` : ''}
  </section>`;
}

router.post('/jobs/:id/variations', requireRole('admin', 'builder'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayRaise(req.user, job) || !VAR_STAGES.includes(job.status)) return notFound(req, res);
  const description = String(req.body.description || '').trim().slice(0, 200);
  const amount = r2(N(req.body.amount));
  if (!description || amount < 0) return res.redirect(`/jobs/${job.id}?error=${encodeURIComponent('Describe the extra work and give a price.')}#variations`);
  const { rows } = await query('INSERT INTO variations (job_id, description, reason, amount_net, created_by) VALUES ($1, $2, $3, $4, $5) RETURNING id',
    [job.id, description, String(req.body.reason || '').trim().slice(0, 1000) || null, amount, req.user.id]);
  await query("INSERT INTO job_status_history (job_id, from_status, to_status, changed_by, note) VALUES ($1, $2, $2, $3, $4)",
    [job.id, job.status, req.user.id, `Extra work priced: ${description} (${money(amount)} + VAT)`]);
  // Email the customer.
  const tpl = (await query("SELECT * FROM email_templates WHERE status = 'variation_raised' AND enabled")).rows[0];
  if (tpl) {
    const s = await settings();
    const data = await jobVars(job.id, job.status, baseUrlOf(req));
    const vars = { ...data.vars, variation_description: description, variation_total: money(r2(amount * (1 + (s.vat_registered ? N(s.vat_rate) : 0) / 100))) + (s.vat_registered ? ' including VAT' : '') };
    await sendEmail({ to: data.job.customer_email, subject: fill(tpl.subject, vars), body: fill(tpl.body, vars), jobId: job.id });
  }
  res.redirect(`/jobs/${job.id}?updated=1#variations`);
  return rows;
}));

async function respondVariation(req, res, to) {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const v = (await query("SELECT * FROM variations WHERE id = $1 AND job_id = $2 AND status = 'pending'", [Number(req.params.vid) || 0, job.id])).rows[0];
  if (!v) return res.redirect(`/jobs/${job.id}#variations`);
  const isCustomer = req.user.role === 'customer';
  if (to === 'withdrawn' && (isCustomer || !mayRaise(req.user, job))) return notFound(req, res);
  if (to === 'approved' && !isCustomer && req.user.role !== 'admin') return notFound(req, res);
  const name = isCustomer && to === 'approved' ? String(req.body.signed_name || '').trim().slice(0, 120) : null;
  if (isCustomer && to === 'approved' && (!name || name.length < 3)) return res.redirect(`/jobs/${job.id}?error=${encodeURIComponent('Type your name to approve the extra work.')}#variations`);
  const note = String(req.body.note || '').trim().slice(0, 500) || (!isCustomer && to === 'approved' ? 'Customer agreed by phone' : null);
  await query('UPDATE variations SET status = $1, responded_at = now(), responded_by = $2, signed_name = $3, response_note = $4 WHERE id = $5',
    [to, req.user.id, name, note, v.id]);
  await query("INSERT INTO job_status_history (job_id, from_status, to_status, changed_by, note) VALUES ($1, $2, $2, $3, $4)",
    [job.id, job.status, req.user.id, `Extra work ${to}: ${v.description}${name ? ` (signed ${name})` : ''}`]);
  if (isCustomer) {
    await notifyOffice(`Extra work ${to}: ${job.title} (${ref(job.id)})`,
      `${job.customer_name} has ${to} the extra work "${v.description}" (${money(v.amount_net)} + VAT).${note ? `\nTheir note: ${note}` : ''}\n\n${baseUrlOf(req)}/jobs/${job.id}#variations`, job.id);
  }
  res.redirect(`/jobs/${job.id}?updated=1#variations`);
}
router.post('/jobs/:id/variations/:vid/approve', requireLogin, wrap((req, res) => respondVariation(req, res, 'approved')));
router.post('/jobs/:id/variations/:vid/decline', requireLogin, wrap((req, res) => {
  if (req.user.role !== 'customer') return res.redirect(`/jobs/${req.params.id}#variations`);
  return respondVariation(req, res, 'declined');
}));
router.post('/jobs/:id/variations/:vid/withdraw', requireRole('admin', 'builder'), wrap((req, res) => respondVariation(req, res, 'withdrawn')));

// Approved extras not yet on an invoice, as invoice lines.
async function approvedExtras(jobId) {
  return (await query("SELECT * FROM variations WHERE job_id = $1 AND status = 'approved' AND invoice_id IS NULL ORDER BY id", [jobId])).rows;
}

module.exports = { router, contractPanel, variationsPanel, approvedExtras, acceptedQuote, termsFor, CANCEL_DAYS };
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
      <a class="button" href="/jobs/${job.id}/quotes/${q.id}/contract" target="_blank" rel="noopener">Contract and terms</a>
      <a class="button" href="/jobs/${job.id}/quotes/${q.id}/pdf" target="_blank" rel="noopener">View or print</a>
      <a class="button" href="/jobs/${job.id}/quotes/${q.id}/pdf?download=1">Download PDF</a>
    </div>
    ${canRespond && !expired ? `<div class="respond">
      ${user.role === 'admin'
        ? `<form method="post" action="/jobs/${job.id}/quotes/${q.id}/accept" class="inline"><button class="primary">Mark as accepted</button></form>`
        : `<a class="button primary" href="/jobs/${job.id}/quotes/${q.id}/accept">Review and accept</a>`}
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
      `INSERT INTO quotes (job_id, layout, scope, customer_note, lines, net, vat_rate, vat, total, deposit_pct, deposit, valid_until, created_by, terms, consumer)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
         (SELECT customer_type <> 'business' FROM users WHERE id = (SELECT customer_id FROM jobs WHERE id = $1))) RETURNING id`,
      [job.id, layout, String(req.body.scope || '').trim().slice(0, 4000) || null, String(req.body.customer_note || '').trim().slice(0, 2000) || null,
        JSON.stringify(lines), net, vatRate, vat, total, N(s.deposit_pct), deposit, valid, req.user.id, require('./contracts').termsFor(s)]);
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
    if (accept) {
      // Accepted by phone or in person: home customers still get the 14-day cancellation period.
      await client.query(
        `UPDATE quotes SET consumer = (SELECT customer_type <> 'business' FROM users WHERE id = $2),
           cancel_until = CASE WHEN (SELECT customer_type <> 'business' FROM users WHERE id = $2) THEN (now() AT TIME ZONE 'Europe/London')::date + 14 END,
           early_start = false WHERE id = $1`, [q.id, job.customer_id]);
    }
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

cat > src/routes/workflow.js <<'HANDYTRIO_EOF'
// Everything after a quote is accepted: deposit, parts, scheduling, the builder's route,
// completion, the final invoice and payments (recorded by the office or paid online with Stripe).
const express = require('express');
const { pool, query } = require('../db');
const { esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day, when, ukDate, addDays } = require('../format');
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
        ${await (async () => { const ex = await require('./contracts').approvedExtras(job.id); return ex.length ? `<p>Plus ${ex.length} approved extra${ex.length === 1 ? '' : 's'} (${m(ex.reduce((a, v) => a + N(v.amount_net), 0))} before VAT), added automatically.</p>` : ''; })()}
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
  const contract = await require('./contracts').acceptedQuote(job.id);
  if (contract && contract.consumer && !contract.early_start && contract.cancel_until && start <= ukDate(contract.cancel_until) && req.body.override !== 'on') {
    return errorBack(res, job, `This home customer can cancel until ${day(contract.cancel_until)} and chose not to start before then. Book from ${day(addDays(ukDate(contract.cancel_until), 1))}, or tick “Book anyway” if they’ve since asked you to start sooner.`);
  }
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
  const extrasApproved = await require('./contracts').approvedExtras(job.id);
  for (const v of extrasApproved) lines.push({ category: 'other', description: `Agreed extra: ${v.description}`, qty: 1, unit: '', unit_price: N(v.amount_net), extra: true });
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
    const created = await client.query(
      `INSERT INTO invoices (job_id, kind, quote_id, layout, lines, net, vat_rate, vat, total, less_paid, amount_due, due_date, note, created_by)
       VALUES ($1, 'final', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) RETURNING id`,
      [job.id, q.id, q.layout, JSON.stringify(lines), net, vatRate, vat, total, r2(paid), due, dueDate,
        String(req.body.note || '').trim().slice(0, 1000) || null, req.user.id]);
    if (extrasApproved.length) await client.query('UPDATE variations SET invoice_id = $1 WHERE id = ANY($2)', [created.rows[0].id, extrasApproved.map((v) => v.id)]);
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
const contracts = require('./contracts');

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
  ${await contracts.contractPanel(job, user)}
  ${await contracts.variationsPanel(job, user)}
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
    ${v.role === 'customer' ? `<label>Customer type<select name="customer_type">
      <option value="home" ${v.customer_type !== 'business' ? 'selected' : ''}>Home (14-day cancellation rights apply)</option>
      <option value="business" ${v.customer_type === 'business' ? 'selected' : ''}>Business or landlord</option></select></label>` : ''}
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
    customer_type: body.customer_type === 'business' ? 'business' : 'home',
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
    if (v.role === 'customer') await query('UPDATE users SET customer_type = $1 WHERE id = $2', [v.customer_type, id]);
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
  <p class="fieldlabel">Who is the work for?</p>
  <label class="check"><input type="radio" name="customer_type" value="home" ${v.customer_type !== 'business' ? 'checked' : ''}> My own home</label>
  <label class="check"><input type="radio" name="customer_type" value="business" ${v.customer_type === 'business' ? 'checked' : ''}> A business, or a property I let out</label>
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
  v.customer_type = req.body.customer_type === 'business' ? 'business' : 'home';
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
      `INSERT INTO users (role, name, email, phone, address_line, town, postcode, password_hash, privacy_accepted_at, customer_type)
       VALUES ('customer', $1, $2, $3, $4, $5, $6, $7, now(), $8) RETURNING id`,
      [v.name, v.email, v.phone || null, v.address_line || null, v.town || null, v.postcode || null, hash, v.customer_type]
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
const termsDefault = require('../terms-default');
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
  ['Contracts', [
    ['company_number', 'Company number (if a limited company)', 'text'],
    ['vat_number', 'VAT number', 'text'],
    ['guarantee_months', 'Workmanship guarantee (months)', 'int', '1'],
    ['contract_terms', 'Terms and conditions customers sign (review these, ideally with a solicitor)', 'textarea'],
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
      ? `<label>${esc(lbl)}<textarea name="${key}" rows="${key === 'privacy_notice' || key === 'contract_terms' ? 16 : 3}" maxlength="10000">${esc(s[key])}</textarea></label>`
      : `<label>${esc(lbl)}<input name="${key}" value="${esc(s[key])}" ${type === 'text' ? '' : `type="number" min="0" step="${step}" required`}></label>`
    ).join('')}
  </fieldset>`).join('');
  return `<form method="post" action="/admin/settings" class="settings">${groups}<button class="primary">Save settings</button></form>`;
}

router.get('/admin/settings', requireRole('admin'), wrap(async (req, res) => {
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  if (!s.privacy_notice) s.privacy_notice = privacyDefault(s);
  if (!s.contract_terms) s.contract_terms = termsDefault(s);
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
const ORDER = [...STATUSES.map(([k]) => k), 'inspection_cancelled', 'cert_issued', 'cert_due', 'review_request', 'variation_raised'];
const nameOf = (k) => ({ cert_issued: 'Certificate issued (PDF attached)', inspection_cancelled: 'Inspection cancelled', cert_due: 'Renewal reminder', review_request: 'Review request', variation_raised: 'Extra work needs approval' }[k] || label(k));

const sample = {
  first_name: 'Sam', customer_name: 'Sam Jones', job_ref: 'HT-00042', job_title: 'Hang an internal door',
  stage: 'Quote sent', variation_description: 'Replace rotten joist under the bathroom floor', variation_total: '£180.00 including VAT', due_date: '14 Mar 2027', address: '12 High Street, CF10 1AA', landlord_note: ' and keeps you legal as a landlord', book_link: 'https://example.com/rebook/7', review_link: 'https://g.page/r/your-business/review', inspection_time: 'Tuesday 14 January at 10:00 am', booked_dates: '20 Jan 2027 to 22 Jan 2027', cert_name: 'Landlord Gas Safety Record', cert_number: 'GSR-00007', price_guide: '£215.00 to £295.00 including VAT', job_link: 'https://example.com/jobs/42',
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

/* Contracts and variations */
.signform { max-width: 760px; }
.termsbox { max-height: 320px; overflow-y: auto; background: var(--sunken); border: 1px solid var(--line); border-radius: 8px; padding: .9rem 1rem; font-size: .88rem; line-height: 1.6; }
.signform .issue, .panel.issue { border-top: 3px solid var(--brand); }
.signform label.check { align-items: flex-start; }
.signform label.check input { margin-top: .25rem; }
li.variation { display: block; }
li.variation p { margin: .25rem 0; }
HANDYTRIO_EOF

echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "Contracts installed. The app restarts by itself; otherwise run: npm run dev"
