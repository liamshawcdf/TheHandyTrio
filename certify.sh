#!/usr/bin/env bash
# TheHandyTrio: Certify, private certificates for engineers. Run with: bash certify.sh
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
HANDYTRIO_EOF

cat > src/certpdf.js <<'HANDYTRIO_EOF'
// Builds a certificate PDF in memory, so it can be downloaded or attached to an email.
const PDFDocument = require('pdfkit');
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
    doc.rect(0, 0, W, 78).fill('#24414f');
    doc.rect(0, 78, W, 5).fill('#f2c300');
    doc.fillColor('#ffffff').font('Helvetica-Bold').fontSize(18).text(s.business_name, L, 22, { width: 280 });
    const contact = [s.business_address, s.business_phone, s.business_email].filter(Boolean).join('\n');
    if (contact) doc.font('Helvetica').fontSize(8).text(contact, R - 220, 20, { width: 220, align: 'right' });

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

cat > src/layout.js <<'HANDYTRIO_EOF'
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
  console.log(`TheHandyTrio running on port ${port}`);
  startScheduler();
});
HANDYTRIO_EOF

cat > src/routes/certify.js <<'HANDYTRIO_EOF'
// "Certify": engineers' own private certificates for side jobs.
// Not linked to any company job, not in company reports or reminders, and branded with
// the engineer's own trading name rather than the business's. Only the engineer can see them.
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { day } = require('../format');
const { sendEmail } = require('../notify');
const { TYPES } = require('../certtypes');
const { buildCertificatePdf } = require('../certpdf');
const { currentQuals, qualFor, certFormSections, readForm, addMonths } = require('./certs');

const router = express.Router();
const staff = requireRole('admin', 'builder');
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const pcertNo = (c) => `${TYPES[c.type].prefix}-P${String(c.id).padStart(5, '0')}`;
const clean = (v, n = 200) => String(v ?? '').trim().slice(0, n);

async function mine(req) {
  const c = (await query('SELECT * FROM certificates WHERE id = $1 AND private AND engineer_id = $2', [Number(req.params.cid) || 0, req.user.id])).rows[0];
  return c && TYPES[c.type] ? c : null;
}

function pdfParts(c, me) {
  return {
    cert: c,
    number: pcertNo(c),
    job: { address_line: c.cust_address, town: '', postcode: c.cust_postcode, ref: '' },
    customer: { name: c.cust_name, phone: c.cust_phone, email: c.cust_email },
    s: { business_name: c.trading_name || me.private_trading_name || me.name, business_address: '', business_phone: c.trading_contact || me.private_trading_contact || '', business_email: '' },
  };
}

router.get('/certify', staff, wrap(async (req, res) => {
  const quals = await currentQuals(req.user.id);
  const allowed = Object.entries(TYPES).filter(([k]) => qualFor(k, quals));
  const list = (await query('SELECT * FROM certificates WHERE private AND engineer_id = $1 ORDER BY id DESC LIMIT 200', [req.user.id])).rows;
  const body = `<p class="lead">Certificates for your own private work, outside ${'the business'}. They carry your own trading name, not the company’s, and only you can see them.</p>
    ${allowed.length ? `<form method="post" action="/certify" class="panel inline-form">
        <label>New certificate<select name="type">${allowed.map(([k, t]) => `<option value="${k}">${esc(t.name)}</option>`).join('')}</select></label>
        <button class="primary">Certify</button>
      </form>`
      : '<div class="error">You need an in-date Gas Safe, electrical or PAT qualification on your profile to certify. Ask the office to add it.</div>'}
    <h2>Your private certificates</h2>
    ${list.length ? `<ul class="certlist">${list.map((c) => `<li>
      <a href="/certify/${c.id}"><strong>${esc(TYPES[c.type] ? TYPES[c.type].name : c.type)}</strong> ${pcertNo(c)}</a>
      ${c.status === 'draft' ? '<span class="tag">Draft</span>' : `<span class="tag ${TYPES[c.type].bad(c.outcome || '') ? 'urgent' : 'ok'}">${esc(c.outcome)}</span>`}
      <span class="muted">${esc(c.cust_name || 'No customer yet')}${c.cust_postcode ? `, ${esc(c.cust_postcode)}` : ''} · ${c.status === 'issued' ? `issued ${day(c.issued_at)}` : `started ${day(c.created_at)}`}${c.next_due ? `, next due ${day(c.next_due)}` : ''}</span>
      ${c.status === 'issued' ? `<a class="button small" href="/certify/${c.id}/pdf" target="_blank" rel="noopener">PDF</a>` : ''}
    </li>`).join('')}</ul>` : '<p class="empty">None yet.</p>'}`;
  res.send(page({ title: 'Certify', user: req.user, body }));
}));

