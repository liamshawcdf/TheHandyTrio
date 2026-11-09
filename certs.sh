#!/usr/bin/env bash
# TheHandyTrio stage 6: engineer qualifications, gas and electrical certificates. Run with: bash certs.sh
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
HANDYTRIO_EOF

cat > src/certtypes.js <<'HANDYTRIO_EOF'
// Certificate types and their forms. Each field: [key, label, type, options?]
// Types: text, textarea, date, number, yn (Yes/No/N/A), pf (Pass/Fail/N/A), select (options).
// Groups repeat (appliances, observations, circuits, items). "table" groups print as a table on the PDF.

const YN = ['Yes', 'No', 'N/A'];
const PF = ['Pass', 'Fail', 'N/A'];
const FLUES = ['Room sealed', 'Open flue', 'Flueless', 'Balanced flue', 'Fanned flue'];
const EARTHING = ['TN-S', 'TN-C-S', 'TT', 'IT'];

const QUAL_KINDS = {
  gas: { label: 'Gas Safe registration', scheme: 'Gas Safe Register', categoriesHint: 'e.g. CCN1, CENWAT, HTR1, CKR1' },
  electrical: { label: 'Electrical competent person scheme', scheme: 'NICEIC', categoriesHint: 'e.g. Domestic Installer, 18th Edition, 2391' },
  pat: { label: 'PAT testing', scheme: 'City & Guilds 2377', categoriesHint: 'e.g. 2377-77' },
};

