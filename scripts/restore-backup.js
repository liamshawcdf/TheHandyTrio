// Emergency restore. WIPES the current data and replaces it with a backup file.
// Usage: npm run restore -- path/to/backup.json.gz
require('dotenv').config();
const fs = require('fs');
const readline = require('readline');
const { Client } = require('pg');
const { restoreBackup } = require('../src/backup');

(async () => {
  const file = process.argv[2];
  if (!file || !fs.existsSync(file)) {
    console.log('Usage: npm run restore -- path/to/backup.json.gz');
    process.exit(1);
  }
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise((r) => rl.question('This replaces ALL current data with the backup. Type RESTORE to carry on: ', r));
  rl.close();
  if (answer.trim() !== 'RESTORE') { console.log('Cancelled. Nothing changed.'); process.exit(0); }
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const r = await restoreBackup(c, fs.readFileSync(file));
  await c.end();
  console.log(`Restored ${r.tables} tables from the backup made ${r.created_at}${r.include_photos ? '' : ' (photos were not in this backup)'}.`);
  console.log('Everyone will need to log in again.');
})().catch((e) => { console.error('Restore failed, nothing was changed:', e.message); process.exit(1); });
