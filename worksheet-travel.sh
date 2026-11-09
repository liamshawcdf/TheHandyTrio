#!/usr/bin/env bash
# TheHandyTrio: travel from the builder’s home on working estimates. Run with: bash worksheet-travel.sh
set -e
if [ ! -f package.json ]; then echo "Run this inside the TheHandyTrio folder"; exit 1; fi

cat > src/estimate.js <<'HANDYTRIO_EOF'
// Works out a job estimate from a template, the price list and the rates in settings.
const { query } = require('./db');
const { esc } = require('./layout');

const ROAD_FACTOR = 1.3; // straight-line miles to rough road miles
const AVG_MPH = 30;      // average driving speed for travel time

const N = (x) => Number(x) || 0;
const pct = (x) => N(x) / 100;
const r2 = (n) => Math.round(n * 100) / 100;
const money = (n, cur = '£') =>
  cur + N(n).toLocaleString('en-GB', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const normPostcode = (pc) => String(pc || '').toUpperCase().replace(/\s+/g, '');

// Finds a UK postcode's location using postcodes.io (free, no key), cached in the database.
async function locate(postcode) {
  const key = normPostcode(postcode);
  if (!/^[A-Z]{1,2}\d[A-Z\d]?\d[A-Z]{2}$/.test(key)) return null;
  const cached = await query('SELECT lat, lng FROM postcode_locations WHERE postcode = $1', [key]);
  if (cached.rows[0]) return { lat: N(cached.rows[0].lat), lng: N(cached.rows[0].lng) };
  try {
    const res = await fetch('https://api.postcodes.io/postcodes/' + encodeURIComponent(key), { signal: AbortSignal.timeout(5000) });
    if (!res.ok) return null;
    const data = await res.json();
    const lat = data && data.result && data.result.latitude;
    const lng = data && data.result && data.result.longitude;
    if (typeof lat !== 'number' || typeof lng !== 'number') return null;
    await query(
      `INSERT INTO postcode_locations (postcode, lat, lng) VALUES ($1, $2, $3)
       ON CONFLICT (postcode) DO UPDATE SET lat = EXCLUDED.lat, lng = EXCLUDED.lng, fetched_at = now()`,
      [key, lat, lng]
    );
    return { lat, lng };
  } catch (e) {
    return null;
  }
}

function milesBetween(a, b) {
  const R = 3958.8;
  const rad = (x) => (x * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

// Where the van leaves from: the assigned builder's home, otherwise the nearest builder's home, otherwise the base.
async function travelOrigin(s, to, builderId, warnings) {
  if (builderId) {
    const b = (await query("SELECT name, postcode FROM users WHERE id = $1 AND role = 'builder'", [builderId])).rows[0];
    const loc = b && b.postcode ? await locate(b.postcode) : null;
    if (loc) return { label: `${b.name}’s home`, postcode: b.postcode, loc };
    warnings.push(`${b ? b.name : 'The assigned builder'} has no usable home postcode, so travel is from the nearest builder or the base instead.`);
  }
  const builders = (await query(
    "SELECT name, postcode FROM users WHERE role = 'builder' AND active AND coalesce(postcode, '') <> '' ORDER BY id")).rows;
  let best = null;
  for (const b of builders) {
    const loc = await locate(b.postcode);
    if (!loc) continue;
    const d = milesBetween(loc, to);
    if (!best || d < best.d) best = { d, label: `${b.name}’s home (nearest builder)`, postcode: b.postcode, loc };
  }
  if (best) return best;
  if (s.base_postcode) {
    const loc = await locate(s.base_postcode);
    if (loc) return { label: 'Base', postcode: s.base_postcode, loc };
  }
  return null;
}

// Travel cost for a number of visits, from the assigned builder, else the nearest builder, else the base.
async function computeTravel({ s, postcode, builderId = null, visits = 1, warnings = [] }) {
  if (!s) s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const travel = { from: null, fromPostcode: null, oneWayMiles: null, visits, mileage: 0, time: 0, total: 0 };
  const to = await locate(postcode);
  const origin = to ? await travelOrigin(s, to, builderId, warnings) : null;
  if (!to) {
    warnings.push('The distance to this postcode couldn’t be found, so travel isn’t included.');
  } else if (!origin) {
    warnings.push('No builder home postcodes or base postcode are set, so travel isn’t included.');
  } else {
    const oneWay = milesBetween(origin.loc, to) * ROAD_FACTOR;
    const roundTrips = oneWay * 2 * visits;
    travel.from = origin.label;
    travel.fromPostcode = origin.postcode;
    travel.oneWayMiles = r2(oneWay);
    travel.mileage = r2(roundTrips * N(s.mileage_rate));
    travel.time = s.charge_travel_time ? r2((roundTrips / AVG_MPH) * N(s.travel_hourly_rate)) : 0;
    travel.total = r2(travel.mileage + travel.time);
    if (oneWay > N(s.service_radius_miles)) {
      warnings.push(`About ${Math.round(oneWay)} miles from ${origin.label.replace(' (nearest builder)', '')}, outside the ${N(s.service_radius_miles)}-mile service area.`);
    }
  }
  return travel;
}

async function calculateEstimate({ templateId, quantity, accessIds = [], postcode, urgent = false, skipTravel = false, builderId = null }) {
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const t = (await query('SELECT * FROM job_templates WHERE id = $1', [templateId])).rows[0];
  if (!t) return null;
  const warnings = [];

  const mats = (await query(
    `SELECT tm.qty_per_unit, p.name, p.unit, p.price, p.cut_material, p.active, sp.name AS supplier
     FROM template_materials tm JOIN price_items p ON p.id = tm.price_item_id
     LEFT JOIN suppliers sp ON sp.id = p.supplier_id
     WHERE tm.template_id = $1 ORDER BY tm.id`, [t.id])).rows;
  const ids = (accessIds || []).map(Number).filter(Number.isInteger);
  const access = ids.length
    ? (await query('SELECT id, label, multiplier FROM access_options WHERE id = ANY($1::int[]) AND active ORDER BY id', [ids])).rows
    : [];

  const qty = t.quantity_question ? Math.max(N(quantity), 0) : 1;

  // Materials
  const lines = mats.map((m) => {
    const base = N(m.qty_per_unit) * qty;
    const q = m.cut_material ? base * (1 + pct(s.waste_pct)) : base;
    if (!m.active) warnings.push(`${m.name} is switched off in the price list but is still in this template.`);
    return { name: m.name, supplier: m.supplier, unit: m.unit, qty: r2(q), price: N(m.price), cost: r2(q * N(m.price)), cut: m.cut_material };
  });
  const materialsCost = r2(lines.reduce((a, l) => a + l.cost, 0));
  const markup = t.materials_included ? 0 : r2(materialsCost * pct(s.markup_pct));
  const materialsCharge = t.materials_included ? 0 : r2(materialsCost + markup);

  // Labour
  const crew = t.crew ? N(t.crew) : N(s.default_crew) || 1;
  const units = N(t.labour_setup) + N(t.labour_per_unit) * qty;
  const accessFactor = access.reduce((f, a) => f * N(a.multiplier), 1);
  let labourBase;
  let labourText;
  let visits;
  let labourQty;
  let labourUnit;
  let labourRate;
  let estimatedHours;
  if (t.pricing_method === 'day') {
    const days = Math.max(0.5, Math.ceil(units * accessFactor * 2) / 2);
    labourBase = days * crew * N(s.day_rate);
    labourText = `${days} day${days === 1 ? '' : 's'} × ${crew} ${crew === 1 ? 'person' : 'people'} × ${money(s.day_rate, s.currency)}`;
    visits = Math.ceil(days);
    labourQty = days * crew; labourUnit = 'days'; labourRate = N(s.day_rate);
    estimatedHours = r2(days * crew * (N(s.hours_per_day) || 8));
  } else if (t.pricing_method === 'fixed') {
    labourBase = units * accessFactor;
    labourText = 'Fixed price' + (accessFactor !== 1 ? ` × access ${r2(accessFactor)}` : '');
    visits = 1;
    labourQty = 1; labourUnit = 'job'; labourRate = r2(labourBase);
    estimatedHours = null;
  } else {
    const hours = r2(units * accessFactor);
    labourBase = hours * crew * N(s.hourly_rate);
    labourText = `${hours} hr${hours === 1 ? '' : 's'} × ${crew} ${crew === 1 ? 'person' : 'people'} × ${money(s.hourly_rate, s.currency)}`;
    visits = Math.max(1, Math.ceil(hours / (N(s.hours_per_day) || 8)));
    labourQty = r2(hours * crew); labourUnit = 'hrs'; labourRate = N(s.hourly_rate);
    estimatedHours = labourQty;
  }
  labourBase = r2(labourBase);
  const urgentPremium = urgent ? r2(labourBase * pct(s.urgent_premium_pct)) : 0;
  const labour = r2(labourBase + urgentPremium);

  // Travel
  const travel = skipTravel
    ? { from: null, fromPostcode: null, oneWayMiles: null, visits, mileage: 0, time: 0, total: 0 }
    : await computeTravel({ s, postcode, builderId, visits, warnings });

  // Totals
  const subtotal = r2(materialsCharge + labour + travel.total);
  const contingency = r2(subtotal * pct(s.contingency_pct));
  let net = r2(subtotal + contingency);
  let minimumApplied = false;
  if (net < N(s.minimum_charge)) {
    net = N(s.minimum_charge);
    minimumApplied = true;
  }
  const vat = s.vat_registered ? r2(net * pct(s.vat_rate)) : 0;
  const total = r2(net + vat);
  const lowPct = t.range_low_pct !== null ? N(t.range_low_pct) : N(s.range_low_pct);
  const highPct = t.range_high_pct !== null ? N(t.range_high_pct) : N(s.range_high_pct);
  const low = Math.max(0, Math.floor((total * (1 - lowPct / 100)) / 5) * 5);
  const high = Math.ceil((total * (1 + highPct / 100)) / 5) * 5;

  return {
    template: { id: t.id, name: t.name, pricing_method: t.pricing_method },
    quantity: qty,
    quantity_unit: t.quantity_unit,
    access: access.map((a) => ({ label: a.label, multiplier: N(a.multiplier) })),
    urgent,
    crew,
    materials: { lines, cost: materialsCost, markup, markupPct: N(s.markup_pct), included: t.materials_included, charge: materialsCharge },
    labour: { text: labourText, accessFactor: r2(accessFactor), base: labourBase, urgentPremium, total: labour, qty: labourQty, unit: labourUnit, rate: labourRate, estimatedHours },
    travel,
    subtotal,
    contingency,
    contingencyPct: N(s.contingency_pct),
    minimumApplied,
    minimumCharge: N(s.minimum_charge),
    net,
    vat,
    vatRate: s.vat_registered ? N(s.vat_rate) : 0,
    total,
    low,
    high,
    currency: s.currency,
    warnings,
    generated_at: new Date().toISOString(),
  };
}

function customerSummary(e) {
  return `${money(e.low, e.currency)} to ${money(e.high, e.currency)}${e.vat ? ' including VAT' : ''}`;
}

// Full working, for the office and builders.
function renderBreakdown(e) {
  const m = (n) => money(n, e.currency);
  const matRows = e.materials.lines.map((l) =>
    `<tr><td>${esc(l.name)}${l.supplier ? ` <span class="muted">(${esc(l.supplier)})</span>` : ''}</td><td>${l.qty} ${esc(l.unit)}${l.cut ? ' incl. waste' : ''}</td><td class="num">${m(l.cost)}</td></tr>`
  ).join('');
  const row = (label, value, cls = '') => `<tr class="${cls}"><td colspan="2">${label}</td><td class="num">${value}</td></tr>`;
  return `<div class="scroll"><table class="breakdown">
    <tbody>
      <tr class="group"><th colspan="3">Materials${e.materials.included ? ' (included in fixed price)' : ''}</th></tr>
      ${matRows || '<tr><td colspan="3" class="muted">No materials in this template</td></tr>'}
      ${e.materials.included ? '' : row(`Markup ${e.materials.markupPct}%`, m(e.materials.markup))}
      ${row('Materials total', m(e.materials.charge), 'sum')}
      <tr class="group"><th colspan="3">Labour</th></tr>
      ${row(esc(e.labour.text), m(e.labour.base))}
      ${e.access.length ? row(`Access: ${esc(e.access.map((a) => `${a.label} ×${a.multiplier}`).join(', '))}`, 'included above') : ''}
      ${e.labour.urgentPremium ? row('Urgent premium', m(e.labour.urgentPremium)) : ''}
      ${row('Labour total', m(e.labour.total), 'sum')}
      <tr class="group"><th colspan="3">Travel</th></tr>
      ${e.travel.oneWayMiles === null
        ? row('<span class="muted">Not included</span>', m(0))
        : `${e.travel.from ? row(`From ${esc(e.travel.from)}, ${esc(e.travel.fromPostcode)}`, '') : ''}
           ${row(`${e.travel.oneWayMiles} miles each way × ${e.travel.visits} visit${e.travel.visits === 1 ? '' : 's'}, mileage`, m(e.travel.mileage))}
           ${e.travel.time ? row('Travel time', m(e.travel.time)) : ''}`}
      ${row('Travel total', m(e.travel.total), 'sum')}
      <tr class="group"><th colspan="3">Totals</th></tr>
      ${row('Subtotal', m(e.subtotal))}
      ${row(`Contingency ${e.contingencyPct}%`, m(e.contingency))}
      ${e.minimumApplied ? row(`Raised to minimum charge`, m(e.minimumCharge)) : ''}
      ${row('Net', m(e.net), 'sum')}
      ${e.vat ? row(`VAT ${e.vatRate}%`, m(e.vat)) : ''}
      ${row('Estimate', m(e.total), 'grand')}
      ${row('Range shown to customer', `${m(e.low)} to ${m(e.high)}`)}
    </tbody></table></div>
    ${e.warnings.length ? `<ul class="warnings">${e.warnings.map((w) => `<li>${esc(w)}</li>`).join('')}</ul>` : ''}`;
}

module.exports = { calculateEstimate, computeTravel, customerSummary, renderBreakdown, money, locate };
HANDYTRIO_EOF

cat > src/routes/onsite.js <<'HANDYTRIO_EOF'
// Behind-the-scenes tools for the office and builders: the working estimate (worksheet) and time tracking.
// Customers never see any of this.
const express = require('express');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { when } = require('../format');
const { money, computeTravel } = require('../estimate');
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

// ---------------- Travel on the worksheet ----------------
// Visits are worked out from the labour lines: hours ÷ crew ÷ hours per day, or days ÷ crew.
async function suggestedVisits(lines) {
  const s = (await query('SELECT hours_per_day, default_crew FROM settings WHERE id = 1')).rows[0];
  const crew = N(s.default_crew) || 1;
  let hours = 0;
  let days = 0;
  for (const l of lines.filter((x) => x.category === 'labour')) {
    if (/^h(ou)?rs?$/i.test(l.unit || '')) hours += N(l.qty);
    else if (/^days?$/i.test(l.unit || '')) days += N(l.qty);
  }
  const fromHours = hours ? hours / crew / (N(s.hours_per_day) || 8) : 0;
  return Math.max(1, Math.ceil(fromHours + days / crew - 1e-9));
}

async function travelLinesFor(job, visits) {
  const warnings = [];
  const t = await computeTravel({ postcode: job.postcode, builderId: job.assigned_builder_id, visits, warnings });
  const lines = [];
  if (t.mileage) {
    lines.push({ category: 'travel', description: `Mileage from ${t.from}: ${t.oneWayMiles} miles each way × ${visits} visit${visits === 1 ? '' : 's'}`, qty: 1, unit: 'job', unit_price: t.mileage });
  }
  if (t.time) lines.push({ category: 'travel', description: `Travel time, ${visits} visit${visits === 1 ? '' : 's'}`, qty: 1, unit: 'job', unit_price: t.time });
  return { lines, warnings };
}

// Swaps the worksheet's travel lines for freshly worked-out ones. Returns any warnings.
async function refreshWorksheetTravel(job, userId, visits) {
  const current = await loadLines(job.id);
  const v = visits || (await suggestedVisits(current));
  const { lines: travel, warnings } = await travelLinesFor(job, v);
  const kept = current.filter((l) => l.category !== 'travel')
    .map((l) => ({ category: l.category, description: l.description, qty: N(l.qty), unit: l.unit, unit_price: N(l.unit_price) }));
  // Travel goes after labour, before "other" lines such as contingency.
  const otherAt = kept.findIndex((l) => l.category === 'other');
  const merged = otherAt === -1 ? [...kept, ...travel] : [...kept.slice(0, otherAt), ...travel, ...kept.slice(otherAt)];
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await replaceLines(client, job.id, merged, userId, null);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  return warnings;
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
        <form method="post" action="/jobs/${job.id}/worksheet/blank" class="inline"><button>Start blank</button></form>
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
      <h2>Travel</h2>
      <form method="post" action="/jobs/${job.id}/worksheet/travel" class="panel">
        <p>${job.builder_name ? `Worked out from ${esc(job.builder_name)}’s home.` : 'No builder assigned yet, so worked out from the nearest builder’s home.'}</p>
        <label>Number of visits<input name="visits" type="number" min="1" max="60" step="1" value="${await suggestedVisits(lines)}" required></label>
        <p class="hint">Suggested from the labour lines. Change it if the job needs more or fewer trips.</p>
        <button class="small">Update travel lines</button>
      </form>
    </section>
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
  res.send(page({
    title: `Working estimate: ${job.title}`, user: req.user,
    notice: req.query.saved ? 'Working estimate saved.' : null,
    error: req.query.warn ? String(req.query.warn).slice(0, 400) : null, body,
  }));
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
  // Re-work travel so it starts from the assigned builder's home today.
  const warnings = await refreshWorksheetTravel(job, req.user.id, job.estimate_snapshot.travel && job.estimate_snapshot.travel.visits);
  res.redirect(`/jobs/${job.id}/worksheet?saved=1${warnings.length ? '&warn=' + encodeURIComponent(warnings.join(' ')) : ''}`);
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

router.post('/jobs/:id/worksheet/blank', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const warnings = await refreshWorksheetTravel(job, req.user.id, 1);
  res.redirect(`/jobs/${job.id}/worksheet?saved=1${warnings.length ? '&warn=' + encodeURIComponent(warnings.join(' ')) : ''}`);
}));

router.post('/jobs/:id/worksheet/travel', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const visits = Math.min(60, Math.max(1, Math.round(N(req.body.visits)) || 1));
  const warnings = await refreshWorksheetTravel(job, req.user.id, visits);
  res.redirect(`/jobs/${job.id}/worksheet?saved=1${warnings.length ? '&warn=' + encodeURIComponent(warnings.join(' ')) : ''}`);
}));