const TYPES = {
  gas_safety: {
    name: 'Landlord Gas Safety Record', prefix: 'GSR', requires: ['gas'], nextDueMonths: 12,
    sections: [
      { title: 'Landlord or agent', fields: [
        ['landlord_name', 'Landlord or agent name', 'text'],
        ['landlord_address', 'Landlord or agent address', 'textarea'],
        ['tenant_name', 'Tenant or occupier', 'text'],
      ] },
      { title: 'Appliances', group: 'appliances', blank: 1, itemLabel: 'Appliance', fields: [
        ['location', 'Location', 'text'],
        ['type', 'Appliance type', 'select', ['Boiler', 'Gas fire', 'Hob', 'Cooker', 'Water heater', 'Warm air unit', 'Other']],
        ['make', 'Make', 'text'],
        ['model', 'Model', 'text'],
        ['flue', 'Flue type', 'select', FLUES],
        ['landlords', 'Landlord’s appliance', 'yn'],
        ['inspected', 'Appliance inspected', 'yn'],
        ['pressure', 'Operating pressure (mbar) or heat input (kW)', 'text'],
        ['safety_device', 'Safety device correct operation', 'pf'],
        ['ventilation', 'Ventilation satisfactory', 'pf'],
        ['flue_visual', 'Visual condition of flue and termination', 'pf'],
        ['flue_test', 'Flue performance tests', 'pf'],
        ['co_ppm', 'Combustion CO (ppm)', 'number'],
        ['co2_pct', 'Combustion CO2 (%)', 'number'],
        ['ratio', 'CO/CO2 ratio', 'number'],
        ['serviced', 'Appliance serviced', 'yn'],
        ['safe', 'Appliance safe to use', 'yn'],
      ] },
      { title: 'Installation checks', fields: [
        ['tightness', 'Gas tightness test', 'pf'],
        ['pipework', 'Visual inspection of installation pipework', 'pf'],
        ['ecv', 'Emergency control valve accessible', 'yn'],
        ['bonding', 'Protective equipotential bonding satisfactory', 'yn'],
        ['co_alarm', 'Carbon monoxide alarm fitted and tested', 'yn'],
      ] },
      { title: 'Defects and action', fields: [
        ['defects', 'Defects identified', 'textarea'],
        ['remedial', 'Remedial action taken', 'textarea'],
        ['warning_notice', 'Warning notice issued', 'yn'],
      ] },
    ],
    outcome: (d) => ((d.appliances || []).some((a) => a.safe === 'No') || d.tightness === 'Fail' ? 'Unsafe items found' : 'Appliances safe to use'),
    bad: (o) => o.startsWith('Unsafe'),
  },

  boiler_service: {
    name: 'Boiler Service Record', prefix: 'BSR', requires: ['gas'], nextDueMonths: 12,
    sections: [
      { title: 'Appliance', fields: [
        ['make', 'Make', 'text'], ['model', 'Model', 'text'], ['serial', 'Serial number', 'text'], ['location', 'Location', 'text'],
        ['type', 'Boiler type', 'select', ['Combi', 'System', 'Regular (heat only)', 'Back boiler', 'Other']],
        ['fuel', 'Fuel', 'select', ['Natural gas', 'LPG']],
        ['flue', 'Flue type', 'select', FLUES],
      ] },
      { title: 'Readings', fields: [
        ['gas_rate', 'Gas rate (m³/h or kW)', 'text'], ['op_pressure', 'Operating pressure (mbar)', 'number'],
        ['burner_pressure', 'Burner pressure (mbar)', 'number'],
        ['co_high', 'CO high fire (ppm)', 'number'], ['co2_high', 'CO2 high fire (%)', 'number'], ['ratio_high', 'Ratio high fire', 'number'],
        ['co_low', 'CO low fire (ppm)', 'number'], ['co2_low', 'CO2 low fire (%)', 'number'], ['ratio_low', 'Ratio low fire', 'number'],
        ['system_pressure', 'System pressure (bar)', 'number'], ['expansion', 'Expansion vessel charge (bar)', 'number'],
      ] },
      { title: 'Checks', fields: [
        ['heat_exchanger', 'Heat exchanger', 'pf'], ['burner', 'Burner and injectors', 'pf'], ['ignition', 'Ignition', 'pf'],
        ['flame', 'Flame picture', 'pf'], ['seals', 'Case and seals', 'pf'], ['condensate', 'Condensate trap and pipe', 'pf'],
        ['safety_devices', 'Safety devices', 'pf'], ['flue_check', 'Flue route and termination', 'pf'],
        ['ventilation', 'Ventilation', 'pf'], ['controls', 'Controls and thermostats', 'pf'], ['tightness', 'Gas tightness', 'pf'],
      ] },
      { title: 'Work and advice', fields: [
        ['work_done', 'Work carried out', 'textarea'], ['parts', 'Parts fitted', 'textarea'],
        ['recommendations', 'Recommendations', 'textarea'], ['safe', 'Appliance safe to use', 'yn'],
      ] },
    ],
    outcome: (d) => (d.safe === 'No' ? 'Not safe to use' : 'Serviced, safe to use'),
    bad: (o) => o.startsWith('Not'),
  },

  warning_notice: {
    name: 'Gas Warning Notice', prefix: 'GWN', requires: ['gas'], nextDueMonths: 0,
    sections: [
      { title: 'Unsafe situation', fields: [
        ['location', 'Location', 'text'], ['appliance', 'Appliance or part of installation', 'text'], ['make_model', 'Make and model', 'text'],
        ['classification', 'Classification', 'select', ['Immediately Dangerous (ID)', 'At Risk (AR)']],
        ['fault', 'Details of the fault', 'textarea'],
        ['action', 'Action taken', 'select', ['Turned off and labelled', 'Disconnected and labelled', 'Turned off, customer refused disconnection', 'Advised only']],
        ['customer_refused', 'Customer refused permission to make safe', 'yn'],
        ['gas_emergency', 'Gas Emergency Service informed', 'yn'],
        ['riddor', 'Reportable under RIDDOR', 'yn'],
        ['customer_informed', 'Responsible person informed and given this notice', 'yn'],
      ] },
    ],
    outcome: (d) => d.classification || 'Warning notice',
    bad: () => true,
  },

  eicr: {
    name: 'Electrical Installation Condition Report', prefix: 'EICR', requires: ['electrical'], nextDueField: 'next_inspection',
    sections: [
      { title: 'Report details', fields: [
        ['client_name', 'Person ordering the report', 'text'], ['occupier', 'Occupier', 'text'],
        ['purpose', 'Purpose of the report', 'textarea'], ['extent', 'Extent of the installation covered', 'textarea'],
        ['limitations', 'Agreed limitations', 'textarea'], ['wiring_age', 'Estimated age of wiring (years)', 'number'],
        ['alterations', 'Evidence of additions or alterations', 'yn'], ['records', 'Installation records available', 'yn'],
      ] },
      { title: 'Supply and earthing', fields: [
        ['earthing', 'Earthing arrangement', 'select', EARTHING], ['phases', 'Supply', 'select', ['Single phase', 'Three phase']],
        ['voltage', 'Nominal voltage (V)', 'number'], ['ze', 'External loop impedance Ze (Ω)', 'number'],
        ['pfc', 'Prospective fault current (kA)', 'number'], ['main_switch', 'Main switch rating (A)', 'number'],
        ['main_earth', 'Main earthing conductor (mm²)', 'number'], ['bonding', 'Main bonding conductors (mm²)', 'number'],
        ['electrode', 'Earth electrode resistance (Ω)', 'number'],
      ] },
      { title: 'Observations', group: 'observations', blank: 3, table: true, itemLabel: 'Observation', fields: [
        ['ref', 'Ref', 'text'], ['observation', 'Observation', 'textarea'], ['location', 'Location', 'text'],
        ['code', 'Code', 'select', ['C1', 'C2', 'C3', 'FI']],
      ] },
      { title: 'Circuit test results', group: 'circuits', blank: 3, table: true, itemLabel: 'Circuit', fields: [
        ['no', 'Circuit', 'text'], ['description', 'Description', 'text'], ['ocpd', 'Device type/rating', 'text'],
        ['r1r2', 'R1+R2 (Ω)', 'number'], ['ir', 'Insulation (MΩ)', 'number'], ['zs', 'Zs (Ω)', 'number'],
        ['rcd', 'RCD (ms)', 'number'], ['polarity', 'Polarity', 'pf'], ['result', 'Result', 'pf'],
      ] },
      { title: 'Summary', fields: [
        ['condition', 'General condition of the installation', 'textarea'],
        ['next_inspection', 'Recommended next inspection', 'date'],
      ] },
    ],
    outcome: (d) => ((d.observations || []).some((o) => ['C1', 'C2', 'FI'].includes(o.code)) ? 'Unsatisfactory' : 'Satisfactory'),
    bad: (o) => o === 'Unsatisfactory',
    codesNote: 'C1 Danger present, immediate action required. C2 Potentially dangerous, urgent action required. C3 Improvement recommended. FI Further investigation required without delay.',
  },

  minor_works: {
    name: 'Minor Electrical Installation Works Certificate', prefix: 'MW', requires: ['electrical'], nextDueMonths: 0,
    sections: [
      { title: 'The work', fields: [
        ['description', 'Description of the minor works', 'textarea'], ['location', 'Location', 'text'],
        ['date_complete', 'Date completed', 'date'], ['departures', 'Departures from BS 7671', 'textarea'],
      ] },
      { title: 'Circuit', fields: [
        ['earthing', 'Earthing arrangement', 'select', EARTHING], ['circuit', 'Circuit affected', 'text'],
        ['ocpd', 'Protective device type and rating', 'text'], ['rcd', 'RCD type and rating', 'text'],
      ] },
      { title: 'Test results', fields: [
        ['r1r2', 'Continuity R1+R2 (Ω)', 'number'], ['ir', 'Insulation resistance (MΩ)', 'number'],
        ['polarity', 'Polarity', 'pf'], ['zs', 'Earth fault loop impedance Zs (Ω)', 'number'],
        ['rcd_time', 'RCD operating time (ms)', 'number'], ['rcd_test', 'RCD test button operation', 'pf'],
        ['comments', 'Comments on the existing installation', 'textarea'],
      ] },
    ],
    outcome: (d) => (d.polarity === 'Fail' || d.rcd_test === 'Fail' ? 'Not satisfactory' : 'Completed and tested'),
    bad: (o) => o.startsWith('Not'),
  },

  pat: {
    name: 'Portable Appliance Test Record', prefix: 'PAT', requires: ['pat', 'electrical'], nextDueFromItems: 'retest',
    sections: [
      { title: 'Site', fields: [['client_name', 'Client', 'text'], ['site', 'Site or premises', 'text']] },
      { title: 'Appliances tested', group: 'items', blank: 5, table: true, itemLabel: 'Appliance', fields: [
        ['asset', 'Asset ID', 'text'], ['description', 'Appliance', 'text'], ['location', 'Location', 'text'],
        ['class', 'Class', 'select', ['Class I', 'Class II', 'Class III']], ['visual', 'Visual', 'pf'],
        ['earth', 'Earth (Ω)', 'number'], ['insulation', 'Insulation (MΩ)', 'number'], ['polarity', 'Polarity', 'pf'],
        ['result', 'Result', 'pf'], ['retest', 'Retest (months)', 'select', ['3', '6', '12', '24', '36', '48']],
      ] },
    ],
    outcome: (d) => {
      const items = d.items || [];
      const fail = items.filter((i) => i.result === 'Fail').length;
      return `${items.length - fail} passed, ${fail} failed`;
    },
    bad: (o) => !/ 0 failed$/.test(o),
  },
};

