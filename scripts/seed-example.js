// Adds one example supplier, three price items and a "Hang an internal door" template, only if no templates exist yet.
require('dotenv').config();
const { Client } = require('pg');

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
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
