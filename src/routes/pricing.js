const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { WORK_TYPES } = require('../format');
const { calculateEstimate, renderBreakdown, money } = require('../estimate');

const router = express.Router();
const admin = requireRole('admin');

const subnav = (active) => `<nav class="subnav">${[
  ['/admin/templates', 'Job templates'],
  ['/admin/price-list', 'Price list'],
  ['/admin/suppliers', 'Suppliers'],
  ['/admin/access-options', 'Access options'],
].map(([h, l]) => `<a href="${h}" ${h === active ? 'aria-current="page"' : ''}>${l}</a>`).join('')}</nav>`;

const txt = (v, max = 200) => String(v ?? '').trim().slice(0, max);
const num = (v) => {
  const s = String(v ?? '').trim().replace(/[£,\s]/g, '');
  if (s === '') return null;
  const n = Number(s);
  return Number.isFinite(n) && n >= 0 ? n : NaN;
};
const idOf = (v) => {
  const n = Number(v);
  return Number.isInteger(n) && n > 0 ? n : null;
};
const METHODS = { hourly: 'Hourly', day: 'Day rate', fixed: 'Fixed price' };
const UNIT_WORD = { hourly: 'hours', day: 'days', fixed: '£' };

// ================= Suppliers =================
router.get('/admin/suppliers', admin, wrap(async (req, res) => {
  const { rows } = await query(
    `SELECT s.*, (SELECT count(*)::int FROM price_items p WHERE p.supplier_id = s.id) AS items
     FROM suppliers s ORDER BY s.active DESC, s.name`);
  const list = rows.length ? `<div class="scroll"><table>
    <thead><tr><th>Supplier</th><th>Address</th><th>Phone</th><th>Items</th><th>Status</th><th></th></tr></thead>
    <tbody>${rows.map((s) => `<tr class="${s.active ? '' : 'off'}">
      <td><a href="/admin/suppliers/${s.id}">${esc(s.name)}</a></td><td>${s.address || s.postcode ? esc([s.address, s.postcode].filter(Boolean).join(', ')) : '<span class="tag urgent">Needs address</span>'}</td><td>${esc(s.phone)}</td>
      <td><a href="/admin/price-list?supplier=${s.id}">${s.items}</a></td><td>${s.active ? 'Active' : 'Switched off'}</td>
      <td><form method="post" action="/admin/suppliers/${s.id}/toggle" class="inline"><button class="small">${s.active ? 'Switch off' : 'Switch on'}</button></form></td>
    </tr>`).join('')}</tbody></table></div>` : '<p class="empty">No suppliers yet. Add your local merchants below.</p>';
  const body = `${subnav('/admin/suppliers')}${list}
    <h2>Add a supplier</h2>
    <form method="post" action="/admin/suppliers" class="panel narrow">
      <label>Name<input name="name" required maxlength="120"></label>
      <label>Branch address<input name="address" maxlength="200"></label>
      <label>Postcode<input name="postcode" maxlength="10"></label>
      <label>Phone<input name="phone" type="tel"></label>
      <label>Email<input name="email" type="email"></label>
      <p class="hint">The address is used to route builders past the branch to collect parts.</p>
      <button class="primary">Add supplier</button>
    </form>`;
  res.send(page({ title: 'Suppliers', user: req.user, notice: req.query.added ? 'Supplier saved.' : null, error: req.query.error ? txt(req.query.error) : null, body }));
}));

router.post('/admin/suppliers', admin, wrap(async (req, res) => {
  const name = txt(req.body.name, 120);
  if (!name) return res.redirect('/admin/suppliers?error=' + encodeURIComponent('Enter a supplier name.'));
  try {
    await query('INSERT INTO suppliers (name, phone, email, address, postcode) VALUES ($1, $2, $3, $4, $5)',
      [name, txt(req.body.phone) || null, txt(req.body.email) || null, txt(req.body.address) || null, txt(req.body.postcode, 10).toUpperCase() || null]);
  } catch (e) {
    if (e.code === '23505') return res.redirect('/admin/suppliers?error=' + encodeURIComponent('That supplier already exists.'));
    throw e;
  }
  res.redirect('/admin/suppliers?added=1');
}));

