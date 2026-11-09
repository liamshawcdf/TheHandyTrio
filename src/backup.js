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
