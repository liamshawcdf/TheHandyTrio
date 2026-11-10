// Everything after a quote is accepted: deposit, parts, scheduling, the builder's route,
// completion, the final invoice and payments (recorded by the office or paid online with Stripe).
const express = require('express');
const { pool, query } = require('../db');
const { esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day, when } = require('../format');
const { money } = require('../estimate');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange, notifyOffice } = require('../notify');
const { currentQuote, displayLines, qref } = require('./quotes');
const { renderDocument } = require('../pdf');
const { loadAvailability, blockedDates } = require('../availability');

const router = express.Router();
const admin = requireRole('admin');
const staff = requireRole('admin', 'builder');
const N = (x) => Number(x) || 0;
const r2 = (n) => Math.round(n * 100) / 100;
const iref = (id) => 'INV-' + String(id).padStart(5, '0');
const todayISO = () => new Date().toISOString().slice(0, 10);
const isDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d || '') && !Number.isNaN(Date.parse(d));
const settings = async () => (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
const mayWork = (user, job) => user.role === 'admin' || (user.role === 'builder' && job.assigned_builder_id === user.id);
const stripeReady = () => Boolean(process.env.STRIPE_SECRET_KEY);
const back = (res, job, hash = '', msg = 'updated=1') => res.redirect(`/jobs/${job.id}?${msg}${hash}`);
const errorBack = (res, job, text, hash = '') => res.redirect(`/jobs/${job.id}?error=${encodeURIComponent(text)}${hash}`);

const ORDER = ['accepted', 'deposit_requested', 'deposit_paid', 'parts_ordered', 'scheduled', 'in_progress', 'complete', 'invoiced', 'paid'];
const before = (status, target) => ORDER.indexOf(status) !== -1 && ORDER.indexOf(status) < ORDER.indexOf(target);

async function inTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
}

// ======================= Payments =======================
async function paidOn(invoiceId, client = { query }) {
  return N((await client.query('SELECT coalesce(sum(amount), 0) AS n FROM payments WHERE invoice_id = $1', [invoiceId])).rows[0].n);
}

// Records a payment and moves the invoice and job on when it is fully paid. Returns the new job status, if any.
async function applyPayment({ invoice, job, amount, method, reference, userId, stripeSessionId = null, receivedAt = null }) {
  return inTransaction(async (client) => {
    await client.query(
      `INSERT INTO payments (job_id, invoice_id, amount, method, reference, stripe_session_id, received_at, recorded_by)
       VALUES ($1, $2, $3, $4, $5, $6, coalesce($7::timestamptz, now()), $8)`,
      [job.id, invoice.id, amount, method, reference || null, stripeSessionId, receivedAt, userId]);
    const paid = await paidOn(invoice.id, client);
    if (paid + 0.005 < N(invoice.amount_due)) return null;
    await client.query("UPDATE invoices SET status = 'paid', paid_at = now() WHERE id = $1", [invoice.id]);
    const target = invoice.kind === 'deposit' ? 'deposit_paid' : 'paid';
    if (before(job.status, target)) {
      await setStatus(client, job.id, job.status, target, userId, `${iref(invoice.id)} paid (${method})`);
      return target;
    }
    return null;
  });
}

async function afterPayment(req, job, invoice, newStatus, amount, method) {
  if (newStatus) await notifyStageChange(job.id, newStatus, baseUrlOf(req));
  const m = money(amount);
  const next = newStatus === 'deposit_paid' ? '\nNext: order the parts and schedule the job.\n' : newStatus === 'paid' ? '\nThe job is fully paid.\n' : '';
  await notifyOffice(`Payment received: ${m} for ${job.title} (${ref(job.id)})`,
    `${m} received by ${method} against ${iref(invoice.id)}.${next}\n${baseUrlOf(req)}/jobs/${job.id}`, job.id);
}