router.get('/admin/suppliers/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const s = id && (await query('SELECT * FROM suppliers WHERE id = $1', [id])).rows[0];
  if (!s) return res.redirect('/admin/suppliers');
  const body = `${subnav('/admin/suppliers')}
    <form method="post" action="/admin/suppliers/${s.id}" class="panel narrow">
      <label>Name<input name="name" value="${esc(s.name)}" required maxlength="120"></label>
      <label>Branch address<input name="address" value="${esc(s.address)}" maxlength="200"></label>
      <label>Postcode<input name="postcode" value="${esc(s.postcode)}" maxlength="10"></label>
      <label>Phone<input name="phone" value="${esc(s.phone)}" type="tel"></label>
      <label>Email<input name="email" value="${esc(s.email)}" type="email"></label>
      <button class="primary">Save supplier</button>
    </form>
    <p><a href="/admin/price-list?supplier=${s.id}">See this supplier’s prices</a> · <a href="/admin/suppliers">Back to suppliers</a></p>`;
  res.send(page({ title: s.name, user: req.user, body }));
}));

router.post('/admin/suppliers/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const name = txt(req.body.name, 120);
  if (!id || !name) return res.redirect('/admin/suppliers');
  try {
    await query('UPDATE suppliers SET name = $1, address = $2, postcode = $3, phone = $4, email = $5 WHERE id = $6',
      [name, txt(req.body.address) || null, txt(req.body.postcode, 10).toUpperCase() || null, txt(req.body.phone) || null, txt(req.body.email) || null, id]);
  } catch (e) {
    if (e.code === '23505') return res.redirect('/admin/suppliers?error=' + encodeURIComponent('Another supplier already has that name.'));
    throw e;
  }
  res.redirect('/admin/suppliers?added=1');
}));

router.post('/admin/suppliers/:id/toggle', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  if (id) await query('UPDATE suppliers SET active = NOT active WHERE id = $1', [id]);
  res.redirect('/admin/suppliers');
}));

// ================= Price list =================
async function supplierOptions(selected, { includeNone = true } = {}) {
  const { rows } = await query('SELECT id, name FROM suppliers WHERE active ORDER BY name');
  return (includeNone ? '<option value="">No supplier</option>' : '')
    + rows.map((s) => `<option value="${s.id}" ${s.id === selected ? 'selected' : ''}>${esc(s.name)}</option>`).join('');
}

function itemFields(v = {}, supplierOpts) {
  return `<label>Supplier<select name="supplier_id">${supplierOpts}</select></label>
    <div class="row">
      <label>Product code (optional)<input name="code" value="${esc(v.code)}" maxlength="60"></label>
      <label>Unit<input name="unit" value="${esc(v.unit || 'each')}" maxlength="30" placeholder="each, m, m², bag, length"></label>
    </div>
    <label>Item name<input name="name" value="${esc(v.name)}" required maxlength="200"></label>
    <label>Price (before your markup, excluding VAT)<input name="price" type="number" step="0.01" min="0" value="${esc(v.price)}" required></label>
    <label class="check"><input type="checkbox" name="cut_material" ${v.cut_material ? 'checked' : ''}> Cut to size (add the waste allowance)</label>`;
}

