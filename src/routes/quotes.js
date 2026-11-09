// Quotes: sent from the working estimate, viewed and accepted or declined by the customer, downloadable as PDF.
const express = require('express');
const PDFDocument = require('pdfkit');
const { pool, query } = require('../db');
const { esc } = require('../layout');
const { wrap, requireLogin, requireRole } = require('../auth');
const { ref, day } = require('../format');
const { money } = require('../estimate');
const { loadJob, notFound, setStatus, baseUrlOf } = require('../jobs-shared');
const { notifyStageChange } = require('../notify');

const router = express.Router();
const N = (x) => Number(x) || 0;
const r2 = (n) => Math.round(n * 100) / 100;
const qref = (id) => 'Q-' + String(id).padStart(5, '0');
const CAT_SUMMARY = { materials: 'Materials', labour: 'Labour', travel: 'Travel and other costs', other: 'Travel and other costs' };

async function currentQuote(jobId) {
  return (await query("SELECT * FROM quotes WHERE job_id = $1 AND status <> 'superseded' ORDER BY id DESC LIMIT 1", [jobId])).rows[0] || null;
}

// What the customer sees: every line, or one line per type.
function displayLines(q) {
  if (q.layout === 'itemised') {
    return q.lines.map((l) => ({ description: l.description, qty: N(l.qty), unit: l.unit || '', price: N(l.unit_price), total: r2(N(l.qty) * N(l.unit_price)) }));
  }
  const groups = {};
  for (const l of q.lines) {
    const k = CAT_SUMMARY[l.category] || 'Other';
    groups[k] = r2((groups[k] || 0) + N(l.qty) * N(l.unit_price));
  }
  return Object.entries(groups).map(([description, total]) => ({ description, qty: null, unit: '', price: null, total }));
}

const fmtQty = (n) => (n === null ? '' : String(Math.round(n * 100) / 100));

// ---------- Panel on the job page ----------
async function quotePanel(job, user) {
  const q = await currentQuote(job.id);
  const s = (await query('SELECT currency FROM settings WHERE id = 1')).rows[0];
  const m = (n) => money(n, s.currency);
  if (!q) return '';
  const rows = displayLines(q);
  const itemised = q.layout === 'itemised';
  const canRespond = q.status === 'sent' && job.status === 'quoted' && (user.role === 'admin' || (user.role === 'customer' && job.customer_id === user.id));
  const expired = q.valid_until && new Date(q.valid_until) < new Date(new Date().toDateString());

  return `<section class="panel quote" id="quote">
    <div class="quotehead">
      <h2>Quote ${qref(q.id)}</h2>
      <span class="tag ${q.status === 'accepted' ? 'ok' : ''}">${{ sent: expired ? 'Expired' : 'Waiting for your answer', accepted: 'Accepted', declined: 'Declined' }[q.status] || ''}</span>
    </div>
    <p class="muted">Sent ${day(q.created_at)}${q.valid_until ? `, valid until ${day(q.valid_until)}` : ''}</p>
    ${q.scope ? `<h3>The work</h3><p class="pre">${esc(q.scope)}</p>` : ''}
    <div class="scroll"><table class="quotetable">
      <thead><tr><th>Description</th>${itemised ? '<th class="num">Qty</th><th>Unit</th><th class="num">Price</th>' : ''}<th class="num">Total</th></tr></thead>
      <tbody>${rows.map((r) => `<tr><td>${esc(r.description)}</td>${itemised ? `<td class="num">${fmtQty(r.qty)}</td><td>${esc(r.unit)}</td><td class="num">${m(r.price)}</td>` : ''}<td class="num">${m(r.total)}</td></tr>`).join('')}</tbody>
    </table></div>
    <div class="wtotals">
      <div><span>Net</span><span>${m(q.net)}</span></div>
      ${N(q.vat) ? `<div><span>VAT ${N(q.vat_rate)}%</span><span>${m(q.vat)}</span></div>` : ''}
      <div class="grand"><span>Total</span><span>${m(q.total)}</span></div>
      ${N(q.deposit) ? `<div><span>Deposit to book (${N(q.deposit_pct)}%)</span><span>${m(q.deposit)}</span></div>` : ''}
    </div>
    ${q.customer_note ? `<p class="pre">${esc(q.customer_note)}</p>` : ''}
    <div class="buttons">
      <a class="button" href="/jobs/${job.id}/quotes/${q.id}/pdf" target="_blank" rel="noopener">View or print</a>
      <a class="button" href="/jobs/${job.id}/quotes/${q.id}/pdf?download=1">Download PDF</a>
    </div>
    ${canRespond && !expired ? `<div class="respond">
      <form method="post" action="/jobs/${job.id}/quotes/${q.id}/accept" class="inline">
        <button class="primary">${user.role === 'admin' ? 'Mark as accepted' : 'Accept this quote'}</button>
      </form>
      <details><summary>${user.role === 'admin' ? 'Mark as declined' : 'Decline'}</summary>
        <form method="post" action="/jobs/${job.id}/quotes/${q.id}/decline" class="panel">
          <label>Reason (optional)<textarea name="reason" rows="2" maxlength="500"></textarea></label>
          <button class="small danger">Decline quote</button>
        </form>
      </details>
    </div>` : ''}
    ${canRespond && expired ? `<p>This quote has expired. ${user.role === 'customer' ? 'Get in touch and we’ll send an updated one.' : 'Send an updated quote from the working estimate.'}</p>` : ''}
    ${q.status !== 'sent' && q.responded_at ? `<p class="muted">${q.status === 'accepted' ? 'Accepted' : 'Declined'} ${day(q.responded_at)}${user.role !== 'customer' && q.response_note ? `: ${esc(q.response_note)}` : ''}</p>` : ''}
  </section>`;
}

