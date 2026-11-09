// Behind-the-scenes tools for the office and builders: the working estimate (worksheet) and time tracking.
// Customers never see any of this.
const express = require('express');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { when } = require('../format');
const { money } = require('../estimate');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange } = require('../notify');
const { sendQuoteForm } = require('./quotes');

const router = express.Router();
const staff = requireRole('admin', 'builder');

const N = (x) => Number(x) || 0;
const r2 = (n) => Math.round(n * 100) / 100;
const CATS = { materials: 'Materials', labour: 'Labour', travel: 'Travel', other: 'Other' };
const BLANK_ROWS = 3;
const PRE_INSPECTION = ['request', 'estimated', 'inspection_required', 'inspection_booked'];

async function loadLines(jobId) {
  return (await query('SELECT * FROM job_estimate_lines WHERE job_id = $1 ORDER BY sort, id', [jobId])).rows;
}

async function worksheetTotals(lines) {
  const s = (await query('SELECT vat_registered, vat_rate, currency FROM settings WHERE id = 1')).rows[0];
  const byCat = {};
  let net = 0;
  for (const l of lines) {
    const t = r2(N(l.qty) * N(l.unit_price));
    byCat[l.category] = r2((byCat[l.category] || 0) + t);
    net += t;
  }
  net = r2(net);
  const vat = s.vat_registered ? r2(net * N(s.vat_rate) / 100) : 0;
  const labourHours = r2(lines.filter((l) => l.category === 'labour' && /^h(ou)?rs?$/i.test(l.unit || '')).reduce((a, l) => a + N(l.qty), 0));
  return { byCat, net, vat, vatRate: s.vat_registered ? N(s.vat_rate) : 0, total: r2(net + vat), currency: s.currency, labourHours };
}

// Turns the automatic estimate into editable lines that add up to the same net figure.
function linesFromSnapshot(e) {
  const lines = [];
  const markup = e.materials.included ? 0 : N(e.materials.markupPct) / 100;
  for (const m of e.materials.lines) {
    if (!N(m.qty)) continue;
    lines.push({ category: 'materials', description: m.name, qty: m.qty, unit: m.unit, unit_price: r2(m.price * (1 + markup)) });
  }
  if (e.labour.qty !== undefined) {
    lines.push({ category: 'labour', description: 'Labour', qty: e.labour.qty, unit: e.labour.unit, unit_price: e.labour.rate });
  } else {
    lines.push({ category: 'labour', description: 'Labour', qty: 1, unit: 'job', unit_price: e.labour.base });
  }
  if (e.labour.urgentPremium) lines.push({ category: 'labour', description: 'Urgent premium', qty: 1, unit: 'job', unit_price: e.labour.urgentPremium });
  if (e.travel.mileage) lines.push({ category: 'travel', description: `Mileage, ${e.travel.oneWayMiles} miles each way × ${e.travel.visits}`, qty: 1, unit: 'job', unit_price: e.travel.mileage });
  if (e.travel.time) lines.push({ category: 'travel', description: 'Travel time', qty: 1, unit: 'job', unit_price: e.travel.time });
  if (e.contingency) lines.push({ category: 'other', description: `Contingency ${e.contingencyPct}%`, qty: 1, unit: 'job', unit_price: e.contingency });
  if (e.minimumApplied) {
    const sum = lines.reduce((a, l) => a + N(l.qty) * N(l.unit_price), 0);
    const topUp = r2(N(e.net) - sum);
    if (topUp > 0) lines.push({ category: 'other', description: 'Minimum charge top-up', qty: 1, unit: 'job', unit_price: topUp });
  }
  return lines;
}

async function replaceLines(client, jobId, lines, userId, notes) {
  await client.query('DELETE FROM job_estimate_lines WHERE job_id = $1', [jobId]);
  let i = 0;
  for (const l of lines) {
    await client.query(
      'INSERT INTO job_estimate_lines (job_id, category, description, qty, unit, unit_price, sort) VALUES ($1, $2, $3, $4, $5, $6, $7)',
      [jobId, l.category, l.description, l.qty, l.unit || null, l.unit_price, i++]);
  }
  await client.query('UPDATE jobs SET worksheet_updated_at = now(), worksheet_updated_by = $1, worksheet_notes = coalesce($2, worksheet_notes), updated_at = now() WHERE id = $3',
    [userId, notes, jobId]);
}