const typeOptions = (t) => (t[2] === 'yn' ? YN : t[2] === 'pf' ? PF : t[3] || []);

module.exports = { TYPES, QUAL_KINDS, typeOptions };
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
    const meta = [['Number', number], ['Issued', fmtDate(cert.issued_at) || 'Draft'], ['Next due', fmtDate(cert.next_due) || 'n/a'], ['Job', job.ref]];
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
    const y1 = party(L, 'Installation address', [customer.name, job.address_line, job.town, job.postcode]);
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

async function sendEmail({ to, subject, body, jobId = null, attachments = [] }) {
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
    [jobId, to || null, subject, body + (attachments.length ? `\n\n[Attached: ${attachments.map((a) => a.filename).join(', ')}]` : ''), status, error]);
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

const PLACEHOLDERS = ['cert_name', 'cert_number', 'first_name', 'customer_name', 'job_ref', 'job_title', 'stage', 'price_guide', 'job_link', 'business_name'];

module.exports = { jobVars, notifyStageChange, notifyOffice, sendEmail, fill, emailReady, PLACEHOLDERS };
HANDYTRIO_EOF

cat > src/jobs-shared.js <<'HANDYTRIO_EOF'
// Shared job helpers: loading a job the current person may see, and recording stage changes.
const { query } = require('./db');
const { page } = require('./layout');