router.get('/admin/price-list', admin, wrap(async (req, res) => {
  const supplier = idOf(req.query.supplier);
  const q = txt(req.query.q, 80);
  const params = [];
  const where = [];
  if (supplier) { params.push(supplier); where.push(`p.supplier_id = $${params.length}`); }
  if (q) { params.push('%' + q + '%'); where.push(`(p.name ILIKE $${params.length} OR p.code ILIKE $${params.length})`); }
  const { rows } = await query(
    `SELECT p.*, s.name AS supplier_name FROM price_items p LEFT JOIN suppliers s ON s.id = p.supplier_id
     ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY p.active DESC, s.name NULLS FIRST, p.name LIMIT 500`, params);
  const cur = (await query('SELECT currency FROM settings WHERE id = 1')).rows[0].currency;

  const filter = `<form method="get" action="/admin/price-list" class="filters">
    <label>Supplier<select name="supplier"><option value="">All</option>${(await supplierOptions(supplier, { includeNone: false }))}</select></label>
    <label>Search<input name="q" value="${esc(q)}" placeholder="Name or code"></label>
    <button class="small">Show</button></form>`;
  const list = rows.length ? `<div class="scroll"><table>
    <thead><tr><th>Item</th><th>Code</th><th>Supplier</th><th>Unit</th><th class="num">Price</th><th></th></tr></thead>
    <tbody>${rows.map((p) => `<tr class="${p.active ? '' : 'off'}">
      <td>${esc(p.name)}${p.cut_material ? ' <span class="tag">Cut</span>' : ''}</td><td>${esc(p.code)}</td>
      <td>${esc(p.supplier_name || '')}</td><td>${esc(p.unit)}</td><td class="num">${money(p.price, cur)}</td>
      <td><a href="/admin/price-list/${p.id}">Edit</a></td></tr>`).join('')}</tbody></table></div>`
    : '<p class="empty">No items match. Add one below, or import a list.</p>';

  const body = `${subnav('/admin/price-list')}${filter}${list}
  <div class="twocol">
    <section>
      <h2>Add an item</h2>
      <form method="post" action="/admin/price-list" class="panel">${itemFields({}, await supplierOptions(supplier))}<button class="primary">Add item</button></form>
    </section>
    <section>
      <h2>Import or update prices</h2>
      <form method="post" action="/admin/price-list/import" class="panel">
        <label>Supplier<select name="supplier_id" required>${await supplierOptions(supplier, { includeNone: false })}</select></label>
        <label>Paste rows: code, name, unit, price, cut (yes/no)
          <textarea name="csv" rows="8" required placeholder="D-INT-01, Internal door 762mm, each, 45.00, no&#10;CLS-2.4, CLS timber 2.4m, length, 3.20, yes"></textarea></label>
        <p class="hint">Items with a matching code (or name, if there’s no code) get their price updated. New ones are added. You can paste straight from a spreadsheet saved as CSV.</p>
        <button class="primary">Import</button>
      </form>
    </section>
  </div>`;
  res.send(page({ title: 'Price list', user: req.user, notice: req.query.msg ? txt(req.query.msg, 300) : null, error: req.query.error ? txt(req.query.error, 300) : null, body }));
}));

function readItem(body) {
  return {
    supplier_id: idOf(body.supplier_id),
    code: txt(body.code, 60) || null,
    name: txt(body.name, 200),
    unit: txt(body.unit, 30) || 'each',
    price: num(body.price),
    cut_material: body.cut_material === 'on',
    active: body.active === undefined ? true : body.active === 'on',
  };
}
const itemError = (v) => (!v.name ? 'Enter an item name.' : v.price === null || Number.isNaN(v.price) ? 'Enter a price of 0 or more.' : null);

router.post('/admin/price-list', admin, wrap(async (req, res) => {
  const v = readItem(req.body);
  const error = itemError(v);
  if (error) return res.redirect('/admin/price-list?error=' + encodeURIComponent(error));
  await query('INSERT INTO price_items (supplier_id, code, name, unit, price, cut_material) VALUES ($1, $2, $3, $4, $5, $6)',
    [v.supplier_id, v.code, v.name, v.unit, v.price, v.cut_material]);
  res.redirect('/admin/price-list?msg=' + encodeURIComponent(`Added ${v.name}.`) + (v.supplier_id ? `&supplier=${v.supplier_id}` : ''));
}));

router.get('/admin/price-list/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const p = id && (await query('SELECT * FROM price_items WHERE id = $1', [id])).rows[0];
  if (!p) return res.redirect('/admin/price-list');
  const used = (await query(
    `SELECT DISTINCT t.id, t.name FROM template_materials tm JOIN job_templates t ON t.id = tm.template_id WHERE tm.price_item_id = $1 ORDER BY t.name`, [id])).rows;
  const body = `${subnav('/admin/price-list')}
    <form method="post" action="/admin/price-list/${p.id}" class="panel narrow">
      ${itemFields(p, await supplierOptions(p.supplier_id))}
      <label class="check"><input type="checkbox" name="active" ${p.active ? 'checked' : ''}> Active (switch off instead of deleting)</label>
      <input type="hidden" name="active_present" value="1">
      <button class="primary">Save item</button>
    </form>
    ${used.length ? `<p>Used in: ${used.map((t) => `<a href="/admin/templates/${t.id}">${esc(t.name)}</a>`).join(', ')}</p>` : '<p class="muted">Not used in any job template yet.</p>'}
    <p><a href="/admin/price-list">Back to price list</a></p>`;
  res.send(page({ title: `Edit ${p.name}`, user: req.user, body }));
}));