// The "send quote" form shown to the office under the working estimate.
async function sendQuoteForm(job, user) {
  if (user.role !== 'admin') return '';
  const lines = (await query('SELECT 1 FROM job_estimate_lines WHERE job_id = $1 LIMIT 1', [job.id])).rows.length;
  if (!lines) return '';
  if (['accepted', 'deposit_requested', 'deposit_paid', 'parts_ordered', 'scheduled', 'in_progress', 'complete', 'invoiced', 'paid', 'cancelled'].includes(job.status)) return '';
  const existing = await currentQuote(job.id);
  return `<details class="panel sendquote" ${req_open(job)}>
    <summary><strong>${existing ? 'Send an updated quote' : 'Send quote to customer'}</strong></summary>
    <form method="post" action="/jobs/${job.id}/quotes">
      <label>Description of the work (shown on the quote)<textarea name="scope" rows="4" maxlength="4000">${esc(existing ? existing.scope : job.description)}</textarea></label>
      <label>How should prices show?<select name="layout">
        <option value="itemised">Every line with quantities and prices</option>
        <option value="summary">Totals for materials, labour, and travel and other costs</option>
      </select></label>
      <label>Message to the customer (optional)<textarea name="customer_note" rows="2" maxlength="2000"></textarea></label>
      <p class="hint">Uses the working estimate as it is now. The customer is emailed and can accept or decline online.${existing ? ' The previous quote is replaced.' : ''}</p>
      <button class="primary">${existing ? 'Send updated quote' : 'Send quote'}</button>
    </form>
  </details>`;
}
const req_open = (job) => (['inspected', 'estimated'].includes(job.status) ? 'open' : '');

// ---------- Send ----------
router.post('/jobs/:id/quotes', requireRole('admin'), wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const lines = (await query('SELECT category, description, qty, unit, unit_price FROM job_estimate_lines WHERE job_id = $1 ORDER BY sort, id', [job.id])).rows
    .map((l) => ({ category: l.category, description: l.description, qty: N(l.qty), unit: l.unit, unit_price: N(l.unit_price) }));
  if (!lines.length) return res.redirect(`/jobs/${job.id}?error=` + encodeURIComponent('Add lines to the working estimate before sending a quote.'));
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const net = r2(lines.reduce((a, l) => a + l.qty * l.unit_price, 0));
  const vatRate = s.vat_registered ? N(s.vat_rate) : 0;
  const vat = r2(net * vatRate / 100);
  const total = r2(net + vat);
  const deposit = r2(total * N(s.deposit_pct) / 100);
  const valid = new Date(Date.now() + N(s.quote_valid_days) * 86400000).toISOString().slice(0, 10);
  const layout = req.body.layout === 'summary' ? 'summary' : 'itemised';

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const prev = (await client.query("UPDATE quotes SET status = 'superseded' WHERE job_id = $1 AND status = 'sent' RETURNING id", [job.id])).rows.length;
    const { rows } = await client.query(
      `INSERT INTO quotes (job_id, layout, scope, customer_note, lines, net, vat_rate, vat, total, deposit_pct, deposit, valid_until, created_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) RETURNING id`,
      [job.id, layout, String(req.body.scope || '').trim().slice(0, 4000) || null, String(req.body.customer_note || '').trim().slice(0, 2000) || null,
        JSON.stringify(lines), net, vatRate, vat, total, N(s.deposit_pct), deposit, valid, req.user.id]);
    await setStatus(client, job.id, job.status, 'quoted', req.user.id, `${prev ? 'Updated quote' : 'Quote'} ${qref(rows[0].id)} sent`);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyStageChange(job.id, 'quoted', baseUrlOf(req));
  res.redirect(`/jobs/${job.id}?updated=1#quote`);
}));