async function stripeApi(path, params = null) {
  const res = await fetch('https://api.stripe.com/v1/' + path, {
    method: params ? 'POST' : 'GET',
    headers: { Authorization: 'Bearer ' + process.env.STRIPE_SECRET_KEY, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: params ? new URLSearchParams(params).toString() : undefined,
    signal: AbortSignal.timeout(15000),
  });
  const data = await res.json();
  if (!res.ok) throw new Error((data.error && data.error.message) || 'Stripe error');
  return data;
}

async function loadInvoice(req, job) {
  return (await query('SELECT * FROM invoices WHERE id = $1 AND job_id = $2', [Number(req.params.iid) || 0, job.id])).rows[0] || null;
}

// ======================= Panels on the job page =======================
async function nextStepPanel(job, user) {
  if (user.role === 'customer') return '';
  const s = await settings();
  const m = (n) => money(n, s.currency);
  const parts = [];

  if (user.role === 'admin' && job.status === 'accepted') {
    const q = await currentQuote(job.id);
    const dep = q ? N(q.deposit) : 0;
    parts.push(`<h3>Request the deposit</h3>
      <form method="post" action="/jobs/${job.id}/deposit" class="inline-form">
        <label>Deposit amount (including VAT)<input name="amount" type="number" step="0.01" min="0.01" value="${dep.toFixed(2)}" required></label>
        <button class="primary">Send deposit request</button>
      </form>
      <form method="post" action="/jobs/${job.id}/skip-deposit" class="inline"><button class="small">No deposit needed, carry on</button></form>`);
  }

  if (user.role === 'admin' && ['deposit_paid', 'parts_ordered', 'scheduled'].includes(job.status)) {
    const builders = (await query("SELECT id, name FROM users WHERE role IN ('builder', 'manager') AND active ORDER BY name")).rows;
    const iso = (d) => (d ? new Date(d).toLocaleDateString('en-CA') : '');
    parts.push(`<h3>${job.status === 'scheduled' ? 'Change the booking' : 'Book the job in'}</h3>
      <form method="post" action="/jobs/${job.id}/schedule" class="schedule">
        <label>Builder<select name="builder_id" required>${builders.map((b) => `<option value="${b.id}" ${b.id === job.assigned_builder_id ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}</select></label>
        <label>Start<input type="date" name="start" value="${iso(job.scheduled_start)}" required></label>
        <label>Finish (optional)<input type="date" name="end" value="${iso(job.scheduled_end)}"></label>
        <label class="check"><input type="checkbox" name="override"> Book anyway, even if they’re off</label>
        <button class="primary">${job.status === 'scheduled' ? 'Save and tell the customer' : 'Book in and tell the customer'}</button>
      </form>`);
  }

  if (mayWork(user, job) && job.status === 'scheduled') {
    parts.push(`<h3>On the day</h3><form method="post" action="/jobs/${job.id}/start" class="inline"><button class="primary">Start the job</button></form>`);
  }

  if (mayWork(user, job) && job.status === 'in_progress') {
    parts.push(`<h3>Finished?</h3>
      <form method="post" action="/jobs/${job.id}/complete">
        <label>What was done, and anything the office should know<textarea name="note" rows="3" maxlength="2000"></textarea></label>
        <p class="hint">Add finished-work photos below first. This clocks you off and tells the customer and office the work is done.</p>
        <button class="primary">Mark work complete</button>
      </form>`);
  }

  if (user.role === 'admin' && job.status === 'complete') {
    const q = await currentQuote(job.id);
    const paid = N((await query('SELECT coalesce(sum(amount), 0) AS n FROM payments WHERE job_id = $1', [job.id])).rows[0].n);
    parts.push(`<h3>Send the final invoice</h3>
      ${job.completion_note ? `<p class="pre muted">Builder’s note: ${esc(job.completion_note)}</p>` : ''}
      <form method="post" action="/jobs/${job.id}/invoice">
        <p>Based on quote ${q ? `${qref(q.id)} (${m(q.total)})` : '(none found)'}, less ${m(paid)} already paid.</p>
        <p class="fieldlabel">Agreed extras (before VAT, optional)</p>
        ${[0, 1, 2].map((i) => `<div class="row"><label>Description<input name="x${i}_desc" maxlength="200"></label><label>Amount<input name="x${i}_amount" type="number" step="0.01" min="0"></label></div>`).join('')}
        <label>Note on the invoice (optional)<textarea name="note" rows="2" maxlength="1000"></textarea></label>
        <button class="primary">Send invoice</button>
      </form>`);
  }

  if (!parts.length) return '';
  return `<section class="panel nextstep staffonly"><h2>Next step <span class="tag">Office and builders only</span></h2>${parts.join('')}</section>`;
}

const PART_STATUS = { to_order: 'To order', ordered: 'Ordered', ready: 'Ready to collect', collected: 'Collected', delivered: 'Delivered to site' };

async function partsPanel(job, user) {
  if (user.role === 'customer' || !ORDER.includes(job.status) || job.status === 'accepted') return '';
  const rows = (await query(
    `SELECT p.*, s.name AS supplier_name FROM job_parts p LEFT JOIN suppliers s ON s.id = p.supplier_id WHERE p.job_id = $1 ORDER BY p.sort, p.id`, [job.id])).rows;
  const isAdmin = user.role === 'admin';
  if (!rows.length) {
    return isAdmin ? `<section class="panel staffonly"><h2>Parts <span class="tag">Office and builders only</span></h2>
      <p>Make an order list from the materials on the accepted quote.</p>
      <form method="post" action="/jobs/${job.id}/parts/from-quote" class="inline"><button class="primary">Make parts list</button></form>
      <form method="post" action="/jobs/${job.id}/parts" class="inline"><input type="hidden" name="count" value="0"><button class="small">Start an empty list</button></form>
    </section>` : '';
  }
  const suppliers = (await query('SELECT id, name FROM suppliers WHERE active ORDER BY name')).rows;
  const supSel = (i, sel) => `<select name="p${i}_supplier"><option value="">No supplier</option>${suppliers.map((s) => `<option value="${s.id}" ${s.id === sel ? 'selected' : ''}>${esc(s.name)}</option>`).join('')}</select>`;
  const statusSel = (i, sel) => `<select name="p${i}_status">${Object.entries(PART_STATUS).map(([k, l]) => `<option value="${k}" ${k === sel ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
  const count = rows.length + (isAdmin ? 2 : 0);
  const outstanding = rows.filter((p) => p.status === 'to_order').length;
  return `<section class="panel staffonly" id="parts"><h2>Parts <span class="tag">Office and builders only</span></h2>
    <p>${outstanding ? `<span class="tag urgent">${outstanding} still to order</span>` : '<span class="tag ok">All ordered</span>'}</p>
    <form method="post" action="/jobs/${job.id}/parts">
      <input type="hidden" name="count" value="${count}">
      ${rows.map((p, i) => `<div class="pline">
        <input type="hidden" name="p${i}_id" value="${p.id}">
        ${isAdmin ? `<label class="desc">Item<input name="p${i}_desc" value="${esc(p.description)}" maxlength="200"></label>
          <label>Qty<input name="p${i}_qty" type="number" step="0.01" min="0" value="${N(p.qty)}"></label>
          <label>Supplier${supSel(i, p.supplier_id)}</label>`
        : `<div class="desc"><strong>${esc(p.description)}</strong><br>${N(p.qty)} ${esc(p.unit)}${p.supplier_name ? `, ${esc(p.supplier_name)}` : ''}</div>`}
        <label>Status${statusSel(i, p.status)}</label>
        <label>Note<input name="p${i}_note" value="${esc(p.note)}" maxlength="200" placeholder="Order number, branch"></label>
        ${isAdmin ? `<label class="check del"><input type="checkbox" name="p${i}_del"> Remove</label>` : ''}
      </div>`).join('')}
      ${isAdmin ? [0, 1].map((k) => { const i = rows.length + k; return `<div class="pline new">
        <label class="desc">Item<input name="p${i}_desc" maxlength="200" placeholder="Add a part"></label>
        <label>Qty<input name="p${i}_qty" type="number" step="0.01" min="0" value="1"></label>
        <label>Supplier${supSel(i, null)}</label>
        <label>Status${statusSel(i, 'to_order')}</label>
        <label>Note<input name="p${i}_note" maxlength="200"></label><span></span>
      </div>`; }).join('') : ''}
      <button class="primary">Save parts</button>
    </form>
  </section>`;
}

async function routePanel(job, user) {
  if (user.role === 'customer' || !['deposit_paid', 'parts_ordered', 'scheduled', 'in_progress'].includes(job.status)) return '';
  const stops = (await query(
    `SELECT s.id, s.name, s.address, s.postcode,
       string_agg(p.description || ' x' || (p.qty::float8)::text, ', ' ORDER BY p.sort, p.id) AS items
     FROM job_parts p JOIN suppliers s ON s.id = p.supplier_id
     WHERE p.job_id = $1 AND p.status IN ('ordered', 'ready')
     GROUP BY s.id, s.name, s.address, s.postcode ORDER BY s.name`, [job.id])).rows;
  const jobAddress = [job.address_line, job.town, job.postcode].filter(Boolean).join(', ');
  const placeOf = (s) => [s.name, s.address, s.postcode].filter(Boolean).join(', ');
  const usable = stops.filter((s) => s.address || s.postcode);
  const url = 'https://www.google.com/maps/dir/?api=1&travelmode=driving&destination=' + encodeURIComponent(jobAddress)
    + (usable.length ? '&waypoints=' + encodeURIComponent(usable.map(placeOf).join('|')) : '');
  return `<section class="panel staffonly route"><h2>Route <span class="tag">Office and builders only</span></h2>
    <ol class="stops">
      ${stops.map((s) => `<li><strong>Collect from ${esc(s.name)}</strong>${s.address || s.postcode ? `<br>${esc([s.address, s.postcode].filter(Boolean).join(', '))}` : '<br><span class="muted">No address saved for this supplier</span>'}<br><span class="muted">${esc(s.items)}</span></li>`).join('')}
      <li><strong>Job</strong><br>${esc(jobAddress)}${job.scheduled_start ? `<br><span class="muted">Booked ${day(job.scheduled_start)}${job.scheduled_end ? ` to ${day(job.scheduled_end)}` : ''}</span>` : ''}</li>
    </ol>
    <a class="button primary" href="${esc(url)}" target="_blank" rel="noopener">Open route in Google Maps</a>
    <p class="hint">Starts from wherever the phone is. Parts marked Collected or Delivered drop off the route.</p>
  </section>`;
}

async function invoicesPanel(job, user, req) {
  const invoices = (await query(
    `SELECT * FROM invoices WHERE job_id = $1 ${user.role === 'customer' ? "AND status <> 'void'" : ''} ORDER BY id`, [job.id])).rows;
  if (!invoices.length) return '';
  const s = await settings();
  const m = (n) => money(n, s.currency);
  const payments = (await query('SELECT * FROM payments WHERE job_id = $1 ORDER BY received_at', [job.id])).rows;
  const out = [];
  for (const inv of invoices) {
    const paid = payments.filter((p) => p.invoice_id === inv.id).reduce((a, p) => a + N(p.amount), 0);
    const due = r2(Math.max(0, N(inv.amount_due) - paid));
    const overdue = inv.status === 'issued' && inv.due_date && new Date(inv.due_date) < new Date(new Date().toDateString());
    const label = inv.kind === 'deposit' ? 'Deposit invoice' : 'Invoice';
    const tag = inv.status === 'paid' ? '<span class="tag ok">Paid</span>' : inv.status === 'void' ? '<span class="tag">Cancelled</span>' : overdue ? '<span class="tag urgent">Overdue</span>' : '<span class="tag">Waiting for payment</span>';
    const canPayOnline = user.role === 'customer' && inv.status === 'issued' && due > 0 && stripeReady();
    out.push(`<div class="invoice ${inv.status}">
      <div class="quotehead"><h3>${label} ${iref(inv.id)}</h3>${tag}</div>
      <div class="wtotals">
        <div><span>Total</span><span>${m(inv.total)}</span></div>
        ${N(inv.less_paid) ? `<div><span>Less already paid</span><span>−${m(inv.less_paid)}</span></div>` : ''}
        ${paid ? `<div><span>Paid on this invoice</span><span>−${m(paid)}</span></div>` : ''}
        <div class="grand"><span>${inv.status === 'void' ? 'Cancelled' : 'Left to pay'}</span><span>${inv.status === 'void' ? '' : m(due)}</span></div>
        ${inv.due_date && inv.status === 'issued' ? `<div><span>Due by</span><span>${day(inv.due_date)}</span></div>` : ''}
      </div>
      <div class="buttons">
        <a class="button" href="/jobs/${job.id}/invoices/${inv.id}/pdf" target="_blank" rel="noopener">View or print</a>
        <a class="button" href="/jobs/${job.id}/invoices/${inv.id}/pdf?download=1">Download PDF</a>
        ${canPayOnline ? `<form method="post" action="/jobs/${job.id}/invoices/${inv.id}/pay" class="inline"><button class="primary">Pay ${m(due)} by card</button></form>` : ''}
      </div>
      ${user.role === 'customer' && inv.status === 'issued' && due > 0 ? `<div class="payhow">
        <p class="pre">${esc(s.payment_instructions)}</p>
        ${s.bank_details ? `<p class="pre"><strong>Bank details</strong>\n${esc(s.bank_details)}\nReference: ${ref(job.id)}</p>` : ''}
      </div>` : ''}
      ${user.role === 'admin' && inv.status === 'issued' ? `<details class="recordpay"><summary>Record a payment</summary>
        <form method="post" action="/jobs/${job.id}/invoices/${inv.id}/payments" class="panel">
          <div class="row">
            <label>Amount<input name="amount" type="number" step="0.01" min="0.01" value="${due.toFixed(2)}" required></label>
            <label>Date received<input name="date" type="date" value="${todayISO()}" required></label>
          </div>
          <label>How it was paid<select name="method">
            <option>Card over the phone</option><option>Bank transfer</option><option>Cash</option><option>Cheque</option><option>Card in person</option>
          </select></label>
          <label>Reference (optional)<input name="reference" maxlength="100"></label>
          <button class="primary">Record payment</button>
        </form>
        <form method="post" action="/jobs/${job.id}/invoices/${inv.id}/void" class="inline">
          <label class="check"><input type="checkbox" name="confirm" required> Cancel this invoice</label> <button class="small danger">Cancel invoice</button>
        </form>
      </details>` : ''}
    </div>`);
  }
  const payList = payments.length ? `<h3>Payments</h3><ul class="payments">${payments.map((p) => `<li>${day(p.received_at)}: ${m(p.amount)} by ${esc(p.method)}${user.role !== 'customer' && p.reference ? ` (${esc(p.reference)})` : ''}${p.invoice_id ? `, ${iref(p.invoice_id)}` : ''}</li>`).join('')}</ul>` : '';
  const flash = req && req.query.paid ? '<div class="notice">Thank you, your payment has been received.</div>'
    : req && req.query.payfail ? `<div class="error">${esc(String(req.query.payfail).slice(0, 200))}</div>` : '';
  return `<section class="panel invoices" id="invoices"><h2>Invoices and payments</h2>${flash}${out.join('')}${payList}</section>`;
}

// ======================= Actions =======================
router.post('/jobs/:id/deposit', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  if (job.status !== 'accepted') return back(res, job);
  const amount = r2(N(req.body.amount));
  if (amount <= 0) return errorBack(res, job, 'Enter a deposit amount.');
  const s = await settings();
  const q = await currentQuote(job.id);
  const vatRate = s.vat_registered ? N(s.vat_rate) : 0;
  const net = r2(amount / (1 + vatRate / 100));
  const lines = [{ category: 'other', description: `Deposit${q ? ` for quote ${qref(q.id)}` : ''}: ${job.title}`, qty: 1, unit: '', unit_price: net }];
  await inTransaction(async (client) => {
    await client.query(
      `INSERT INTO invoices (job_id, kind, quote_id, lines, net, vat_rate, vat, total, amount_due, due_date, created_by)
       VALUES ($1, 'deposit', $2, $3, $4, $5, $6, $7, $7, $8, $9)`,
      [job.id, q ? q.id : null, JSON.stringify(lines), net, vatRate, r2(amount - net), amount, todayISO(), req.user.id]);
    await setStatus(client, job.id, job.status, 'deposit_requested', req.user.id, `Deposit of ${money(amount)} requested`);
  });
  await notifyStageChange(job.id, 'deposit_requested', baseUrlOf(req));
  back(res, job, '#invoices');
}));

router.post('/jobs/:id/skip-deposit', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  if (job.status === 'accepted') {
    await inTransaction((client) => setStatus(client, job.id, job.status, 'deposit_paid', req.user.id, 'No deposit needed'));
  }
  back(res, job, '#parts');
}));

router.post('/jobs/:id/parts/from-quote', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const q = (await query("SELECT * FROM quotes WHERE job_id = $1 AND status = 'accepted' ORDER BY id DESC LIMIT 1", [job.id])).rows[0];
  let lines = q ? q.lines.filter((l) => l.category === 'materials') : [];
  if (!lines.length) {
    lines = (await query("SELECT description, qty, unit FROM job_estimate_lines WHERE job_id = $1 AND category = 'materials' ORDER BY sort, id", [job.id])).rows;
  }
  await inTransaction(async (client) => {
    let i = 0;
    for (const l of lines) {
      const match = (await client.query('SELECT supplier_id FROM price_items WHERE lower(name) = lower($1) AND supplier_id IS NOT NULL ORDER BY active DESC, id LIMIT 1', [l.description])).rows[0];
      await client.query('INSERT INTO job_parts (job_id, description, qty, unit, supplier_id, sort) VALUES ($1, $2, $3, $4, $5, $6)',
        [job.id, l.description, N(l.qty), l.unit || null, match ? match.supplier_id : null, i++]);
    }
  });
  back(res, job, '#parts', lines.length ? 'updated=1' : 'error=' + encodeURIComponent('No materials found on the quote. Add parts by hand.'));
}));

router.post('/jobs/:id/parts', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  const isAdmin = req.user.role === 'admin';
  const count = Math.min(Number(req.body.count) || 0, 300);
  let moved = false;
  await inTransaction(async (client) => {
    for (let i = 0; i < count; i++) {
      const id = Number(req.body[`p${i}_id`]) || null;
      const status = PART_STATUS[req.body[`p${i}_status`]] ? req.body[`p${i}_status`] : 'to_order';
      const note = String(req.body[`p${i}_note`] || '').trim().slice(0, 200) || null;
      if (!isAdmin) {
        if (id) await client.query('UPDATE job_parts SET status = $1, note = $2, updated_at = now() WHERE id = $3 AND job_id = $4', [status, note, id, job.id]);
        continue;
      }
      if (id && req.body[`p${i}_del`] === 'on') {
        await client.query('DELETE FROM job_parts WHERE id = $1 AND job_id = $2', [id, job.id]);
        continue;
      }
      const desc = String(req.body[`p${i}_desc`] || '').trim().slice(0, 200);
      if (!desc) continue;
      const qty = Math.max(0, N(req.body[`p${i}_qty`]));
      const supplier = Number(req.body[`p${i}_supplier`]) || null;
      if (id) {
        await client.query('UPDATE job_parts SET description = $1, qty = $2, supplier_id = $3, status = $4, note = $5, updated_at = now() WHERE id = $6 AND job_id = $7',
          [desc, qty, supplier, status, note, id, job.id]);
      } else {
        await client.query('INSERT INTO job_parts (job_id, description, qty, supplier_id, status, note, sort) VALUES ($1, $2, $3, $4, $5, $6, $7)',
          [job.id, desc, qty, supplier, status, note, 1000 + i]);
      }
    }
    // Once nothing is left to order, the job moves to Parts ordered.
    const left = (await client.query("SELECT count(*)::int AS n, count(*) FILTER (WHERE status = 'to_order')::int AS todo FROM job_parts WHERE job_id = $1", [job.id])).rows[0];
    if (left.n && !left.todo && job.status === 'deposit_paid') {
      await setStatus(client, job.id, job.status, 'parts_ordered', req.user.id, 'All parts ordered');
      moved = true;
    }
  });
  if (moved) await notifyStageChange(job.id, 'parts_ordered', baseUrlOf(req));
  back(res, job, '#parts');
}));

router.post('/jobs/:id/schedule', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const builderId = Number(req.body.builder_id) || null;
  const start = String(req.body.start || '');
  const end = String(req.body.end || '');
  if (!isDate(start)) return errorBack(res, job, 'Choose a start date.');
  if (end && (!isDate(end) || end < start)) return errorBack(res, job, 'The finish date must be on or after the start.');
  const b = builderId && (await query("SELECT id, name FROM users WHERE id = $1 AND role IN ('builder', 'manager') AND active", [builderId])).rows[0];
  if (!b) return errorBack(res, job, 'Choose a builder.');
  const av = await loadAvailability([b.id], start, end || start);
  const blocked = blockedDates(av, b.id, start, end || start);
  if (blocked.length && req.body.override !== 'on') {
    return errorBack(res, job, `${b.name} is off on ${blocked.map((x) => `${day(x.date)}${x.state === 'holiday' ? ' (holiday)' : ''}`).join(', ')}. Choose other dates or tick “Book anyway”.`);
  }
  await inTransaction(async (client) => {
    await client.query('UPDATE jobs SET assigned_builder_id = $1, scheduled_start = $2, scheduled_end = $3, updated_at = now() WHERE id = $4',
      [builderId, start, end || null, job.id]);
    await setStatus(client, job.id, job.status, 'scheduled', req.user.id, `Booked for ${day(start)}${end ? ` to ${day(end)}` : ''}`);
  });
  await notifyStageChange(job.id, 'scheduled', baseUrlOf(req));
  back(res, job);
}));

router.post('/jobs/:id/start', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  if (job.status === 'scheduled') {
    await inTransaction((client) => setStatus(client, job.id, job.status, 'in_progress', req.user.id, 'Work started'));
    await notifyStageChange(job.id, 'in_progress', baseUrlOf(req));
  }
  back(res, job, '#time');
}));

router.post('/jobs/:id/complete', staff, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || !mayWork(req.user, job)) return notFound(req, res);
  if (job.status !== 'in_progress') return back(res, job);
  const note = String(req.body.note || '').trim().slice(0, 2000) || null;
  await inTransaction(async (client) => {
    await client.query("UPDATE job_time_entries SET ended_at = now() WHERE job_id = $1 AND ended_at IS NULL", [job.id]);
    await client.query('UPDATE jobs SET completion_note = $1, completed_at = now(), updated_at = now() WHERE id = $2', [note, job.id]);
    await setStatus(client, job.id, job.status, 'complete', req.user.id, note ? `Work complete: ${note}` : 'Work complete');
  });
  await notifyStageChange(job.id, 'complete', baseUrlOf(req));
  await notifyOffice(`Work complete: ${job.title} (${ref(job.id)})`,
    `${req.user.name} has marked the job complete.${note ? `\n\nNote: ${note}` : ''}\n\nNext: send the final invoice.\n${baseUrlOf(req)}/jobs/${job.id}`, job.id);
  back(res, job);
}));

router.post('/jobs/:id/invoice', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  if (job.status !== 'complete') return back(res, job);
  const q = (await query("SELECT * FROM quotes WHERE job_id = $1 AND status = 'accepted' ORDER BY id DESC LIMIT 1", [job.id])).rows[0];
  if (!q) return errorBack(res, job, 'There’s no accepted quote to invoice from.');
  const s = await settings();
  const lines = q.lines.map((l) => ({ ...l }));
  for (let i = 0; i < 3; i++) {
    const d = String(req.body[`x${i}_desc`] || '').trim().slice(0, 200);
    const a = r2(N(req.body[`x${i}_amount`]));
    if (d && a > 0) lines.push({ category: 'other', description: d, qty: 1, unit: '', unit_price: a, extra: true });
  }
  const net = r2(lines.reduce((t, l) => t + N(l.qty) * N(l.unit_price), 0));
  const vatRate = s.vat_registered ? N(s.vat_rate) : 0;
  const vat = r2(net * vatRate / 100);
  const total = r2(net + vat);
  const paid = N((await query('SELECT coalesce(sum(amount), 0) AS n FROM payments WHERE job_id = $1', [job.id])).rows[0].n);
  const due = r2(Math.max(0, total - paid));
  const dueDate = new Date(Date.now() + N(s.payment_terms_days) * 86400000).toISOString().slice(0, 10);
  // Extras always show as their own lines, even on a summary-style quote.
  await inTransaction(async (client) => {
    await client.query(
      `INSERT INTO invoices (job_id, kind, quote_id, layout, lines, net, vat_rate, vat, total, less_paid, amount_due, due_date, note, created_by)
       VALUES ($1, 'final', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
      [job.id, q.id, q.layout, JSON.stringify(lines), net, vatRate, vat, total, r2(paid), due, dueDate,
        String(req.body.note || '').trim().slice(0, 1000) || null, req.user.id]);
    await setStatus(client, job.id, job.status, 'invoiced', req.user.id, `Final invoice for ${money(total)} sent`);
  });
  await notifyStageChange(job.id, 'invoiced', baseUrlOf(req));
  back(res, job, '#invoices');
}));

router.post('/jobs/:id/invoices/:iid/payments', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const inv = await loadInvoice(req, job);
  if (!inv || inv.status !== 'issued') return back(res, job, '#invoices');
  const amount = r2(N(req.body.amount));
  if (amount <= 0) return errorBack(res, job, 'Enter the amount received.', '#invoices');
  const method = String(req.body.method || 'Other').slice(0, 40);
  const date = isDate(req.body.date) ? req.body.date : null;
  const newStatus = await applyPayment({ invoice: inv, job, amount, method, reference: String(req.body.reference || '').trim().slice(0, 100), userId: req.user.id, receivedAt: date });
  if (newStatus) await notifyStageChange(job.id, newStatus, baseUrlOf(req));
  back(res, job, '#invoices');
}));