router.post('/admin/price-list/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  if (!id) return res.redirect('/admin/price-list');
  const v = readItem({ ...req.body, active: req.body.active_present ? (req.body.active || 'off') : undefined });
  const error = itemError(v);
  if (error) return res.redirect('/admin/price-list?error=' + encodeURIComponent(error));
  await query(
    `UPDATE price_items SET supplier_id = $1, code = $2, name = $3, unit = $4, price = $5, cut_material = $6, active = $7, updated_at = now() WHERE id = $8`,
    [v.supplier_id, v.code, v.name, v.unit, v.price, v.cut_material, v.active, id]);
  res.redirect('/admin/price-list?msg=' + encodeURIComponent(`Saved ${v.name}.`));
}));

function parseCsvLine(line) {
  const out = [];
  let cur = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quoted) {
      if (c === '"') {
        if (line[i + 1] === '"') { cur += '"'; i++; } else quoted = false;
      } else cur += c;
    } else if (c === '"') quoted = true;
    else if (c === ',' || c === '\t') { out.push(cur); cur = ''; }
    else cur += c;
  }
  out.push(cur);
  return out.map((s) => s.trim());
}

router.post('/admin/price-list/import', admin, wrap(async (req, res) => {
  const supplierId = idOf(req.body.supplier_id);
  if (!supplierId) return res.redirect('/admin/price-list?error=' + encodeURIComponent('Choose a supplier for the import.'));
  const lines = String(req.body.csv || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean).slice(0, 2000);
  let added = 0;
  let updated = 0;
  const problems = [];
  for (let i = 0; i < lines.length; i++) {
    const [code, name, unit, price, cut] = parseCsvLine(lines[i]);
    if (i === 0 && /^(code|name|item)$/i.test(code || '')) continue; // header row
    const p = num(price);
    if (!name || p === null || Number.isNaN(p)) { problems.push(i + 1); continue; }
    const isCut = /^(y|yes|true|1|cut)$/i.test(cut || '');
    const existing = code
      ? (await query('SELECT id FROM price_items WHERE supplier_id = $1 AND code = $2', [supplierId, code])).rows[0]
      : (await query('SELECT id FROM price_items WHERE supplier_id = $1 AND lower(name) = lower($2)', [supplierId, name])).rows[0];
    if (existing) {
      await query('UPDATE price_items SET name = $1, unit = $2, price = $3, cut_material = $4, active = true, updated_at = now() WHERE id = $5',
        [name.slice(0, 200), (unit || 'each').slice(0, 30), p, isCut, existing.id]);
      updated++;
    } else {
      await query('INSERT INTO price_items (supplier_id, code, name, unit, price, cut_material) VALUES ($1, $2, $3, $4, $5, $6)',
        [supplierId, code ? code.slice(0, 60) : null, name.slice(0, 200), (unit || 'each').slice(0, 30), p, isCut]);
      added++;
    }
  }
  const msg = `Import finished: ${added} added, ${updated} updated.` + (problems.length ? ` Skipped line${problems.length === 1 ? '' : 's'} ${problems.slice(0, 15).join(', ')} (missing name or price).` : '');
  res.redirect(`/admin/price-list?supplier=${supplierId}&msg=${encodeURIComponent(msg)}`);
}));