// ---------------- Panels shown on the job page ----------------
async function worksheetPanel(job, user) {
  if (user.role === 'customer') return '';
  const lines = await loadLines(job.id);
  if (!lines.length) {
    return `<section class="panel staffonly">
      <h2>Working estimate <span class="tag">Office and builders only</span></h2>
      <p>Adjust the price on site or afterwards. This becomes the quote.</p>
      <div class="buttons">
        ${job.estimate_snapshot ? `<form method="post" action="/jobs/${job.id}/worksheet/from-estimate" class="inline"><button class="primary">Start from the price guide</button></form>` : ''}
        <a class="button" href="/jobs/${job.id}/worksheet">Start blank</a>
      </div>
    </section>`;
  }
  const t = await worksheetTotals(lines);
  const m = (n) => money(n, t.currency);
  const by = job.worksheet_updated_by ? (await query('SELECT name FROM users WHERE id = $1', [job.worksheet_updated_by])).rows[0] : null;
  return `<section class="panel staffonly">
    <h2>Working estimate <span class="tag">Office and builders only</span></h2>
    <p class="bigprice">${m(t.total)}${t.vat ? ' <span class="muted small">incl. VAT</span>' : ''}</p>
    <p class="muted">${Object.entries(CATS).filter(([k]) => t.byCat[k]).map(([k, l]) => `${l} ${m(t.byCat[k])}`).join(' · ')}</p>
    <p class="muted">Last updated ${when(job.worksheet_updated_at)}${by ? ` by ${esc(by.name)}` : ''}.</p>
    <a class="button primary" href="/jobs/${job.id}/worksheet">Edit working estimate</a>
    ${await sendQuoteForm(job, user)}
  </section>`;
}

async function timePanel(job, user) {
  if (user.role === 'customer') return '';
  const entries = (await query(
    `SELECT t.*, u.name FROM job_time_entries t JOIN users u ON u.id = t.user_id WHERE t.job_id = $1 ORDER BY t.started_at DESC`, [job.id])).rows;
  const mine = entries.find((e) => e.user_id === user.id && !e.ended_at);
  const elsewhere = !mine && (await query(
    `SELECT t.job_id FROM job_time_entries t WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
  const hrs = (a, b) => (new Date(b || Date.now()) - new Date(a)) / 3600000;
  const fmt = (h) => `${Math.floor(h)}h ${String(Math.round((h % 1) * 60)).padStart(2, '0')}m`;
  const actual = entries.reduce((a, e) => a + hrs(e.started_at, e.ended_at), 0);

  const lines = await loadLines(job.id);
  const wsHours = lines.length ? (await worksheetTotals(lines)).labourHours : 0;
  const autoHours = job.estimate_snapshot && job.estimate_snapshot.labour ? job.estimate_snapshot.labour.estimatedHours : null;
  const estHours = wsHours || autoHours;

  const canClock = user.role === 'admin' || job.assigned_builder_id === user.id;
  const clock = !canClock ? '' : mine
    ? `<form method="post" action="/jobs/${job.id}/clock-off" class="clock on">
        <p><strong>Clocked on</strong> since ${when(mine.started_at)} (${fmt(hrs(mine.started_at))})</p>
        <label>What did you do? (optional)<input name="note" maxlength="300"></label>
        <button class="primary">Clock off</button>
      </form>`
    : `<form method="post" action="/jobs/${job.id}/clock-on" class="clock">
        ${elsewhere ? `<p class="hint">You’re clocked on to another job. Clocking on here will clock you off there.</p>` : ''}
        <button class="primary">Clock on to this job</button>
      </form>`;

  return `<section class="panel staffonly">
    <h2>Time on this job <span class="tag">Office and builders only</span></h2>
    ${clock}
    <p>Actual so far: <strong>${fmt(actual)}</strong>${estHours ? ` against ${estHours} hrs estimated` : ''}${estHours && actual > estHours ? ' <span class="tag urgent">Over estimate</span>' : ''}</p>
    ${entries.length ? `<div class="scroll"><table>
      <thead><tr><th>Who</th><th>Started</th><th>Finished</th><th>Time</th><th>Note</th>${user.role === 'admin' ? '<th></th>' : ''}</tr></thead>
      <tbody>${entries.map((e) => `<tr>
        <td>${esc(e.name)}</td><td>${when(e.started_at)}</td><td>${e.ended_at ? when(e.ended_at) : '<span class="tag">Running</span>'}</td>
        <td>${fmt(hrs(e.started_at, e.ended_at))}</td><td>${esc(e.note)}</td>
        ${user.role === 'admin' ? `<td><form method="post" action="/jobs/${job.id}/time/${e.id}/delete" class="inline"><button class="small">Delete</button></form></td>` : ''}
      </tr>`).join('')}</tbody></table></div>` : '<p class="empty">No time recorded yet.</p>'}
  </section>`;
}

// ---------------- Time tracking ----------------
const mayWork = (user, job) => user.role === 'admin' || job.assigned_builder_id === user.id;

router.post('/jobs/:id/clock-on', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(
      `UPDATE job_time_entries SET ended_at = now(), note = coalesce(note, 'Clocked off automatically when clocking on to another job')
       WHERE user_id = $1 AND ended_at IS NULL`, [req.user.id]);
    await client.query('INSERT INTO job_time_entries (job_id, user_id) VALUES ($1, $2)', [job.id, req.user.id]);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  res.redirect(`/jobs/${job.id}#time`);
}));

