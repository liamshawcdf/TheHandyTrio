#!/usr/bin/env bash
# TheHandyTrio: getting ready to go live on Render. Run with: bash golive.sh
set -e
if [ ! -f package.json ]; then echo "Run this inside the TheHandyTrio folder"; exit 1; fi
mkdir -p src/routes scripts

cat > package.json <<'HANDYTRIO_EOF'
{
  "name": "thehandytrio",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "db": "bash scripts/db.sh",
    "migrate": "node scripts/migrate.js",
    "dev": "bash scripts/db.sh && node scripts/migrate.js && node --watch src/server.js",
    "start": "node scripts/migrate.js && node src/server.js",
    "create-admin": "node scripts/create-admin.js",
    "restore": "node scripts/restore-backup.js",
    "backup": "node scripts/make-backup.js"
  },
  "engines": {
    "node": ">=20"
  },
  "dependencies": {
    "bcryptjs": "^2.4.3",
    "connect-pg-simple": "^9.0.0",
    "dotenv": "^16.0.0",
    "express": "^4.18.0",
    "express-rate-limit": "^7.0.0",
    "express-session": "^1.17.0",
    "helmet": "^7.0.0",
    "multer": "^2.0.0",
    "nodemailer": "^6.9.0",
    "pdfkit": "^0.15.0",
    "pg": "^8.11.0"
  }
}
HANDYTRIO_EOF

cat > .gitignore <<'HANDYTRIO_EOF'
node_modules
.env
uploads
backups
HANDYTRIO_EOF

cat > render.yaml <<'HANDYTRIO_EOF'
# Render Blueprint: one web service and one database, in Frankfurt (closest region to the UK).
# Render asks for any value marked sync: false when you create the Blueprint. Leave optional ones blank for now.
services:
  - type: web
    name: thehandytrio
    runtime: node
    plan: starter
    region: frankfurt
    buildCommand: npm ci
    startCommand: npm start
    healthCheckPath: /healthz
    autoDeploy: true
    envVars:
      - key: NODE_ENV
        value: production
      - key: NODE_VERSION
        value: "22"
      - key: SESSION_SECRET
        generateValue: true
      - key: DATABASE_URL
        fromDatabase:
          name: thehandytrio-db
          property: connectionString
      - key: APP_URL
        sync: false
      - key: SMTP_HOST
        sync: false
      - key: SMTP_PORT
        sync: false
      - key: SMTP_USER
        sync: false
      - key: SMTP_PASS
        sync: false
      - key: SMTP_FROM
        sync: false
      - key: STRIPE_SECRET_KEY
        sync: false
      - key: TWILIO_ACCOUNT_SID
        sync: false
      - key: TWILIO_AUTH_TOKEN
        sync: false
      - key: TWILIO_FROM
        sync: false

databases:
  - name: thehandytrio-db
    plan: basic-256mb
    region: frankfurt
    postgresMajorVersion: "16"
HANDYTRIO_EOF

cat > src/pgconfig.js <<'HANDYTRIO_EOF'
// Database connection settings. Uses SSL for databases reached over the internet
// (like Render's external address) and plain connections for local or private ones.
// Force it either way with DATABASE_SSL=1 or DATABASE_SSL=0.
function pgConfig(url = process.env.DATABASE_URL) {
  let ssl = false;
  if (process.env.DATABASE_SSL === '1') ssl = true;
  else if (process.env.DATABASE_SSL !== '0') {
    try {
      const host = new URL(url).hostname;
      ssl = host.includes('.') && !/^(localhost|127\.0\.0\.1)$/.test(host);
    } catch (e) {
      ssl = false;
    }
  }
  return { connectionString: url, ssl: ssl ? { rejectUnauthorized: false } : false };
}
module.exports = { pgConfig };
HANDYTRIO_EOF

cat > src/db.js <<'HANDYTRIO_EOF'
const { Pool } = require('pg');
const { pgConfig } = require('./pgconfig');

const pool = new Pool({ ...pgConfig(), max: 10 });

module.exports = {
  pool,
  query: (text, params) => pool.query(text, params),
};
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
  if (data.app !== 'TheHandyTrio') throw new Error('This isn’t a TheHandyTrio backup file.');
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

