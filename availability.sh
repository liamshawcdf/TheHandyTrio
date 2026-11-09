#!/usr/bin/env bash
# TheHandyTrio: staff working hours, holidays and pay rates. Run with: bash availability.sh
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
HANDYTRIO_EOF

cat > src/availability.js <<'HANDYTRIO_EOF'
// Staff availability. Everyone is available 24/7 unless they've set working hours,
// a day off, or a holiday for that date.
const { query } = require('./db');
const { ukDate, ukTime, addDays } = require('./format');

const isoOf = (d) => (typeof d === 'string' ? d.slice(0, 10) : ukDate(d));
const validTime = (t) => /^([01]\d|2[0-3]):[0-5]\d$/.test(t || '') || t === '24:00';

async function loadAvailability(userIds, fromISO, toISO) {
  const ids = [...new Set(userIds.map(Number).filter(Boolean))];
  const out = Object.fromEntries(ids.map((id) => [id, { days: {}, off: [] }]));
  if (!ids.length) return out;
  const days = (await query(
    `SELECT user_id, to_char(date, 'YYYY-MM-DD') AS date, kind, start_time, end_time FROM staff_availability
     WHERE user_id = ANY($1) AND date BETWEEN $2::date AND $3::date`, [ids, fromISO, toISO])).rows;
  for (const d of days) out[d.user_id].days[d.date] = d;
  const off = (await query(
    `SELECT id, user_id, to_char(start_date, 'YYYY-MM-DD') AS start_date, to_char(end_date, 'YYYY-MM-DD') AS end_date, note FROM staff_time_off
     WHERE user_id = ANY($1) AND end_date >= $2::date AND start_date <= $3::date`, [ids, fromISO, toISO])).rows;
  for (const o of off) out[o.user_id].off.push(o);
  return out;
}

// What a person's day looks like: any time, set hours, a day off, or holiday.
function dayStatus(av, userId, iso) {
  const a = av[userId];
  if (!a) return { state: 'any' };
  const hol = a.off.find((o) => o.start_date <= iso && iso <= o.end_date);
  if (hol) return { state: 'holiday', note: hol.note };
  const d = a.days[iso];
  if (!d) return { state: 'any' };
  if (d.kind === 'off') return { state: 'off' };
  return { state: 'hours', start: d.start_time, end: d.end_time };
}

// Is the person working for the whole of [start, end)? Both are Date instants.
function freeBetween(av, userId, start, end) {
  const iso = ukDate(start);
  const st = dayStatus(av, userId, iso);
  if (st.state === 'any') return true;
  if (st.state !== 'hours') return false;
  const from = ukTime(iso, st.start).getTime();
  const to = st.end === '24:00' ? ukTime(addDays(iso, 1), '00:00').getTime() : ukTime(iso, st.end).getTime();
  return start.getTime() >= from && end.getTime() <= to;
}

// Dates in a range the person is on holiday or not working.
function blockedDates(av, userId, fromISO, toISO) {
  const out = [];
  for (let d = fromISO; d <= toISO; d = addDays(d, 1)) {
    const st = dayStatus(av, userId, d);
    if (st.state === 'holiday' || st.state === 'off') out.push({ date: d, state: st.state });
  }
  return out;
}

const statusLabel = (st) => (st.state === 'holiday' ? `Holiday${st.note ? `: ${st.note}` : ''}`
  : st.state === 'off' ? 'Not working' : st.state === 'hours' ? `${st.start} to ${st.end}` : '');

module.exports = { loadAvailability, dayStatus, freeBetween, blockedDates, statusLabel, validTime, isoOf };
HANDYTRIO_EOF

cat > src/layout.js <<'HANDYTRIO_EOF'
const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin' };

function nav(user) {
  if (!user) return '<a href="/login">Log in</a><a href="/register">Create account</a>';
  const links = ['<a href="/dashboard">Dashboard</a>'];
  if (user.role !== 'customer') links.push(`<a href="/jobs">${user.role === 'admin' ? 'All jobs' : 'My jobs'}</a>`, `<a href="/calendar">${user.role === 'admin' ? 'Calendar' : 'My diary'}</a>`);
  if (user.role === 'builder') links.push('<a href="/availability">My availability</a>');
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
  return (await query("SELECT id, name FROM users WHERE id = $1 AND role IN ('builder', 'admin')", [id])).rows[0] || { id: req.user.id, name: req.user.name };
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
      <label>Person<select name="user">${(await query("SELECT id, name FROM users WHERE role IN ('builder', 'admin') AND active ORDER BY name")).rows
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
    const builders = (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows;
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
  const b = builderId && (await query("SELECT id, name FROM users WHERE id = $1 AND role = 'builder' AND active", [builderId])).rows[0];
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
  if (v.role === 'builder' && v.postcode && !(await locate(v.postcode))) {
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
    <td>${u.role === 'builder' && !u.postcode ? '<span class="tag urgent">Needs postcode</span>' : esc(u.postcode)}</td>
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
HANDYTRIO_EOF

echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "Availability installed. The app restarts by itself; otherwise run: npm run dev"