router.post('/certify', staff, wrap(async (req, res) => {
  const type = String(req.body.type || '');
  if (!TYPES[type] || !qualFor(type, await currentQuals(req.user.id))) return res.redirect('/certify');
  const me = (await query('SELECT private_trading_name, private_trading_contact FROM users WHERE id = $1', [req.user.id])).rows[0];
  const { rows } = await query(
    'INSERT INTO certificates (job_id, type, engineer_id, data, private, trading_name, trading_contact) VALUES (NULL, $1, $2, $3, true, $4, $5) RETURNING id',
    [type, req.user.id, '{}', me.private_trading_name, me.private_trading_contact]);
  res.redirect(`/certify/${rows[0].id}`);
}));

router.get('/certify/:cid', staff, wrap(async (req, res) => {
  const c = await mine(req);
  if (!c) return res.redirect('/certify');
  const t = TYPES[c.type];
  if (c.status !== 'draft') {
    const body = `<p class="jobhead"><a href="/certify">Back to my certificates</a></p>
      <section class="panel quote">
        <div class="quotehead"><h2>${pcertNo(c)}</h2><span class="tag ${t.bad(c.outcome || '') ? 'urgent' : 'ok'}">${esc(c.outcome)}</span></div>
        <p>${esc(c.cust_name)}, ${esc(c.cust_address)} ${esc(c.cust_postcode)}</p>
        <p class="muted">Issued ${day(c.issued_at)}${c.next_due ? `. Next due ${day(c.next_due)}` : ''}${c.sent_to ? `. Emailed to ${esc(c.sent_to)}` : ''}</p>
        <div class="buttons">
          <a class="button primary" href="/certify/${c.id}/pdf" target="_blank" rel="noopener">View or print</a>
          <a class="button" href="/certify/${c.id}/pdf?download=1">Download PDF</a>
          <form method="post" action="/certify/${c.id}/resend" class="inline"><button class="small">Email the customer again</button></form>
        </div>
      </section>`;
    return res.send(page({ title: t.name, user: req.user, notice: req.query.issued ? 'Certificate issued and sent.' : req.query.sent ? 'Sent again.' : null, body }));
  }
  const v = (k) => esc(c[k] ?? '');
  const body = `<p class="jobhead"><a href="/certify">Back to my certificates</a> <span class="ref">${pcertNo(c)}</span> <span class="tag">Draft</span></p>
    <form method="post" action="/certify/${c.id}" class="certform">
      <fieldset class="panel"><legend>Customer</legend>
        <div class="certgrid">
          <label>Full name<input name="cust_name" value="${v('cust_name')}" maxlength="120" autocomplete="off"></label>
          <label>Address<input name="cust_address" value="${v('cust_address')}" maxlength="200" autocomplete="off"></label>
          <label>Postcode<input name="cust_postcode" value="${v('cust_postcode')}" maxlength="10" autocomplete="off"></label>
          <label>Phone<input type="tel" name="cust_phone" value="${v('cust_phone')}" maxlength="40" autocomplete="off"></label>
          <label>Email<input type="email" name="cust_email" value="${v('cust_email')}" maxlength="120" autocomplete="off"></label>
        </div>
        <p class="hint">All five are needed to issue, so the customer can be traced and sent their copy if there’s ever a safety issue.</p>
      </fieldset>
      <fieldset class="panel"><legend>Your business details on the certificate</legend>
        <div class="certgrid">
          <label>Trading name<input name="trading_name" value="${v('trading_name')}" maxlength="120" placeholder="${esc(req.user.name)}"></label>
          <label>Your contact phone or email<input name="trading_contact" value="${v('trading_contact')}" maxlength="120"></label>
        </div>
        <p class="hint">Remembered for next time.</p>
      </fieldset>
      ${certFormSections(t, c.data || {})}
      <div class="buttons"><button name="action" value="save" class="small">Save draft</button>
        <a class="button" href="/certify/${c.id}/pdf" target="_blank" rel="noopener">Preview PDF</a></div>
      <fieldset class="panel issue">
        <legend>Issue the certificate</legend>
        <p>Issuing locks the certificate and emails the PDF to the customer, with a copy to you (${esc(req.user.email)}).</p>
        <label class="check"><input type="checkbox" name="declare"> I confirm the inspection and tests recorded were carried out by me and are a true record.</label>
        <label>Your full name<input name="declaration_name" value="${esc(req.user.name)}" maxlength="120"></label>
        <button name="action" value="issue" class="primary">Issue and send</button>
      </fieldset>
      <p><button name="action" value="delete" class="small danger">Delete this draft</button></p>
    </form>`;
  res.send(page({ title: t.name, user: req.user, notice: req.query.saved ? 'Draft saved.' : null, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body }));
}));

