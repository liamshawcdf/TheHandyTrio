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