// ---------- Accept / decline ----------
async function respond(req, res, accept) {
  const job = await loadJob(req);
  if (!job || !['admin', 'customer'].includes(req.user.role)) return notFound(req, res);
  const q = await currentQuote(job.id);
  if (!q || q.id !== Number(req.params.qid) || q.status !== 'sent' || job.status !== 'quoted') return res.redirect(`/jobs/${job.id}#quote`);
  if (q.valid_until && new Date(q.valid_until) < new Date(new Date().toDateString())) return res.redirect(`/jobs/${job.id}#quote`);
  const to = accept ? 'accepted' : 'declined';
  const reason = String(req.body.reason || '').trim().slice(0, 500) || null;
  const who = req.user.role === 'admin' ? 'by the office' : 'by the customer';
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('UPDATE quotes SET status = $1, responded_at = now(), responded_by = $2, response_note = $3 WHERE id = $4',
      [to, req.user.id, reason, q.id]);
    await setStatus(client, job.id, job.status, to, req.user.id, `Quote ${qref(q.id)} ${to} ${who}${reason ? `: ${reason}` : ''}`);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  await notifyStageChange(job.id, to, baseUrlOf(req));
  res.redirect(`/jobs/${job.id}?updated=1#quote`);
}
router.post('/jobs/:id/quotes/:qid/accept', requireLogin, wrap((req, res) => respond(req, res, true)));
router.post('/jobs/:id/quotes/:qid/decline', requireLogin, wrap((req, res) => respond(req, res, false)));