module.exports = { router, worksheetPanel, timePanel, refreshWorksheetTravel };
HANDYTRIO_EOF

cat > src/routes/jobs.js <<'HANDYTRIO_EOF'
const express = require('express');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const multer = require('multer');
const { pool, query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { STATUSES, label } = require('../statuses');
const { ref, day, when, WORK_TYPES } = require('../format');
const { calculateEstimate, customerSummary, renderBreakdown } = require('../estimate');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange } = require('../notify');
const onsite = require('./onsite');
const quotes = require('./quotes');

const router = express.Router();

// ---------- Photo uploads ----------
const UPLOAD_DIR = path.join(__dirname, '..', '..', 'uploads');
fs.mkdirSync(UPLOAD_DIR, { recursive: true });
const MAX_PHOTOS = 8;
const MAX_MB = 15;

const upload = multer({
  storage: multer.diskStorage({
    destination: UPLOAD_DIR,
    filename: (req, file, cb) => {
      const ext = path.extname(file.originalname || '').toLowerCase().replace(/[^.a-z0-9]/g, '').slice(0, 6);
      cb(null, crypto.randomUUID() + ext);
    },
  }),
  limits: { fileSize: MAX_MB * 1024 * 1024, files: MAX_PHOTOS, fields: 30 },
  fileFilter: (req, file, cb) => cb(null, /^image\//.test(file.mimetype)),
});

// Runs multer but turns its errors into a friendly message instead of a crash.
function photoUpload(req, res, next) {
  upload.array('photos', MAX_PHOTOS)(req, res, (err) => {
    if (err) {
      req.uploadError =
        err.code === 'LIMIT_FILE_SIZE' ? `Each photo must be under ${MAX_MB} MB.`
        : err.code === 'LIMIT_FILE_COUNT' || err.code === 'LIMIT_UNEXPECTED_FILE' ? `You can add up to ${MAX_PHOTOS} photos.`
        : 'The photos couldn’t be uploaded. Try again.';
    }
    req.files = req.files || [];
    next();
  });
}

const removeFiles = (files) => (files || []).forEach((f) => fs.unlink(f.path, () => {}));

async function savePhotos(client, jobId, files, userId) {
  for (const f of files) {
    await client.query(
      'INSERT INTO job_photos (job_id, stored_name, original_name, mime_type, size_bytes, uploaded_by) VALUES ($1, $2, $3, $4, $5, $6)',
      [jobId, f.filename, f.originalname, f.mimetype, f.size, userId]
    );
  }
}

// ---------- New job request (customers) ----------
const todayISO = () => new Date().toISOString().slice(0, 10);
const asArray = (v) => (v === undefined ? [] : Array.isArray(v) ? v : [v]);

async function activeTemplate(id) {
  const n = Number(id);
  if (!Number.isInteger(n) || n < 1) return null;
  return (await query('SELECT * FROM job_templates WHERE id = $1 AND active', [n])).rows[0] || null;
}

function chooser(templates) {
  const groups = {};
  for (const t of templates) (groups[t.work_type || 'Other jobs'] ||= []).push(t);
  return `<p class="lead">Pick the job that fits best. You’ll get a price guide straight away.</p>
  ${Object.entries(groups).map(([g, ts]) => `<h2>${esc(g)}</h2>
    <div class="choices">${ts.map((t) => `<a class="choice" href="/jobs/new?t=${t.id}"><strong>${esc(t.name)}</strong>${t.description ? `<span>${esc(t.description)}</span>` : ''}</a>`).join('')}</div>`).join('')}
  <h2>Not listed?</h2>
  <div class="choices"><a class="choice" href="/jobs/new?t=other"><strong>Something else</strong><span>Describe the job and we’ll arrange a visit to price it.</span></a></div>`;
}

function requestForm(v, s, t, accessOptions) {
  const opt = (w) => `<option ${v.work_type === w ? 'selected' : ''}>${esc(w)}</option>`;
  const chosen = asArray(v.access).map(String);
  return `<form method="post" action="/jobs" enctype="multipart/form-data" class="request">
  <input type="hidden" name="template_id" value="${t ? t.id : 'other'}">
  <fieldset class="panel">
    <legend>The job</legend>
    ${t ? `<p class="picked"><strong>${esc(t.name)}</strong> <a href="/jobs/new">Change</a></p>` : ''}
    <label>${t ? 'Job title (change it if you like)' : 'What do you need doing?'}<input name="title" value="${esc(v.title)}" maxlength="120" required placeholder="For example: replace a rotten fence post"></label>
    ${t ? '' : `<label>Type of work<select name="work_type" required>${WORK_TYPES.map(opt).join('')}</select></label>`}
    ${t && t.quantity_question ? `<label>${esc(t.quantity_question)}<input name="quantity" type="number" min="0.5" step="0.5" max="${esc(t.max_quantity)}" value="${esc(v.quantity || '')}" required></label>` : ''}
    <label>Describe the job<textarea name="description" rows="5" maxlength="4000" placeholder="Sizes, materials, what’s wrong, anything you’ve already bought">${esc(v.description)}</textarea></label>
    <label>Photos (up to ${MAX_PHOTOS})<input type="file" name="photos" accept="image/*" multiple></label>
    <p class="hint">Photos of the area and any damage help us price it accurately.</p>
  </fieldset>
  <fieldset class="panel">
    <legend>Where</legend>
    <label>Address<input name="address_line" value="${esc(v.address_line)}" required autocomplete="street-address"></label>
    <div class="row">
      <label>Town<input name="town" value="${esc(v.town)}" autocomplete="address-level2"></label>
      <label>Postcode<input name="postcode" value="${esc(v.postcode)}" required autocomplete="postal-code"></label>
    </div>
    ${t && accessOptions.length ? `<p class="fieldlabel">Anything that makes access harder?</p>
      ${accessOptions.map((a) => `<label class="check"><input type="checkbox" name="access" value="${a.id}" ${chosen.includes(String(a.id)) ? 'checked' : ''}> ${esc(a.label)}</label>`).join('')}` : ''}
    <label>Access information<textarea name="access_info" rows="3" maxlength="2000" placeholder="Parking, key safe or who lets us in, pets">${esc(v.access_info)}</textarea></label>
  </fieldset>
  <fieldset class="panel">
    <legend>When</legend>
    <div class="row">
      <label>Earliest start<input type="date" name="preferred_start" value="${esc(v.preferred_start)}" min="${todayISO()}" required></label>
      <label>Finished by (optional)<input type="date" name="preferred_end" value="${esc(v.preferred_end)}" min="${todayISO()}"></label>
    </div>
    <p class="hint">Jobs needed within ${esc(s.urgent_within_hours)} hours are treated as urgent and cost more.</p>
  </fieldset>
  <button class="primary">${t ? 'Send and see my price guide' : 'Send job request'}</button>
</form>`;
}

router.get('/jobs/new', requireRole('customer'), wrap(async (req, res) => {
  const pick = req.query.t;
  if (!pick) {
    const templates = (await query('SELECT id, name, description, work_type FROM job_templates WHERE active ORDER BY work_type, name')).rows;
    if (!templates.length) return res.redirect('/jobs/new?t=other');
    return res.send(page({ title: 'Request a job', user: req.user, body: chooser(templates) }));
  }
  const t = pick === 'other' ? null : await activeTemplate(pick);
  if (pick !== 'other' && !t) return res.redirect('/jobs/new');
  const me = (await query('SELECT address_line, town, postcode FROM users WHERE id = $1', [req.user.id])).rows[0];
  const s = (await query('SELECT urgent_within_hours FROM settings WHERE id = 1')).rows[0];
  const access = t ? (await query('SELECT id, label FROM access_options WHERE active ORDER BY id')).rows : [];
  const v = { ...me, title: t ? t.name : '', work_type: 'Something else' };
  res.send(page({ title: 'Request a job', user: req.user, body: requestForm(v, s, t, access) }));
}));

router.post('/jobs', requireRole('customer'), photoUpload, wrap(async (req, res) => {
  const v = {};
  for (const k of ['title', 'work_type', 'description', 'address_line', 'town', 'postcode', 'access_info', 'preferred_start', 'preferred_end', 'quantity']) {
    v[k] = String(req.body[k] || '').trim();
  }
  v.postcode = v.postcode.toUpperCase();
  v.access = asArray(req.body.access);
  const s = (await query('SELECT urgent_within_hours FROM settings WHERE id = 1')).rows[0];
  const isDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d) && !Number.isNaN(Date.parse(d));

  const isOther = req.body.template_id === 'other';
  const t = isOther ? null : await activeTemplate(req.body.template_id);
  if (!isOther && !t) { removeFiles(req.files); return res.redirect('/jobs/new'); }
  if (t) v.work_type = t.work_type || 'Something else';
  const accessOptions = t ? (await query('SELECT id, label FROM access_options WHERE active ORDER BY id')).rows : [];
  const accessIds = v.access.map(Number).filter((id) => accessOptions.some((a) => a.id === id));
  const qty = t && t.quantity_question ? Number(v.quantity) : 1;

  let error = req.uploadError || null;
  if (!error) {
    if (!v.title) error = 'Give the job a title.';
    else if (!WORK_TYPES.includes(v.work_type)) error = 'Choose the type of work.';
    else if (t && t.quantity_question && (!(qty > 0) || qty > Number(t.max_quantity))) error = `Answer “${t.quantity_question}” with a number from 0.5 to ${Number(t.max_quantity)}. For bigger jobs, choose Something else.`;
    else if (!v.address_line || !v.postcode) error = 'Enter the address and postcode for the job.';
    else if (!isDate(v.preferred_start) || v.preferred_start < todayISO()) error = 'Choose an earliest start date from today onwards.';
    else if (v.preferred_end && (!isDate(v.preferred_end) || v.preferred_end < v.preferred_start)) error = 'The finish date must be on or after the start date.';
  }
  if (error) {
    removeFiles(req.files);
    return res.status(400).send(page({ title: 'Request a job', user: req.user, error, body: requestForm(v, s, t, accessOptions) }));
  }

  const hoursAhead = (Date.parse(v.preferred_start) - Date.parse(todayISO())) / 3600000;
  const urgent = hoursAhead < Number(s.urgent_within_hours);

  let estimate = null;
  if (t) {
    try {
      estimate = await calculateEstimate({ templateId: t.id, quantity: qty, accessIds, postcode: v.postcode, urgent });
    } catch (e) {
      console.error('Estimate failed:', e);
    }
  }
  const status = isOther ? 'inspection_required' : 'request';

  const client = await pool.connect();
  let jobId;
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `INSERT INTO jobs (customer_id, title, work_type, description, address_line, town, postcode, access_info,
         preferred_start, preferred_end, urgent, status, template_id, quantity, access_option_ids)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15) RETURNING id`,
      [req.user.id, v.title, v.work_type, v.description || null, v.address_line, v.town || null, v.postcode,
        v.access_info || null, v.preferred_start, v.preferred_end || null, urgent, status,
        t ? t.id : null, t ? qty : null, accessIds]
    );
    jobId = rows[0].id;
    await client.query(
      'INSERT INTO job_status_history (job_id, from_status, to_status, changed_by, note) VALUES ($1, NULL, $2, $3, $4)',
      [jobId, status, req.user.id, 'Request sent by customer']
    );
    if (estimate) {
      await client.query('UPDATE jobs SET estimate_low = $1, estimate_high = $2, estimate_snapshot = $3 WHERE id = $4',
        [estimate.low, estimate.high, JSON.stringify(estimate), jobId]);
      await setStatus(client, jobId, status, 'estimated', null, 'Price guide worked out automatically');
    }
    await savePhotos(client, jobId, req.files, req.user.id);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    removeFiles(req.files);
    throw e;
  } finally {
    client.release();
  }
  await notifyStageChange(jobId, estimate ? 'estimated' : status, baseUrlOf(req));
  res.redirect(`/jobs/${jobId}?sent=1`);
}));