const JOB_SELECT = `SELECT j.*, c.name AS customer_name, c.phone AS customer_phone, c.email AS customer_email,
    b.name AS builder_name
  FROM jobs j JOIN users c ON c.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id`;

function canSee(user, job) {
  return user.role === 'admin'
    || (user.role === 'customer' && job.customer_id === user.id)
    || (user.role === 'builder' && (job.assigned_builder_id === user.id || job.on_team === true));
}

async function loadJob(req) {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id < 1) return null;
  const { rows } = await query(`${JOB_SELECT} WHERE j.id = $1`, [id]);
  const job = rows[0];
  if (job && req.user.role === 'builder' && job.assigned_builder_id !== req.user.id) {
    job.on_team = (await query('SELECT 1 FROM job_team WHERE job_id = $1 AND user_id = $2', [job.id, req.user.id])).rows.length > 0;
  }
  return job && canSee(req.user, job) ? job : null;
}

const notFound = (req, res) =>
  res.status(404).send(page({ title: 'Job not found', user: req.user, body: '<p>That job doesn’t exist or isn’t yours to view.</p><p><a href="/dashboard">Back to your dashboard</a></p>' }));

async function setStatus(client, jobId, from, to, userId, note) {
  await client.query('UPDATE jobs SET status = $1, updated_at = now() WHERE id = $2', [to, jobId]);
  await client.query(
    'INSERT INTO job_status_history (job_id, from_status, to_status, changed_by, note) VALUES ($1, $2, $3, $4, $5)',
    [jobId, from, to, userId, note || null]
  );
}

const baseUrlOf = (req) => (process.env.APP_URL || `${req.protocol}://${req.get('host')}`).replace(/\/$/, '');

module.exports = { JOB_SELECT, canSee, loadJob, notFound, setStatus, baseUrlOf };
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

cat > src/layout.js <<'HANDYTRIO_EOF'
const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin' };

