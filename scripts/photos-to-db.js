// One-off: copies photos saved on disk (before photos moved into the database) into the database.
require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { Client } = require('pg');

(async () => {
  const dir = path.join(__dirname, '..', 'uploads');
  const c = new Client({ connectionString: process.env.DATABASE_URL });
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