// ---------- Job page ----------
router.get('/jobs/:id', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const user = req.user;

  const photos = (await query('SELECT id, original_name FROM job_photos WHERE job_id = $1 ORDER BY id', [job.id])).rows;
  const history = (await query(
    `SELECT h.*, u.name AS by_name FROM job_status_history h LEFT JOIN users u ON u.id = h.changed_by
     WHERE h.job_id = $1 ORDER BY h.created_at DESC, h.id DESC`, [job.id])).rows;

  const address = [job.address_line, job.town, job.postcode].filter(Boolean).join(', ');
  const mapsUrl = 'https://www.google.com/maps/dir/?api=1&destination=' + encodeURIComponent(address);

  const photoGrid = photos.length
    ? `<div class="photos">${photos.map((p) => `<a href="/jobs/${job.id}/photos/${p.id}" target="_blank" rel="noopener"><img src="/jobs/${job.id}/photos/${p.id}" alt="${esc(p.original_name || 'Job photo')}" loading="lazy"></a>`).join('')}</div>`
    : '<p class="empty">No photos yet.</p>';

  const addPhotos = photos.length < MAX_PHOTOS && !['paid', 'cancelled', 'declined'].includes(job.status)
    ? `<form method="post" action="/jobs/${job.id}/photos" enctype="multipart/form-data" class="inline-form">
        <input type="file" name="photos" accept="image/*" multiple required>
        <button class="small">Add photos</button>
      </form>` : '';

  let actions = '';
  if (user.role === 'customer' && ['request', 'inspection_required', 'estimated'].includes(job.status)) {
    actions = `<form method="post" action="/jobs/${job.id}/cancel" class="panel">
      <p>Changed your mind? You can cancel this request until an inspection is booked.</p>
      <button class="small danger">Cancel this request</button></form>`;
  }
  if (user.role === 'admin') {
    const builders = (await query("SELECT id, name FROM users WHERE role = 'builder' AND active ORDER BY name")).rows;
    actions = `<div class="admin-actions">
      <form method="post" action="/jobs/${job.id}/assign" class="panel">
        <label>Builder<select name="builder_id">
          <option value="">Not assigned</option>
          ${builders.map((b) => `<option value="${b.id}" ${b.id === job.assigned_builder_id ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}
        </select></label>
        <p class="hint">Saving re-prices travel on the price guide and working estimate from this builder’s home, until a quote is sent.</p>
        <button class="small">Save builder</button>
      </form>
      <form method="post" action="/jobs/${job.id}/status" class="panel">
        <label>Move to stage<select name="status">
          ${STATUSES.map(([k, l]) => `<option value="${k}" ${k === job.status ? 'selected' : ''}>${esc(l)}</option>`).join('')}
        </select></label>
        <label>Note for the office (optional)<input name="note" maxlength="500"></label>
        <p class="hint">The customer gets an email about the new stage. They never see this note.</p>
        <button class="small">Update stage</button>
      </form>
    </div>`;
  }

  const e = job.estimate_snapshot;
  const quote = await quotes.currentQuote(job.id);
  let estimatePanel = '';
  if (e && !(quote && user.role === 'customer')) {
    estimatePanel = `<section class="panel callout estimate">
      <h2>Price guide</h2>
      <p class="bigprice">${esc(customerSummary(e))}</p>
      <p>${user.role === 'customer'
        ? 'This is a guide based on what you’ve told us. We’ll confirm the exact price after we’ve seen the job.'
        : `${esc(e.template.name)}${e.quantity_unit ? `, ${e.quantity} ${esc(e.quantity_unit)}` : ''}. Worked out ${when(e.generated_at)}.`}</p>
      ${user.role !== 'customer' ? `<details ${user.role === 'admin' ? 'open' : ''}><summary>How this was worked out</summary>${renderBreakdown(e)}</details>` : ''}
      ${user.role === 'admin' && job.template_id ? `<form method="post" action="/jobs/${job.id}/estimate" class="inline"><button class="small">Recalculate with today’s prices</button></form>` : ''}
    </section>`;
  } else if (job.status === 'inspection_required') {
    estimatePanel = `<section class="panel callout"><h2>Price</h2><p>${user.role === 'customer'
      ? 'This job needs a visit before we can price it. We’ll be in touch to arrange an inspection.'
      : 'Not a standard job, so no automatic estimate. Book an inspection to price it.'}</p></section>`;
  }

  const notice = req.query.sent ? 'Job request sent. We’ll review it and be in touch.'
    : req.query.updated ? 'Job updated.' : req.query.photos ? 'Photos added.' : null;
  const error = req.query.photoerror || req.query.error ? String(req.query.photoerror || req.query.error).slice(0, 160) : null;

  const body = `
  <p class="jobhead"><span class="ref">${ref(job.id)}</span> <span class="tag">${esc(label(job.status))}</span>
    ${job.urgent ? '<span class="tag urgent">Urgent</span>' : ''}</p>
  ${await quotes.quotePanel(job, user)}
  ${estimatePanel}
  <div class="jobgrid">
    <section class="panel">
      <h2>The job</h2>
      <dl>
        <dt>Type of work</dt><dd>${esc(job.work_type || 'Not given')}</dd>
        <dt>Details</dt><dd class="pre">${esc(job.description || 'No details given')}</dd>
        <dt>Wanted from</dt><dd>${day(job.preferred_start)}${job.preferred_end ? ` to ${day(job.preferred_end)}` : ''}</dd>
        ${user.role !== 'customer' ? `<dt>Builder</dt><dd>${esc(job.builder_name || 'Not assigned')}</dd>` : ''}
      </dl>
    </section>
    <section class="panel">
      <h2>Where</h2>
      <dl>
        <dt>Address</dt><dd>${esc(address)}</dd>
        <dt>Access</dt><dd class="pre">${esc(job.access_info || 'No access notes')}</dd>
        ${user.role !== 'customer' ? `<dt>Customer</dt><dd>${esc(job.customer_name)}<br>${job.customer_phone ? `<a href="tel:${esc(job.customer_phone)}">${esc(job.customer_phone)}</a><br>` : ''}<a href="mailto:${esc(job.customer_email)}">${esc(job.customer_email)}</a></dd>` : ''}
      </dl>
      ${user.role !== 'customer' ? `<p><a class="button" href="${esc(mapsUrl)}" target="_blank" rel="noopener">Directions</a></p>` : ''}
    </section>
  </div>
  ${await onsite.worksheetPanel(job, user)}
  <div id="time">${await onsite.timePanel(job, user)}</div>
  <h2>Photos</h2>
  ${photoGrid}
  ${addPhotos}
  ${actions}
  <h2>History</h2>
  <ol class="history">${history.map((h) => `<li><strong>${esc(label(h.to_status))}</strong> <span class="muted">${when(h.created_at)}${user.role !== 'customer' && h.by_name ? `, ${esc(h.by_name)}` : ''}</span>${user.role !== 'customer' && h.note ? `<br>${esc(h.note)}` : ''}</li>`).join('')}</ol>
  <p><a href="/dashboard">Back to dashboard</a></p>`;

  res.send(page({ title: job.title, user, notice, error, body }));
}));

// ---------- Photo file ----------
router.get('/jobs/:id/photos/:photoId', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return res.sendStatus(404);
  const { rows } = await query('SELECT stored_name, mime_type FROM job_photos WHERE id = $1 AND job_id = $2', [Number(req.params.photoId) || 0, job.id]);
  if (!rows[0]) return res.sendStatus(404);
  res.set('Cache-Control', 'private, max-age=86400');
  res.type(rows[0].mime_type);
  res.sendFile(path.join(UPLOAD_DIR, path.basename(rows[0].stored_name)), (err) => {
    if (err && !res.headersSent) res.sendStatus(404);
  });
}));

router.post('/jobs/:id/photos', requireLogin, photoUpload, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) { removeFiles(req.files); return notFound(req, res); }
  const count = (await query('SELECT count(*)::int AS n FROM job_photos WHERE job_id = $1', [job.id])).rows[0].n;
  let error = req.uploadError;
  if (!error && !req.files.length) error = 'Choose at least one photo.';
  if (!error && count + req.files.length > MAX_PHOTOS) error = `A job can have up to ${MAX_PHOTOS} photos. It has ${count} already.`;
  if (error) {
    removeFiles(req.files);
    return res.redirect(`/jobs/${job.id}?photoerror=${encodeURIComponent(error)}`);
  }
  const client = await pool.connect();
  try {
    await savePhotos(client, job.id, req.files, req.user.id);
  } catch (e) {
    removeFiles(req.files);
    throw e;
  } finally {
    client.release();
  }
  res.redirect(`/jobs/${job.id}?photos=1`);
}));

// ---------- Customer cancel ----------
router.post('/jobs/:id/cancel', requireRole('customer'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  if (['request', 'inspection_required', 'estimated'].includes(job.status)) {
    const client = await pool.connect();
    try {
      await setStatus(client, job.id, job.status, 'cancelled', req.user.id, 'Cancelled by customer');
    } finally {
      client.release();
    }
    await notifyStageChange(job.id, 'cancelled', baseUrlOf(req));
  }
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

// ---------- Admin: recalculate estimate ----------
const REPRICE_STAGES = ['request', 'estimated', 'inspection_required', 'inspection_booked', 'inspected'];

async function refreshEstimate(job, builderId, userId, baseUrl) {
  if (!job.template_id) return;
  const est = await calculateEstimate({
    templateId: job.template_id, quantity: job.quantity, accessIds: job.access_option_ids || [],
    postcode: job.postcode, urgent: job.urgent, builderId,
  });
  if (!est) return;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE jobs SET estimate_low = $1, estimate_high = $2, estimate_snapshot = $3, updated_at = now() WHERE id = $4',
      [est.low, est.high, JSON.stringify(est), job.id]);
    if (job.status === 'request') await setStatus(client, job.id, 'request', 'estimated', userId, 'Price guide worked out');
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  if (job.status === 'request') await notifyStageChange(job.id, 'estimated', baseUrl);
}

router.post('/jobs/:id/estimate', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  await refreshEstimate(job, job.assigned_builder_id, req.user.id, baseUrlOf(req));
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

// ---------- Admin: assign builder and move stage ----------
router.post('/jobs/:id/assign', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const builderId = req.body.builder_id ? Number(req.body.builder_id) : null;
  if (builderId !== null) {
    const ok = (await query("SELECT 1 FROM users WHERE id = $1 AND role = 'builder' AND active", [builderId])).rows.length;
    if (!ok) return res.redirect(`/jobs/${job.id}`);
  }
  await query('UPDATE jobs SET assigned_builder_id = $1, updated_at = now() WHERE id = $2', [builderId, job.id]);
  // Travel now comes from this builder's home, so re-price while the job is still at estimate stage.
  if (job.estimate_snapshot && REPRICE_STAGES.includes(job.status)) await refreshEstimate(job, builderId, req.user.id, baseUrlOf(req));
  // Same for the working estimate's travel lines, if one has been started.
  const hasWorksheet = (await query('SELECT 1 FROM job_estimate_lines WHERE job_id = $1 LIMIT 1', [job.id])).rows.length;
  if (hasWorksheet && REPRICE_STAGES.includes(job.status)) {
    await onsite.refreshWorksheetTravel({ ...job, assigned_builder_id: builderId }, req.user.id);
  }
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

router.post('/jobs/:id/status', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const to = String(req.body.status || '');
  if (to === 'quoted' && !(await quotes.currentQuote(job.id))) {
    return res.redirect(`/jobs/${job.id}?error=` + encodeURIComponent('Use “Send quote” under the working estimate, so the customer has a quote to see.'));
  }
  if (STATUSES.some(([k]) => k === to) && to !== job.status) {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await setStatus(client, job.id, job.status, to, req.user.id, String(req.body.note || '').trim().slice(0, 500));
      await client.query('COMMIT');
    } catch (e) {
      await client.query('ROLLBACK');
      throw e;
    } finally {
      client.release();
    }
    await notifyStageChange(job.id, to, baseUrlOf(req));
  }
  res.redirect(`/jobs/${job.id}?updated=1`);
}));

module.exports = router;
HANDYTRIO_EOF

touch src/server.js
echo ""
echo "Travel fix installed. The app restarts by itself; otherwise run: npm run dev"