// ================= Job templates =================
router.get('/admin/templates', admin, wrap(async (req, res) => {
  const { rows } = await query(
    `SELECT t.*, (SELECT count(*)::int FROM template_materials m WHERE m.template_id = t.id) AS materials
     FROM job_templates t ORDER BY t.active DESC, t.work_type, t.name`);
  const list = rows.length ? `<div class="scroll"><table>
    <thead><tr><th>Template</th><th>Type of work</th><th>Pricing</th><th>Materials</th><th>Status</th></tr></thead>
    <tbody>${rows.map((t) => `<tr class="${t.active ? '' : 'off'}">
      <td><a href="/admin/templates/${t.id}">${esc(t.name)}</a></td><td>${esc(t.work_type)}</td>
      <td>${METHODS[t.pricing_method]}</td><td>${t.materials}</td><td>${t.active ? 'Shown to customers' : 'Hidden'}</td>
    </tr>`).join('')}</tbody></table></div>` : '<p class="empty">No templates yet. Start with the job you do most often.</p>';
  const body = `${subnav('/admin/templates')}
    <p class="lead">Each template is a job customers can pick. Its labour, materials and your rates work out the estimate.</p>
    ${list}
    <h2>New template</h2>
    <form method="post" action="/admin/templates" class="panel narrow">
      <label>Job name customers will see<input name="name" required maxlength="120" placeholder="Hang an internal door"></label>
      <label>Type of work<select name="work_type">${WORK_TYPES.filter((w) => w !== 'Something else').map((w) => `<option>${esc(w)}</option>`).join('')}</select></label>
      <label>Pricing method<select name="pricing_method">${Object.entries(METHODS).map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></label>
      <button class="primary">Create and set up</button>
    </form>`;
  res.send(page({ title: 'Job templates', user: req.user, body }));
}));

router.post('/admin/templates', admin, wrap(async (req, res) => {
  const name = txt(req.body.name, 120);
  const method = METHODS[req.body.pricing_method] ? req.body.pricing_method : 'hourly';
  const workType = WORK_TYPES.includes(req.body.work_type) ? req.body.work_type : null;
  if (!name) return res.redirect('/admin/templates');
  const { rows } = await query('INSERT INTO job_templates (name, work_type, pricing_method, active) VALUES ($1, $2, $3, false) RETURNING id', [name, workType, method]);
  res.redirect(`/admin/templates/${rows[0].id}?created=1`);
}));