async function emailIt(c, me) {
  const t = TYPES[c.type];
  const parts = pdfParts(c, me);
  const pdf = await buildCertificatePdf(parts);
  const from = parts.s.business_name;
  const attachments = [{ filename: `${pcertNo(c)}.pdf`, content: pdf, contentType: 'application/pdf' }];
  const body = `Hi ${c.cust_name.split(' ')[0]},\n\nPlease find attached your ${t.name}, number ${pcertNo(c)}, for ${c.cust_address}, ${c.cust_postcode}.\n\nPlease keep it somewhere safe.${c.next_due ? ` The next one is due by ${day(c.next_due)}.` : ''}\n\nThanks,\n${from}${parts.s.business_phone ? `\n${parts.s.business_phone}` : ''}`;
  const r = await sendEmail({ to: c.cust_email, subject: `Your ${t.name} (${pcertNo(c)})`, body, attachments });
  await sendEmail({ to: me.email, subject: `Your copy: ${t.name} ${pcertNo(c)} for ${c.cust_name}`, body: `Your copy of ${pcertNo(c)}, issued to ${c.cust_name}, ${c.cust_address}, ${c.cust_postcode}.`, attachments });
  await query('UPDATE certificates SET sent_to = $1, sent_at = now() WHERE id = $2', [c.cust_email, c.id]);
  return r;
}

