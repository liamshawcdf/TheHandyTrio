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