router.post('/jobs/:id/clock-off', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const note = String(req.body.note || '').trim().slice(0, 300) || null;
  await query('UPDATE job_time_entries SET ended_at = now(), note = coalesce($1, note) WHERE job_id = $2 AND user_id = $3 AND ended_at IS NULL',
    [note, job.id, req.user.id]);
  res.redirect(`/jobs/${job.id}#time`);
}));

router.post('/jobs/:id/time/:eid/delete', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  await query('DELETE FROM job_time_entries WHERE id = $1 AND job_id = $2', [Number(req.params.eid) || 0, job.id]);
  res.redirect(`/jobs/${job.id}#time`);
}));

// ---------------- Worksheet (working estimate) ----------------
function lineRow(i, l = {}) {
  const isNew = !l.description;
  return `<div class="wline ${isNew ? 'new' : ''}">
    <label>Type<select name="l${i}_cat">${Object.entries(CATS).map(([k, v]) => `<option value="${k}" ${k === (l.category || 'materials') ? 'selected' : ''}>${v}</option>`).join('')}</select></label>
    <label class="desc">Description<input name="l${i}_desc" value="${esc(l.description)}" maxlength="200" ${isNew ? 'placeholder="Add a line"' : ''}></label>
    <label>Qty<input name="l${i}_qty" type="number" step="0.01" min="0" value="${esc(l.qty ?? '')}"></label>
    <label>Unit<input name="l${i}_unit" value="${esc(l.unit)}" maxlength="20"></label>
    <label>Price each<input name="l${i}_price" type="number" step="0.01" min="0" value="${esc(l.unit_price ?? '')}"></label>
    <span class="ltotal">${isNew ? '' : money(N(l.qty) * N(l.unit_price), '£')}</span>
    ${isNew ? '<span></span>' : `<label class="check del"><input type="checkbox" name="l${i}_del"> Remove</label>`}
  </div>`;
}

router.get('/jobs/:id/worksheet', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const lines = await loadLines(job.id);
  const t = await worksheetTotals(lines);
  const m = (n) => money(n, t.currency);
  const items = (await query(
    `SELECT p.id, p.name, p.unit, p.price, s.name AS supplier FROM price_items p LEFT JOIN suppliers s ON s.id = p.supplier_id WHERE p.active ORDER BY p.name`)).rows;
  const count = lines.length + BLANK_ROWS;

  const body = `
  <p class="jobhead"><a href="/jobs/${job.id}">Back to the job</a></p>
  <p class="lead">Prices here are what the customer pays, before VAT. Change anything you find on site. This becomes the quote.</p>
  <form method="post" action="/jobs/${job.id}/worksheet" class="worksheet">
    <input type="hidden" name="count" value="${count}">
    ${lines.map((l, i) => lineRow(i, l)).join('')}
    ${Array.from({ length: BLANK_ROWS }, (_, k) => lineRow(lines.length + k)).join('')}
    <div class="wtotals panel">
      ${Object.entries(CATS).filter(([k]) => t.byCat[k]).map(([k, l]) => `<div><span>${l}</span><span>${m(t.byCat[k])}</span></div>`).join('')}
      <div class="sum"><span>Net</span><span>${m(t.net)}</span></div>
      ${t.vat ? `<div><span>VAT ${t.vatRate}%</span><span>${m(t.vat)}</span></div>` : ''}
      <div class="grand"><span>Total</span><span>${m(t.total)}</span></div>
      <p class="hint">Totals update when you save.</p>
    </div>
    <label>Notes for the office (never shown to the customer)<textarea name="notes" rows="3" maxlength="2000">${esc(job.worksheet_notes)}</textarea></label>
    ${PRE_INSPECTION.includes(job.status) ? '<label class="check"><input type="checkbox" name="mark_inspected"> I’ve inspected the job (moves it to Inspected and emails the customer)</label>' : ''}
    <button class="primary">Save working estimate</button>
  </form>

  <div class="twocol">
    <section>
      <h2>Add from the price list</h2>
      ${items.length ? `<form method="post" action="/jobs/${job.id}/worksheet/add-item" class="panel">
        <label>Item<select name="price_item_id">${items.map((p) => `<option value="${p.id}">${esc(p.name)} (${esc(p.unit)}, ${m(p.price)} cost${p.supplier ? `, ${esc(p.supplier)}` : ''})</option>`).join('')}</select></label>
        <label>Quantity<input name="qty" type="number" step="0.01" min="0.01" value="1" required></label>
        <p class="hint">Added at your markup. Save any changes above first.</p>
        <button class="small">Add item</button>
      </form>` : '<p class="empty">The price list is empty.</p>'}
    </section>
    ${job.estimate_snapshot ? `<section>
      <h2>Start again</h2>
      <form method="post" action="/jobs/${job.id}/worksheet/from-estimate" class="panel">
        <p>Replace every line with the automatic price guide.</p>
        <label class="check"><input type="checkbox" name="confirm" required> Yes, replace all lines</label>
        <button class="small danger">Replace lines</button>
      </form>
    </section>` : ''}
  </div>`;
  res.send(page({ title: `Working estimate: ${job.title}`, user: req.user, notice: req.query.saved ? 'Working estimate saved.' : null, body }));
}));