router.post('/certify/:cid', staff, wrap(async (req, res) => {
  const c = await mine(req);
  if (!c || c.status !== 'draft') return res.redirect('/certify');
  if (req.body.action === 'delete') {
    await query("DELETE FROM certificates WHERE id = $1 AND status = 'draft' AND private", [c.id]);
    return res.redirect('/certify');
  }
  const t = TYPES[c.type];
  const f = {
    cust_name: clean(req.body.cust_name, 120), cust_address: clean(req.body.cust_address), cust_postcode: clean(req.body.cust_postcode, 10).toUpperCase(),
    cust_phone: clean(req.body.cust_phone, 40), cust_email: clean(req.body.cust_email, 120).toLowerCase(),
    trading_name: clean(req.body.trading_name, 120), trading_contact: clean(req.body.trading_contact, 120),
  };
  const data = readForm(t, req.body);
  await query(
    `UPDATE certificates SET data = $1, cust_name = $2, cust_address = $3, cust_postcode = $4, cust_phone = $5, cust_email = $6,
       trading_name = $7, trading_contact = $8, updated_at = now() WHERE id = $9`,
    [JSON.stringify(data), f.cust_name || null, f.cust_address || null, f.cust_postcode || null, f.cust_phone || null, f.cust_email || null, f.trading_name || null, f.trading_contact || null, c.id]);
  await query('UPDATE users SET private_trading_name = $1, private_trading_contact = $2 WHERE id = $3', [f.trading_name || null, f.trading_contact || null, req.user.id]);
  if (req.body.action !== 'issue') return res.redirect(`/certify/${c.id}?saved=1`);

  const qual = qualFor(c.type, await currentQuals(req.user.id));
  const name = clean(req.body.declaration_name, 120);
  let error = null;
  if (!qual) error = 'Your qualification for this certificate has expired or is missing, so it can’t be issued.';
  else if (!f.cust_name || !f.cust_address || !f.cust_postcode || !f.cust_phone || !EMAIL.test(f.cust_email)) error = 'Fill in the customer’s name, address, postcode, phone and a valid email to issue.';
  else if (req.body.declare !== 'on' || !name) error = 'Tick the declaration and type your name to issue.';
  else if (t.nextDueField && !data[t.nextDueField]) error = 'Fill in the recommended next inspection date.';
  else if (t.sections.some((sec) => ['appliances', 'items'].includes(sec.group) && !(data[sec.group] || []).length)) error = 'Add at least one appliance.';
  if (error) return res.redirect(`/certify/${c.id}?error=${encodeURIComponent(error)}`);

  let nextDue = null;
  if (t.nextDueField) nextDue = data[t.nextDueField];
  else if (t.nextDueFromItems) {
    const months = Math.min(...(data.items || []).map((i) => Number(i[t.nextDueFromItems]) || 12));
    nextDue = addMonths(Number.isFinite(months) ? months : 12);
  } else if (t.nextDueMonths) nextDue = addMonths(t.nextDueMonths);

  const updated = (await query(
    `UPDATE certificates SET status = 'issued', outcome = $1, issued_at = now(), next_due = $2, declaration_name = $3,
       engineer_name = $4, engineer_scheme = $5, engineer_number = $6, engineer_categories = $7, updated_at = now()
     WHERE id = $8 AND status = 'draft' RETURNING *`,
    [t.outcome(data), nextDue, name, req.user.name, qual.scheme, qual.number, qual.categories, c.id])).rows[0];
  if (updated) await emailIt(updated, (await query('SELECT * FROM users WHERE id = $1', [req.user.id])).rows[0]);
  res.redirect(`/certify/${c.id}?issued=1`);
}));

router.post('/certify/:cid/resend', staff, wrap(async (req, res) => {
  const c = await mine(req);
  if (c && c.status === 'issued') await emailIt(c, (await query('SELECT * FROM users WHERE id = $1', [req.user.id])).rows[0]);
  res.redirect(`/certify/${req.params.cid}?sent=1`);
}));

router.get('/certify/:cid/pdf', staff, wrap(async (req, res) => {
  const c = await mine(req);
  if (!c) return res.redirect('/certify');
  const me = (await query('SELECT * FROM users WHERE id = $1', [req.user.id])).rows[0];
  let cert = c;
  if (c.status === 'draft') {
    const q = qualFor(c.type, await currentQuals(req.user.id));
    cert = { ...c, outcome: TYPES[c.type].outcome(c.data || {}), engineer_name: me.name, engineer_scheme: q && q.scheme, engineer_number: q && q.number, engineer_categories: q && q.categories };
  }
  const pdf = await buildCertificatePdf(pdfParts(cert, me));
  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `${req.query.download ? 'attachment' : 'inline'}; filename="${pcertNo(c)}.pdf"`);
  res.send(pdf);
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
    await sendEmail({ to: s.business_email, subject: `[TheHandyTrio] Office copy: ${t.name} ${certNo(c)} (${ref(job.id)})`,
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
  const staffRows = (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows;
  const avToday = await loadAvailability(staffRows.map((b) => b.id), todayISO, todayISO);
  const notAny = staffRows.map((b) => ({ b, st: dayStatus(avToday, b.id, todayISO) })).filter((x) => x.st.state !== 'any');
  const whoOff = notAny.length ? `<p class="muted">${notAny.map((x) => `${esc(x.b.name)}: ${esc(statusLabel(x.st))}`).join(' · ')}</p>` : '';
  const todayBox = `<h2>Today</h2>${whoOff}${todays.length ? `<div class="soon">${todays.map(eventChip).join('')}</div>` : '<p class="empty">Nothing booked today.</p>'}<p><a href="/calendar">Open the calendar</a></p>`;
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

echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "Certify installed. The app restarts by itself; otherwise run: npm run dev"