cat > scripts/migrate.js <<'HANDYTRIO_EOF'
require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { Client } = require('pg');
const { pgConfig } = require('../src/pgconfig');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const sql = fs.readFileSync(path.join(__dirname, '..', 'db', 'schema.sql'), 'utf8');
  let client;
  for (let attempt = 1; attempt <= 30; attempt++) {
    client = new Client(pgConfig());
    try {
      await client.connect();
      break;
    } catch (e) {
      await client.end().catch(() => {});
      if (attempt === 30) {
        console.error('Could not connect to the database:', e.message);
        process.exit(1);
      }
      await sleep(1000);
    }
  }
  try {
    await client.query(sql);
    console.log('Database schema up to date');
  } catch (e) {
    console.error('Schema error:', e.message);
    process.exitCode = 1;
  } finally {
    await client.end();
  }
})();
HANDYTRIO_EOF

cat > scripts/create-admin.js <<'HANDYTRIO_EOF'
require('dotenv').config();
const bcrypt = require('bcryptjs');
const { Client } = require('pg');
const { pgConfig } = require('../src/pgconfig');

(async () => {
  const [email, name, password] = process.argv.slice(2);
  if (!email || !name || !password) {
    console.log('Usage: npm run create-admin -- you@example.com "Your Name" "a-strong-password"');
    process.exit(1);
  }
  if (password.length < 8) {
    console.log('Password must be at least 8 characters.');
    process.exit(1);
  }
  const client = new Client(pgConfig());
  await client.connect();
  const hash = await bcrypt.hash(password, 12);
  await client.query(
    `INSERT INTO users (role, name, email, password_hash)
     VALUES ('admin', $1, $2, $3)
     ON CONFLICT (email) DO UPDATE
       SET role = 'admin', name = EXCLUDED.name, password_hash = EXCLUDED.password_hash, active = true`,
    [name.trim(), email.trim().toLowerCase(), hash]
  );
  await client.end();
  console.log(`Admin account ready for ${email.trim().toLowerCase()}`);
})().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
HANDYTRIO_EOF

cat > scripts/seed-example.js <<'HANDYTRIO_EOF'
// Adds one example supplier, three price items and a "Hang an internal door" template, only if no templates exist yet.
require('dotenv').config();
const { Client } = require('pg');
const { pgConfig } = require('../src/pgconfig');

(async () => {
  const c = new Client(pgConfig());
  await c.connect();
  const has = (await c.query('SELECT 1 FROM job_templates LIMIT 1')).rows.length;
  if (has) {
    console.log('Templates already exist, example not added.');
    return c.end();
  }
  await c.query('BEGIN');
  const sup = (await c.query(
    `INSERT INTO suppliers (name) VALUES ('Example Merchants') ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id`)).rows[0].id;
  const add = async (code, name, unit, price) => (await c.query(
    'INSERT INTO price_items (supplier_id, code, name, unit, price) VALUES ($1, $2, $3, $4, $5) RETURNING id', [sup, code, name, unit, price])).rows[0].id;
  const door = await add('EX-DOOR', 'Internal door, 762mm', 'each', 45);
  const hinges = await add('EX-HINGE', 'Hinges 75mm (1.5 pairs)', 'set', 8);
  const handle = await add('EX-HANDLE', 'Door handle and latch set', 'set', 15);
  const t = (await c.query(
    `INSERT INTO job_templates (name, work_type, description, pricing_method, labour_per_unit, quantity_question, quantity_unit, max_quantity, active)
     VALUES ('Hang an internal door', 'Doors and windows', 'Supply and hang a standard internal door with hinges and handle.', 'hourly', 3, 'How many doors?', 'doors', 20, true)
     RETURNING id`)).rows[0].id;
  for (const id of [door, hinges, handle]) {
    await c.query('INSERT INTO template_materials (template_id, price_item_id, qty_per_unit) VALUES ($1, $2, 1)', [t, id]);
  }
  await c.query('COMMIT');
  console.log('Added example template "Hang an internal door" with Example Merchants prices.');
  await c.end();
})().catch((e) => {
  console.error('Example not added:', e.message);
  process.exit(1);
});
HANDYTRIO_EOF