router.post('/jobs/:id/worksheet', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const count = Math.min(Number(req.body.count) || 0, 300);
  const lines = [];
  for (let i = 0; i < count; i++) {
    if (req.body[`l${i}_del`] === 'on') continue;
    const description = String(req.body[`l${i}_desc`] || '').trim().slice(0, 200);
    if (!description) continue;
    const qty = Math.max(0, N(req.body[`l${i}_qty`]));
    const unitPrice = Math.max(0, N(req.body[`l${i}_price`]));
    const category = CATS[req.body[`l${i}_cat`]] ? req.body[`l${i}_cat`] : 'other';
    lines.push({ category, description, qty: String(req.body[`l${i}_qty`] || '').trim() === '' ? 1 : qty, unit: String(req.body[`l${i}_unit`] || '').trim().slice(0, 20), unit_price: unitPrice });
  }
  const notes = String(req.body.notes ?? '').trim().slice(0, 2000);
  const inspect = req.body.mark_inspected === 'on' && PRE_INSPECTION.includes(job.status);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await replaceLines(client, job.id, lines, req.user.id, notes);
    if (inspect) await setStatus(client, job.id, job.status, 'inspected', req.user.id, 'Inspected on site');
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  if (inspect) await notifyStageChange(job.id, 'inspected', baseUrlOf(req));
  res.redirect(`/jobs/${job.id}/worksheet?saved=1`);
}));

router.post('/jobs/:id/worksheet/from-estimate', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  if (!job.estimate_snapshot) return res.redirect(`/jobs/${job.id}/worksheet`);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await replaceLines(client, job.id, linesFromSnapshot(job.estimate_snapshot), req.user.id, null);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  res.redirect(`/jobs/${job.id}/worksheet?saved=1`);
}));

router.post('/jobs/:id/worksheet/add-item', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const item = (await query('SELECT name, unit, price FROM price_items WHERE id = $1', [Number(req.body.price_item_id) || 0])).rows[0];
  const qty = N(req.body.qty);
  if (item && qty > 0) {
    const s = (await query('SELECT markup_pct FROM settings WHERE id = 1')).rows[0];
    const sort = (await query('SELECT coalesce(max(sort), 0) + 1 AS n FROM job_estimate_lines WHERE job_id = $1', [job.id])).rows[0].n;
    await query(
      `INSERT INTO job_estimate_lines (job_id, category, description, qty, unit, unit_price, sort) VALUES ($1, 'materials', $2, $3, $4, $5, $6)`,
      [job.id, item.name, qty, item.unit, r2(N(item.price) * (1 + N(s.markup_pct) / 100)), sort]);
    await query('UPDATE jobs SET worksheet_updated_at = now(), worksheet_updated_by = $1 WHERE id = $2', [req.user.id, job.id]);
  }
  res.redirect(`/jobs/${job.id}/worksheet?saved=1`);
}));

module.exports = { router, worksheetPanel, timePanel };