router.get('/admin/templates/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const t = id && (await query('SELECT * FROM job_templates WHERE id = $1', [id])).rows[0];
  if (!t) return res.redirect('/admin/templates');
  const mats = (await query(
    `SELECT tm.id, tm.qty_per_unit, p.name, p.unit, p.price, p.active, s.name AS supplier
     FROM template_materials tm JOIN price_items p ON p.id = tm.price_item_id LEFT JOIN suppliers s ON s.id = p.supplier_id
     WHERE tm.template_id = $1 ORDER BY tm.id`, [id])).rows;
  const items = (await query(
    `SELECT p.id, p.name, p.unit, p.price, s.name AS supplier FROM price_items p LEFT JOIN suppliers s ON s.id = p.supplier_id
     WHERE p.active ORDER BY p.name`)).rows;
  const cur = (await query('SELECT currency FROM settings WHERE id = 1')).rows[0].currency;
  const unitWord = UNIT_WORD[t.pricing_method];
  const perWhat = t.quantity_unit ? esc(t.quantity_unit.replace(/s$/, '')) : 'unit';

  const previewQty = Number(req.query.qty) > 0 ? Number(req.query.qty) : 1;
  const est = await calculateEstimate({ templateId: id, quantity: previewQty, skipTravel: true });

  const v = (k) => esc(t[k] ?? '');
  const body = `${subnav('/admin/templates')}
  <div class="twocol">
  <section>
    <form method="post" action="/admin/templates/${t.id}" class="panel">
      <label>Job name customers will see<input name="name" value="${v('name')}" required maxlength="120"></label>
      <label>Type of work<select name="work_type">${WORK_TYPES.filter((w) => w !== 'Something else').map((w) => `<option ${w === t.work_type ? 'selected' : ''}>${esc(w)}</option>`).join('')}</select></label>
      <label>Short description for customers (optional)<textarea name="description" rows="2" maxlength="500">${v('description')}</textarea></label>

      <label>Pricing method<select name="pricing_method">${Object.entries(METHODS).map(([k, l]) => `<option value="${k}" ${k === t.pricing_method ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
      <div class="row">
        <label>Labour per ${perWhat} (${unitWord})<input name="labour_per_unit" type="number" step="0.01" min="0" value="${v('labour_per_unit')}"></label>
        <label>Plus once per job (${unitWord})<input name="labour_setup" type="number" step="0.01" min="0" value="${v('labour_setup')}"></label>
      </div>
      <label>Crew size (blank uses the default)<input name="crew" type="number" step="1" min="1" value="${v('crew')}"></label>

      <label>Sizing question (blank means no question, quantity 1)<input name="quantity_question" value="${v('quantity_question')}" maxlength="120" placeholder="How many doors?"></label>
      <div class="row">
        <label>Unit word<input name="quantity_unit" value="${v('quantity_unit')}" maxlength="30" placeholder="doors, m², panels"></label>
        <label>Most a customer can enter<input name="max_quantity" type="number" step="0.5" min="1" value="${v('max_quantity')}"></label>
      </div>

      <div class="row">
        <label>Range below (%, blank = default)<input name="range_low_pct" type="number" step="0.1" min="0" value="${v('range_low_pct')}"></label>
        <label>Range above (%, blank = default)<input name="range_high_pct" type="number" step="0.1" min="0" value="${v('range_high_pct')}"></label>
      </div>
      <label class="check"><input type="checkbox" name="materials_included" ${t.materials_included ? 'checked' : ''}> Materials are included in the fixed price</label>
      <label class="check"><input type="checkbox" name="active" ${t.active ? 'checked' : ''}> Show this job to customers</label>
      <button class="primary">Save template</button>
    </form>

    <h2>Materials per ${perWhat}</h2>
    ${mats.length ? `<div class="scroll"><table>
      <thead><tr><th>Item</th><th>Qty</th><th class="num">Price</th><th></th></tr></thead>
      <tbody>${mats.map((m) => `<tr class="${m.active ? '' : 'off'}">
        <td>${esc(m.name)}${m.supplier ? ` <span class="muted">(${esc(m.supplier)})</span>` : ''}</td>
        <td>${Number(m.qty_per_unit)} ${esc(m.unit)}</td><td class="num">${money(m.price, cur)}</td>
        <td><form method="post" action="/admin/templates/${t.id}/materials/${m.id}/delete" class="inline"><button class="small">Remove</button></form></td>
      </tr>`).join('')}</tbody></table></div>` : '<p class="empty">No materials yet.</p>'}
    ${items.length ? `<form method="post" action="/admin/templates/${t.id}/materials" class="panel addmat">
      <label>Item<select name="price_item_id" required>${items.map((p) => `<option value="${p.id}">${esc(p.name)} (${esc(p.unit)}, ${money(p.price, cur)}${p.supplier ? `, ${esc(p.supplier)}` : ''})</option>`).join('')}</select></label>
      <label>Qty per ${perWhat}<input name="qty_per_unit" type="number" step="0.01" min="0" value="1" required></label>
      <button class="small">Add material</button>
    </form>` : '<p>Add items to the <a href="/admin/price-list">price list</a> first.</p>'}
  </section>

  <section>
    <h2>Example estimate</h2>
    <form method="get" action="/admin/templates/${t.id}" class="filters">
      <label>${t.quantity_question ? esc(t.quantity_question) : 'Quantity'}<input name="qty" type="number" step="0.5" min="0.5" value="${previewQty}" ${t.quantity_question ? '' : 'disabled'}></label>
      <button class="small">Recalculate</button>
    </form>
    <p class="hint">Uses today’s prices and rates, with no travel, access issues or urgency.</p>
    ${est ? renderBreakdown(est) : ''}
  </section>
  </div>
  <p><a href="/admin/templates">Back to templates</a></p>`;
  const notice = req.query.created ? 'Template created. It stays hidden from customers until you tick “Show this job to customers”.' : req.query.saved ? 'Template saved.' : null;
  res.send(page({ title: t.name, user: req.user, notice, error: req.query.error ? txt(req.query.error) : null, body }));
}));

router.post('/admin/templates/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  if (!id) return res.redirect('/admin/templates');
  const b = req.body;
  const name = txt(b.name, 120);
  const nums = {};
  for (const k of ['labour_per_unit', 'labour_setup', 'crew', 'max_quantity', 'range_low_pct', 'range_high_pct']) nums[k] = num(b[k]);
  const bad = Object.entries(nums).find(([, n]) => Number.isNaN(n));
  if (!name || bad) return res.redirect(`/admin/templates/${id}?error=` + encodeURIComponent(!name ? 'Enter a job name.' : 'Numbers must be 0 or more.'));
  await query(
    `UPDATE job_templates SET name = $1, work_type = $2, description = $3, pricing_method = $4, labour_per_unit = $5, labour_setup = $6,
       crew = $7, quantity_question = $8, quantity_unit = $9, max_quantity = $10, range_low_pct = $11, range_high_pct = $12,
       materials_included = $13, active = $14 WHERE id = $15`,
    [name, WORK_TYPES.includes(b.work_type) ? b.work_type : null, txt(b.description, 500) || null,
      METHODS[b.pricing_method] ? b.pricing_method : 'hourly', nums.labour_per_unit || 0, nums.labour_setup || 0,
      nums.crew ? Math.max(1, Math.round(nums.crew)) : null, txt(b.quantity_question, 120) || null, txt(b.quantity_unit, 30) || null,
      nums.max_quantity || 50, nums.range_low_pct, nums.range_high_pct, b.materials_included === 'on', b.active === 'on', id]);
  res.redirect(`/admin/templates/${id}?saved=1`);
}));

router.post('/admin/templates/:id/materials', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const itemId = idOf(req.body.price_item_id);
  const qty = num(req.body.qty_per_unit);
  if (id && itemId && qty !== null && !Number.isNaN(qty)) {
    await query('INSERT INTO template_materials (template_id, price_item_id, qty_per_unit) VALUES ($1, $2, $3)', [id, itemId, qty]);
  }
  res.redirect(`/admin/templates/${id || ''}`);
}));

router.post('/admin/templates/:id/materials/:mid/delete', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const mid = idOf(req.params.mid);
  if (id && mid) await query('DELETE FROM template_materials WHERE id = $1 AND template_id = $2', [mid, id]);
  res.redirect(`/admin/templates/${id || ''}`);
}));

// ================= Access options =================
router.get('/admin/access-options', admin, wrap(async (req, res) => {
  const { rows } = await query('SELECT * FROM access_options ORDER BY active DESC, id');
  const body = `${subnav('/admin/access-options')}
    <p class="lead">Customers tick these on the request form. Each one multiplies the labour, so 1.2 adds 20%.</p>
    ${rows.map((a) => `<form method="post" action="/admin/access-options/${a.id}" class="panel accessrow ${a.active ? '' : 'off'}">
      <label>Label<input name="label" value="${esc(a.label)}" required maxlength="120"></label>
      <label>Multiplier<input name="multiplier" type="number" step="0.05" min="0.5" value="${esc(a.multiplier)}" required></label>
      <label class="check"><input type="checkbox" name="active" ${a.active ? 'checked' : ''}> Active</label>
      <button class="small">Save</button>
    </form>`).join('')}
    <h2>Add an option</h2>
    <form method="post" action="/admin/access-options" class="panel accessrow">
      <label>Label<input name="label" required maxlength="120" placeholder="Third floor or higher, no lift"></label>
      <label>Multiplier<input name="multiplier" type="number" step="0.05" min="0.5" value="1.1" required></label>
      <button class="primary">Add option</button>
    </form>`;
  res.send(page({ title: 'Access options', user: req.user, notice: req.query.saved ? 'Saved.' : null, body }));
}));

router.post('/admin/access-options', admin, wrap(async (req, res) => {
  const label = txt(req.body.label, 120);
  const m = num(req.body.multiplier);
  if (label && m > 0) await query('INSERT INTO access_options (label, multiplier) VALUES ($1, $2)', [label, m]);
  res.redirect('/admin/access-options?saved=1');
}));

router.post('/admin/access-options/:id', admin, wrap(async (req, res) => {
  const id = idOf(req.params.id);
  const label = txt(req.body.label, 120);
  const m = num(req.body.multiplier);
  if (id && label && m > 0) await query('UPDATE access_options SET label = $1, multiplier = $2, active = $3 WHERE id = $4', [label, m, req.body.active === 'on', id]);
  res.redirect('/admin/access-options?saved=1');
}));

module.exports = router;