cat > scripts/photos-to-db.js <<'HANDYTRIO_EOF'
// One-off: copies photos saved on disk (before photos moved into the database) into the database.
require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { Client } = require('pg');
const { pgConfig } = require('../src/pgconfig');

(async () => {
  const dir = path.join(__dirname, '..', 'uploads');
  const c = new Client(pgConfig());
  await c.connect();
  const { rows } = await c.query('SELECT id, stored_name FROM job_photos WHERE data IS NULL');
  let moved = 0;
  let missing = 0;
  for (const r of rows) {
    const file = path.join(dir, path.basename(r.stored_name));
    if (!fs.existsSync(file)) { missing++; continue; }
    await c.query('UPDATE job_photos SET data = $1 WHERE id = $2', [fs.readFileSync(file), r.id]);
    moved++;
  }
  console.log(`Photos moved into the database: ${moved}${missing ? `, not found on disk: ${missing}` : ''}`);
  await c.end();
})().catch((e) => { console.error(e.message); process.exit(1); });
HANDYTRIO_EOF

cat > scripts/restore-backup.js <<'HANDYTRIO_EOF'
// Emergency restore. WIPES the current data and replaces it with a backup file.
// Usage: npm run restore -- path/to/backup.json.gz
require('dotenv').config();
const fs = require('fs');
const readline = require('readline');
const { Client } = require('pg');
const { pgConfig } = require('../src/pgconfig');
const { restoreBackup } = require('../src/backup');

(async () => {
  const file = process.argv[2];
  if (!file || !fs.existsSync(file)) {
    console.log('Usage: npm run restore -- path/to/backup.json.gz');
    process.exit(1);
  }
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  let where = 'this database';
  try { where = new URL(process.env.DATABASE_URL).hostname; } catch (e) { /* keep default */ }
  const answer = await new Promise((r) => rl.question(`This replaces ALL data in ${where} with the backup. Type RESTORE to carry on: `, r));
  rl.close();
  if (answer.trim() !== 'RESTORE') { console.log('Cancelled. Nothing changed.'); process.exit(0); }
  const c = new Client(pgConfig());
  await c.connect();
  const r = await restoreBackup(c, fs.readFileSync(file));
  await c.end();
  console.log(`Restored ${r.tables} tables from the ${r.setup_only ? 'setup file' : 'backup'} made ${r.created_at}${r.setup_only ? ' (staff, settings, prices and templates; no customers or jobs)' : r.include_photos ? '' : ' (photos were not in this backup)'}.`);
  console.log('Everyone will need to log in again.');
})().catch((e) => { console.error('Restore failed, nothing was changed:', e.message); process.exit(1); });
HANDYTRIO_EOF

cat > scripts/make-backup.js <<'HANDYTRIO_EOF'
// Saves a backup file into the backups folder.
//   npm run backup              everything, including photos
//   npm run backup -- --setup   just staff, settings, price list, templates and messages (no customers or jobs)
require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { Client } = require('pg');
const { pgConfig } = require('../src/pgconfig');
const { makeBackup } = require('../src/backup');

(async () => {
  const setupOnly = process.argv.includes('--setup');
  const c = new Client(pgConfig());
  await c.connect();
  const gz = await makeBackup(c, { includePhotos: !setupOnly, setupOnly });
  await c.end();
  const dir = path.join(__dirname, '..', 'backups');
  fs.mkdirSync(dir, { recursive: true });
  const name = `handytrio-${setupOnly ? 'setup' : 'backup'}-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.json.gz`;
  fs.writeFileSync(path.join(dir, name), gz);
  console.log(`Saved backups/${name} (${Math.max(1, Math.round(gz.length / 1024))} KB)`);
})().catch((e) => { console.error('Backup failed:', e.message); process.exit(1); });
HANDYTRIO_EOF

echo "Checking packages..."
npm install
echo "Updating database..."
node scripts/migrate.js
echo "Making your setup file (staff, settings, prices, templates, no customers or jobs)..."
npm run backup -- --setup
touch src/server.js
echo ""
echo "Ready to go live. Next: ./save.sh \"ready for hosting\""