function nav(user) {
  if (!user) return '<a href="/login">Log in</a><a href="/register">Create account</a>';
  const links = ['<a href="/dashboard">Dashboard</a>'];
  if (user.role !== 'customer') links.push(`<a href="/jobs">${user.role === 'admin' ? 'All jobs' : 'My jobs'}</a>`);
  if (user.role === 'admin') {
    links.push('<a href="/admin/certificates">Certificates</a>', '<a href="/admin/templates">Pricing</a>', '<a href="/admin/users">People</a>', '<a href="/admin/emails">Emails</a>', '<a href="/admin/settings">Settings</a>');
  }
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
</body>
</html>`;
}

module.exports = { esc, page, ROLE_LABELS };
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

  const sections = t.sections.map((sec) => {
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
  const where = ["c.status <> 'draft'"];
  if (type) { params.push(type); where.push(`c.type = $${params.length}`); }
  if (due) where.push("c.status = 'issued' AND c.next_due <= current_date + 60");
  const rows = (await query(
    `SELECT c.*, j.title, j.postcode, cu.name AS customer_name FROM certificates c JOIN jobs j ON j.id = c.job_id JOIN users cu ON cu.id = j.customer_id
     WHERE ${where.join(' AND ')} ORDER BY ${due ? 'c.next_due' : 'c.issued_at DESC'} LIMIT 300`, params)).rows;
  const body = `<form method="get" action="/admin/certificates" class="filters">
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

module.exports = { router, certificatesPanel, teamPanel, currentQuals };
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
  const builders = isAdmin ? (await query("SELECT id, name FROM users WHERE role = 'builder' ORDER BY name")).rows : [];

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
      `${JOB_SELECT} WHERE (j.assigned_builder_id = $1 OR j.id IN (SELECT job_id FROM job_team WHERE user_id = $1)) AND j.status <> ALL($2) ORDER BY coalesce(j.scheduled_start, j.preferred_start) NULLS LAST, j.created_at`,
      [user.id, CLOSED]
    );
    const clocked = (await query(
      `SELECT t.job_id, t.started_at, j.title FROM job_time_entries t JOIN jobs j ON j.id = t.job_id
       WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
    const myQuals = (await query(
      `SELECT kind, expires FROM staff_qualifications WHERE user_id = $1 AND expires <= current_date + 30 ORDER BY expires`, [user.id])).rows;
    const qualWarn = myQuals.map((q) => `<div class="error">Your ${esc(q.kind === 'gas' ? 'Gas Safe' : q.kind === 'pat' ? 'PAT' : 'electrical scheme')} qualification ${new Date(q.expires) < new Date(new Date().toDateString()) ? 'has expired' : 'expires'} on ${day(q.expires)}. Send the office your renewal.</div>`).join('');
    const body = `${qualWarn}${clocked ? `<div class="notice">You’re clocked on to <a href="/jobs/${clocked.job_id}#time">${esc(clocked.title)}</a> since ${new Date(clocked.started_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}.</div>` : ''}
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
  const todoItems = [
    ...quals.map((q) => `<li><a href="/admin/users/${q.user_id}"><strong>${new Date(q.expires) < new Date(new Date().toDateString()) ? 'Qualification expired' : 'Qualification expiring'}</strong>: ${esc(q.name)}, ${esc(q.kind === 'gas' ? 'Gas Safe' : q.kind === 'pat' ? 'PAT' : 'electrical scheme')}, ${day(q.expires)}</a></li>`),
    ...(certsDue ? [`<li><a href="/admin/certificates?due=1"><strong>Certificates due for renewal</strong>: ${certsDue} in the next 30 days or overdue</a></li>`] : []),
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
      `INSERT INTO users (role, name, email, phone, address_line, town, postcode, password_hash)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [v.role, v.name, v.email, v.phone || null, v.address_line || null, v.town || null, v.postcode || null, await bcrypt.hash(v.password, 12)]);
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
      `UPDATE users SET name = $1, email = $2, phone = $3, role = $4, address_line = $5, town = $6, postcode = $7 WHERE id = $8`,
      [v.name, v.email, v.phone || null, v.role, v.address_line || null, v.town || null, v.postcode || null, id]);
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
const ORDER = [...STATUSES.map(([k]) => k), 'cert_issued'];
const nameOf = (k) => (k === 'cert_issued' ? 'Certificate issued (PDF attached)' : label(k));

const sample = {
  first_name: 'Sam', customer_name: 'Sam Jones', job_ref: 'HT-00042', job_title: 'Hang an internal door',
  stage: 'Quote sent', cert_name: 'Landlord Gas Safety Record', cert_number: 'GSR-00007', price_guide: '£215.00 to £295.00 including VAT', job_link: 'https://example.com/jobs/42',
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
HANDYTRIO_EOF

echo "Updating database..."
node scripts/migrate.js
touch src/server.js
echo ""
echo "Certificates installed. The app restarts by itself; otherwise run: npm run dev"
