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
