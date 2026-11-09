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