router.post('/jobs/:id/invoices/:iid/void', admin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const inv = await loadInvoice(req, job);
  if (inv && inv.status === 'issued' && req.body.confirm === 'on') {
    if (await paidOn(inv.id)) return errorBack(res, job, 'This invoice has payments recorded, so it can’t be cancelled.', '#invoices');
    await query("UPDATE invoices SET status = 'void' WHERE id = $1", [inv.id]);
  }
  back(res, job, '#invoices');
}));

// ---- Online card payments (Stripe Checkout) ----
router.post('/jobs/:id/invoices/:iid/pay', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job || req.user.role !== 'customer') return notFound(req, res);
  const inv = await loadInvoice(req, job);
  if (!inv || inv.status !== 'issued' || !stripeReady()) return back(res, job, '#invoices');
  const due = r2(N(inv.amount_due) - (await paidOn(inv.id)));
  if (due <= 0) return back(res, job, '#invoices');
  const base = baseUrlOf(req);
  try {
    const session = await stripeApi('checkout/sessions', {
      mode: 'payment',
      'line_items[0][price_data][currency]': 'gbp',
      'line_items[0][price_data][product_data][name]': `${inv.kind === 'deposit' ? 'Deposit' : 'Invoice'} ${iref(inv.id)}: ${job.title}`.slice(0, 250),
      'line_items[0][price_data][unit_amount]': String(Math.round(due * 100)),
      'line_items[0][quantity]': '1',
      customer_email: job.customer_email,
      'metadata[invoice_id]': String(inv.id),
      'metadata[job_id]': String(job.id),
      success_url: `${base}/jobs/${job.id}/invoices/${inv.id}/paid?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${base}/jobs/${job.id}#invoices`,
    });
    res.redirect(303, session.url);
  } catch (e) {
    console.error('Stripe checkout failed:', e.message);
    res.redirect(`/jobs/${job.id}?payfail=${encodeURIComponent('Online payment isn’t available right now. Please use one of the other ways to pay.')}#invoices`);
  }
}));