// ---------- PDF ----------
router.get('/jobs/:id/quotes/:qid/pdf', requireLogin, wrap(async (req, res) => {
  const job = await loadJob(req);
  if (!job) return notFound(req, res);
  const q = (await query('SELECT * FROM quotes WHERE id = $1 AND job_id = $2', [Number(req.params.qid) || 0, job.id])).rows[0];
  if (!q || (req.user.role === 'customer' && q.status === 'superseded')) return notFound(req, res);
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  const cust = (await query('SELECT name, email, phone FROM users WHERE id = $1', [job.customer_id])).rows[0];
  const m = (n) => money(n, s.currency);

  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `${req.query.download ? 'attachment' : 'inline'}; filename="${qref(q.id)}.pdf"`);
  const doc = new PDFDocument({ size: 'A4', margin: 50, bufferPages: true, info: { Title: `Quote ${qref(q.id)}`, Author: s.business_name } });
  doc.pipe(res);

  const W = doc.page.width;
  const L = 50;
  const R = W - 50;
  const ink = '#1d2529';
  const muted = '#5d6a70';

  // Header band
  doc.rect(0, 0, W, 86).fill('#24414f');
  doc.rect(0, 86, W, 6).fill('#f2c300');
  doc.fillColor('#ffffff').font('Helvetica-Bold').fontSize(22).text(s.business_name, L, 28, { width: 300 });
  const contact = [s.business_address, s.business_phone, s.business_email].filter(Boolean).join('\n');
  if (contact) doc.font('Helvetica').fontSize(9).text(contact, R - 220, 26, { width: 220, align: 'right' });

  // Title and details
  doc.fillColor(ink).font('Helvetica-Bold').fontSize(20).text('Quote', L, 115);
  const meta = [['Quote', qref(q.id)], ['Date', day(q.created_at)], ['Valid until', day(q.valid_until)], ['Job', ref(job.id)]];
  let my = 115;
  for (const [k, v] of meta) {
    doc.font('Helvetica').fontSize(9).fillColor(muted).text(k, R - 200, my, { width: 80 });
    doc.font('Helvetica-Bold').fillColor(ink).text(v, R - 120, my, { width: 120, align: 'right' });
    my += 14;
  }
  doc.font('Helvetica').fontSize(9).fillColor(muted).text('For', L, 150);
  doc.font('Helvetica-Bold').fontSize(11).fillColor(ink).text(cust.name, L, 162);
  doc.font('Helvetica').fontSize(10).text([job.address_line, job.town, job.postcode].filter(Boolean).join('\n'), L, doc.y + 2, { width: 260 });

  doc.y = Math.max(doc.y, my) + 22;
  doc.font('Helvetica-Bold').fontSize(13).text(job.title, L, doc.y, { width: R - L });
  if (q.scope) doc.moveDown(0.3).font('Helvetica').fontSize(10).fillColor(ink).text(q.scope, { width: R - L });
  doc.moveDown(1);

  // Table
  const itemised = q.layout === 'itemised';
  const cols = itemised
    ? [['Description', L, 245, 'left'], ['Qty', L + 250, 45, 'right'], ['Unit', L + 300, 45, 'left'], ['Price', L + 350, 70, 'right'], ['Total', R - 75, 75, 'right']]
    : [['Description', L, 360, 'left'], ['Total', R - 100, 100, 'right']];
  const header = () => {
    const y = doc.y;
    doc.rect(L, y - 4, R - L, 20).fill('#e9ecea');
    doc.fillColor(ink).font('Helvetica-Bold').fontSize(9);
    for (const [t, x, w, a] of cols) doc.text(t, x + 4, y + 2, { width: w - 8, align: a });
    doc.y = y + 22;
  };
  header();
  doc.font('Helvetica').fontSize(10);
  for (const r of displayLines(q)) {
    const vals = itemised ? [r.description, fmtQty(r.qty), r.unit, m(r.price), m(r.total)] : [r.description, m(r.total)];
    const h = Math.max(14, doc.heightOfString(r.description, { width: cols[0][2] - 8 }));
    if (doc.y + h > doc.page.height - 140) { doc.addPage(); doc.y = 60; header(); doc.font('Helvetica').fontSize(10); }
    const y = doc.y;
    cols.forEach(([, x, w, a], i) => doc.fillColor(ink).text(vals[i], x + 4, y, { width: w - 8, align: a }));
    doc.y = y + h + 6;
    doc.moveTo(L, doc.y - 3).lineTo(R, doc.y - 3).lineWidth(0.5).strokeColor('#c9d0cd').stroke();
  }

  // Totals
  if (doc.y > doc.page.height - 200) { doc.addPage(); doc.y = 60; }
  doc.moveDown(0.5);
  const tot = [['Net', m(q.net)]];
  if (N(q.vat)) tot.push([`VAT ${N(q.vat_rate)}%`, m(q.vat)]);
  tot.push(['Total', m(q.total)]);
  for (const [k, v] of tot) {
    const y = doc.y;
    const big = k === 'Total';
    if (big) doc.moveTo(R - 200, y - 2).lineTo(R, y - 2).lineWidth(1.2).strokeColor(ink).stroke();
    doc.font(big ? 'Helvetica-Bold' : 'Helvetica').fontSize(big ? 12 : 10).fillColor(ink);
    doc.text(k, R - 200, y + (big ? 3 : 0), { width: 100 });
    doc.text(v, R - 100, y + (big ? 3 : 0), { width: 100, align: 'right' });
    doc.y = y + (big ? 22 : 16);
  }
  if (N(q.deposit)) {
    doc.font('Helvetica').fontSize(10).fillColor(muted).text(`Deposit to book (${N(q.deposit_pct)}%): ${m(q.deposit)}`, R - 260, doc.y + 2, { width: 260, align: 'right' });
  }

  doc.x = L;
  doc.moveDown(1.5);
  if (q.customer_note) doc.font('Helvetica').fontSize(10).fillColor(ink).text(q.customer_note, L, doc.y, { width: R - L }).moveDown(1);
  if (q.status === 'sent') {
    doc.font('Helvetica-Bold').fontSize(10).fillColor(ink).text('To accept this quote', L, doc.y, { width: R - L });
    doc.font('Helvetica').fontSize(10).text(`Log in and open your job: ${baseUrlOf(req)}/jobs/${job.id}`, { width: R - L }).moveDown(1);
  } else if (q.status === 'accepted') {
    doc.font('Helvetica-Bold').fontSize(10).fillColor(ink).text(`Accepted ${day(q.responded_at)}`, L, doc.y).moveDown(1);
  }
  if (s.quote_terms) {
    doc.font('Helvetica-Bold').fontSize(9).fillColor(muted).text('Terms', L, doc.y, { width: R - L });
    doc.font('Helvetica').fontSize(8.5).text(s.quote_terms, { width: R - L });
  }

  // Page numbers
  const range = doc.bufferedPageRange();
  for (let i = 0; i < range.count; i++) {
    doc.switchToPage(range.start + i);
    const bottom = doc.page.margins.bottom;
    doc.page.margins.bottom = 0;
    doc.font('Helvetica').fontSize(8).fillColor(muted)
      .text(`${s.business_name}  |  ${qref(q.id)}  |  Page ${i + 1} of ${range.count}`, L, doc.page.height - 35, { width: R - L, align: 'center' });
    doc.page.margins.bottom = bottom;
  }
  doc.end();
}));

module.exports = { router, quotePanel, sendQuoteForm, currentQuote };
