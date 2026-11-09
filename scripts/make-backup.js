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