router.get('/jobs/:id/invoices/:iid/paid', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const inv = await loadInvoice(req, job);
  const sessionId = String(req.query.session_id || '');
  if (!inv || !/^cs_[A-Za-z0-9_]+$/.test(sessionId) || !stripeReady()) return back(res, job, '#invoices');
  try {
    const session = await stripeApi('checkout/sessions/' + encodeURIComponent(sessionId));
    if (session.payment_status !== 'paid' || String(session.metadata && session.metadata.invoice_id) !== String(inv.id)) {
      return res.redirect(`/jobs/${job.id}?payfail=${encodeURIComponent('The payment hasn’t gone through. Nothing has been taken.')}#invoices`);
    }
    const already = (await query('SELECT 1 FROM payments WHERE stripe_session_id = $1', [sessionId])).rows.length;
    if (!already) {
      const amount = r2(N(session.amount_total) / 100);
      const newStatus = await applyPayment({ invoice: inv, job, amount, method: 'Card online', reference: session.payment_intent || sessionId, userId: req.user.id, stripeSessionId: sessionId });
      await afterPayment(req, job, inv, newStatus, amount, 'card online');
    }
    res.redirect(`/jobs/${job.id}?paid=1#invoices`);
  } catch (e) {
    if (e.code === '23505') return res.redirect(`/jobs/${job.id}?paid=1#invoices`);
    console.error('Stripe check failed:', e.message);
    res.redirect(`/jobs/${job.id}?payfail=${encodeURIComponent('We couldn’t confirm the payment yet. If money was taken, the office will match it up.')}#invoices`);
  }
}));

// ---- Invoice PDF ----
router.get('/jobs/:id/invoices/:iid/pdf', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const inv = await loadInvoice(req, job);
  if (!inv || (req.user.role === 'customer' && inv.status === 'void')) return notFound(req, res);
  const s = await settings();
  const m = (n) => money(n, s.currency);
  const cust = (await query('SELECT name FROM users WHERE id = $1', [job.customer_id])).rows[0];
  const paid = await paidOn(inv.id);
  const due = r2(Math.max(0, N(inv.amount_due) - paid));

  // Summary-style quotes group the quoted lines, but agreed extras stay as their own lines.
  const quoted = { layout: inv.layout, lines: inv.lines.filter((l) => !l.extra) };
  const extras = inv.lines.filter((l) => l.extra).map((l) => ({ description: l.description, qty: 1, unit: '', price: N(l.unit_price), total: N(l.unit_price) }));
  const itemised = inv.kind === 'deposit' || inv.layout === 'itemised';
  const rows = [...displayLines({ ...quoted, layout: itemised ? 'itemised' : 'summary' }), ...extras.map((x) => (itemised ? x : { ...x, qty: null, price: null }))];

  const totals = [['Net', m(inv.net)]];
  if (N(inv.vat)) totals.push([`VAT ${N(inv.vat_rate)}%`, m(inv.vat)]);
  totals.push(['Total', m(inv.total), true]);
  if (N(inv.less_paid)) totals.push(['Less already paid', `-${m(inv.less_paid)}`]);
  if (paid) totals.push(['Paid', `-${m(paid)}`]);
  totals.push([inv.status === 'void' ? 'Cancelled' : 'Amount due', inv.status === 'void' ? '' : m(due), true]);

  const blocks = [{ text: inv.note }];
  if (inv.status === 'paid') blocks.push({ title: `Paid in full${inv.paid_at ? ` on ${day(inv.paid_at)}` : ''}. Thank you.`, text: ' ' });
  else if (inv.status === 'issued') {
    blocks.push({ title: 'How to pay', text: s.payment_instructions });
    if (s.bank_details) blocks.push({ title: 'Bank details', text: `${s.bank_details}\nReference: ${ref(job.id)}` });
    if (stripeReady()) blocks.push({ title: 'Pay by card online', text: `${baseUrlOf(req)}/jobs/${job.id}` });
  }

  renderDocument({
    res, s, money: m, download: Boolean(req.query.download), filename: `${iref(inv.id)}.pdf`,
    title: inv.kind === 'deposit' ? 'Deposit invoice' : 'Invoice',
    meta: [['Invoice', iref(inv.id)], ['Date', day(inv.created_at)], ['Due', inv.due_date ? day(inv.due_date) : 'On receipt'], ['Job', ref(job.id)]],
    customer: { name: cust.name, lines: [job.address_line, job.town, job.postcode] },
    heading: job.title, itemised, rows, totals, blocks,
  });
}));

module.exports = { router, nextStepPanel, partsPanel, routePanel, invoicesPanel, iref };
