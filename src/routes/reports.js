// Reports: money in, money owed, how well quotes convert, profit per job,
// and how accurate each job template's time estimate turns out to be.
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { ref, day, ukDate, ukTime, addDays } = require('../format');
const { money } = require('../estimate');

const router = express.Router();
const admin = requireRole('admin');
const N = (x) => Number(x) || 0;
const r2 = (n) => Math.round(n * 100) / 100;
const isDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d || '');
const pct = (a, b) => (b ? `${Math.round((a / b) * 100)}%` : 'n/a');

function period(q) {
  const today = ukDate(new Date());
  const [y, m] = today.split('-').map(Number);
  const first = (yy, mm) => `${yy}-${String(mm).padStart(2, '0')}-01`;
  const lastOf = (yy, mm) => addDays(mm === 12 ? first(yy + 1, 1) : first(yy, mm + 1), -1);
  const taxStartYear = today >= `${y}-04-06` ? y : y - 1;
  const presets = {
    this_month: ['This month', first(y, m), today],
    last_month: ['Last month', m === 1 ? first(y - 1, 12) : first(y, m - 1), m === 1 ? lastOf(y - 1, 12) : lastOf(y, m - 1)],
    tax_year: ['This tax year', `${taxStartYear}-04-06`, today],
    last_12: ['Last 12 months', addDays(today, -364), today],
  };
  if (q.preset === 'custom' && isDate(q.from) && isDate(q.to) && q.from <= q.to) return { key: 'custom', label: `${day(q.from)} to ${day(q.to)}`, from: q.from, to: q.to };
  const key = presets[q.preset] ? q.preset : 'this_month';
  const [label, from, to] = presets[key];
  return { key, label, from, to };
}

// Hours estimated for a job: the working estimate's labour hours, else the price guide's.
const ESTIMATED_HOURS = `coalesce(
  nullif((SELECT sum(l.qty) FROM job_estimate_lines l WHERE l.job_id = j.id AND l.category = 'labour' AND l.unit ~* '^h(ou)?rs?$'), 0),
  (j.estimate_snapshot -> 'labour' ->> 'estimatedHours')::numeric)`;
const ACTUAL_HOURS = `(SELECT sum(extract(epoch FROM (coalesce(t.ended_at, now()) - t.started_at)) / 3600) FROM job_time_entries t WHERE t.job_id = j.id)`;

router.get('/admin/reports', admin, wrap(async (req, res) => {
  const p = period(req.query);
  const fromTs = ukTime(p.from, '00:00');
  const toTs = ukTime(addDays(p.to, 1), '00:00');
  const s = (await query('SELECT currency, markup_pct FROM settings WHERE id = 1')).rows[0];
  const m = (n) => money(n, s.currency);

  // ---- Money ----
  const byMethod = (await query('SELECT method, sum(amount) AS total, count(*)::int AS n FROM payments WHERE received_at >= $1 AND received_at < $2 GROUP BY method ORDER BY total DESC', [fromTs, toTs])).rows;
  const takings = byMethod.reduce((a, r) => a + N(r.total), 0);
  const invoiced = N((await query("SELECT sum(total) AS t FROM invoices WHERE kind = 'final' AND status <> 'void' AND created_at >= $1 AND created_at < $2", [fromTs, toTs])).rows[0].t);
  const owed = (await query(
    `SELECT i.id, i.job_id, i.due_date, i.amount_due - coalesce((SELECT sum(amount) FROM payments p WHERE p.invoice_id = i.id), 0) AS left_to_pay
     FROM invoices i WHERE i.status = 'issued'`)).rows.filter((r) => N(r.left_to_pay) > 0.004);
  const today = new Date(new Date().toDateString());
  const ageing = { notDue: 0, d30: 0, d60: 0, older: 0 };
  for (const o of owed) {
    const late = o.due_date ? Math.floor((today - new Date(o.due_date)) / 86400000) : 0;
    const k = late <= 0 ? 'notDue' : late <= 30 ? 'd30' : late <= 60 ? 'd60' : 'older';
    ageing[k] += N(o.left_to_pay);
  }
  const owedTotal = Object.values(ageing).reduce((a, b) => a + b, 0);

  // Takings by month, last 12 months, for the bar chart.
  const monthly = (await query(
    `SELECT to_char(date_trunc('month', received_at AT TIME ZONE 'Europe/London'), 'YYYY-MM') AS mon, sum(amount) AS total
     FROM payments WHERE received_at >= now() - interval '12 months' GROUP BY 1 ORDER BY 1`)).rows;
  const months = [];
  for (let i = 11; i >= 0; i--) {
    const d = new Date();
    d.setDate(1);
    d.setMonth(d.getMonth() - i);
    const key = d.toISOString().slice(0, 7);
    months.push({ key, label: d.toLocaleDateString('en-GB', { month: 'short' }), total: N((monthly.find((x) => x.mon === key) || {}).total) });
  }
  const maxMonth = Math.max(1, ...months.map((x) => x.total));

  // ---- Sales ----
  const requests = (await query('SELECT count(*)::int AS n FROM jobs WHERE created_at >= $1 AND created_at < $2', [fromTs, toTs])).rows[0].n;
  const quoted = (await query("SELECT count(DISTINCT job_id)::int AS n FROM quotes WHERE created_at >= $1 AND created_at < $2", [fromTs, toTs])).rows[0].n;
  const answers = (await query(
    `SELECT count(*) FILTER (WHERE status = 'accepted')::int AS won, count(*) FILTER (WHERE status = 'declined')::int AS lost, avg(total) FILTER (WHERE status = 'accepted') AS avg_won
     FROM quotes WHERE responded_at >= $1 AND responded_at < $2`, [fromTs, toTs])).rows[0];

  // ---- Profit per job (finished in the period) ----
  const jobs = (await query(
    `SELECT j.id, j.title, b.name AS builder,
       (SELECT i.net FROM invoices i WHERE i.job_id = j.id AND i.kind = 'final' AND i.status <> 'void' ORDER BY i.id DESC LIMIT 1) AS invoiced_net,
       (SELECT q.net FROM quotes q WHERE q.job_id = j.id AND q.status = 'accepted' ORDER BY q.id DESC LIMIT 1) AS quoted_net,
       (SELECT q.lines FROM quotes q WHERE q.job_id = j.id AND q.status = 'accepted' ORDER BY q.id DESC LIMIT 1) AS lines,
       (SELECT sum(extract(epoch FROM (coalesce(t.ended_at, now()) - t.started_at)) / 3600 * coalesce(u.cost_rate, 0))
          FROM job_time_entries t JOIN users u ON u.id = t.user_id WHERE t.job_id = j.id) AS labour_cost,
       (SELECT bool_or(u.cost_rate IS NULL) FROM job_time_entries t JOIN users u ON u.id = t.user_id WHERE t.job_id = j.id) AS missing_rate,
       ${ACTUAL_HOURS} AS actual_hours
     FROM jobs j LEFT JOIN users b ON b.id = j.assigned_builder_id
     WHERE j.completed_at >= $1 AND j.completed_at < $2 ORDER BY j.completed_at DESC`, [fromTs, toTs])).rows.map((j) => {
    const revenue = N(j.invoiced_net ?? j.quoted_net);
    // Materials at cost: quoted materials prices take your markup back off.
    const materials = (j.lines || []).filter((l) => l.category === 'materials').reduce((a, l) => a + N(l.qty) * N(l.unit_price), 0) / (1 + N(s.markup_pct) / 100);
    const profit = revenue - materials - N(j.labour_cost);
    return { ...j, revenue, materials: r2(materials), profit: r2(profit) };
  });
  const totals = jobs.reduce((a, j) => ({ revenue: a.revenue + j.revenue, profit: a.profit + j.profit }), { revenue: 0, profit: 0 });
  const missingRates = jobs.some((j) => j.missing_rate);

  // ---- Estimating accuracy by template (all finished jobs, not just this period) ----
  const accuracy = (await query(
    `SELECT t.id, t.name, t.pricing_method, t.labour_per_unit, count(*)::int AS jobs, sum(x.est) AS est, sum(x.actual) AS actual
     FROM (SELECT j.template_id, ${ESTIMATED_HOURS} AS est, ${ACTUAL_HOURS} AS actual FROM jobs j
           WHERE j.template_id IS NOT NULL AND j.status IN ('complete', 'invoiced', 'paid')) x
     JOIN job_templates t ON t.id = x.template_id
     WHERE x.est > 0 AND x.actual > 0 GROUP BY t.id ORDER BY count(*) DESC`)).rows.map((t) => {
    const ratio = N(t.actual) / N(t.est);
    const suggest = t.jobs >= 3 && Math.abs(ratio - 1) >= 0.1 && t.pricing_method !== 'fixed' ? r2(N(t.labour_per_unit) * ratio) : null;
    return { ...t, ratio, suggest };
  });

  // ---- Builders ----
  const builders = (await query(
    `SELECT u.id, u.name, u.cost_rate,
       coalesce(sum(extract(epoch FROM (coalesce(t.ended_at, now()) - t.started_at)) / 3600), 0) AS hours,
       (SELECT count(*)::int FROM jobs j WHERE j.assigned_builder_id = u.id AND j.completed_at >= $1 AND j.completed_at < $2) AS finished
     FROM users u LEFT JOIN job_time_entries t ON t.user_id = u.id AND t.started_at >= $1 AND t.started_at < $2
     WHERE u.role IN ('builder', 'admin', 'manager') AND u.active GROUP BY u.id ORDER BY u.name`, [fromTs, toTs])).rows.filter((b) => N(b.hours) > 0 || b.finished > 0);

  const presetOpt = (k, l) => `<option value="${k}" ${p.key === k ? 'selected' : ''}>${l}</option>`;
  const csv = (what) => `/admin/reports/${what}.csv?preset=${p.key}${p.key === 'custom' ? `&from=${p.from}&to=${p.to}` : ''}`;
  const card = (label, value, note = '') => `<div class="stat"><span class="muted">${label}</span><strong>${value}</strong>${note ? `<span class="muted small">${note}</span>` : ''}</div>`;

  const body = `<form method="get" action="/admin/reports" class="filters">
      <label>Period<select name="preset">${presetOpt('this_month', 'This month')}${presetOpt('last_month', 'Last month')}${presetOpt('tax_year', 'This tax year')}${presetOpt('last_12', 'Last 12 months')}${presetOpt('custom', 'Choose dates')}</select></label>
      <label>From<input type="date" name="from" value="${p.from}"></label>
      <label>To<input type="date" name="to" value="${p.to}"></label>
      <button class="small">Show</button>
    </form>
    <h2>${esc(p.label)}</h2>
    <div class="stats">
      ${card('Money in', m(takings), byMethod.map((r) => `${esc(r.method)} ${m(r.total)}`).join(' · ') || 'No payments')}
      ${card('Invoiced', m(invoiced))}
      ${card('Owed to you now', m(owedTotal), `${m(ageing.d30 + ageing.d60 + ageing.older)} overdue`)}
      ${card('Quotes won', pct(answers.won, answers.won + answers.lost), `${answers.won} won, ${answers.lost} lost`)}
      ${card('Average job won', m(answers.avg_won || 0))}
      ${card('New requests', requests, `${quoted} quoted`)}
    </div>

    <h2>Money in, last 12 months</h2>
    <div class="bars">${months.map((x) => `<div class="bar"><span class="fill" style="height:${Math.round((x.total / maxMonth) * 100)}%" title="${m(x.total)}"></span><span class="lbl">${x.label}</span></div>`).join('')}</div>

    <h2>Owed to you</h2>
    <div class="stats">
      ${card('Not due yet', m(ageing.notDue))}${card('1 to 30 days late', m(ageing.d30))}${card('31 to 60 days late', m(ageing.d60))}${card('Over 60 days late', m(ageing.older))}
    </div>

    <h2>Profit on jobs finished in this period</h2>
    ${missingRates ? '<p class="error">Some time was logged by people without a pay rate, so their labour counts as £0. Add pay rates on the People page.</p>' : ''}
    ${jobs.length ? `<div class="scroll"><table>
      <thead><tr><th>Job</th><th>Builder</th><th class="num">Charged (net)</th><th class="num">Materials at cost</th><th class="num">Labour cost</th><th class="num">Hours</th><th class="num">Profit</th><th class="num">Margin</th></tr></thead>
      <tbody>${jobs.map((j) => `<tr>
        <td><a href="/jobs/${j.id}">${ref(j.id)}</a> ${esc(j.title)}</td><td>${esc(j.builder || '')}</td>
        <td class="num">${m(j.revenue)}</td><td class="num">${m(j.materials)}</td><td class="num">${m(j.labour_cost)}</td>
        <td class="num">${r2(N(j.actual_hours))}</td>
        <td class="num ${j.profit < 0 ? 'neg' : ''}">${m(j.profit)}</td><td class="num">${pct(j.profit, j.revenue)}</td></tr>`).join('')}
        <tr class="sumrow"><td colspan="2">Total</td><td class="num">${m(totals.revenue)}</td><td></td><td></td><td></td><td class="num">${m(totals.profit)}</td><td class="num">${pct(totals.profit, totals.revenue)}</td></tr>
      </tbody></table></div>
      <p class="hint">An estimate: materials are the quoted prices with your current ${N(s.markup_pct)}% markup taken off, and labour is clocked hours times each person’s pay rate. Travel and other costs aren’t taken off.</p>`
    : '<p class="empty">No jobs finished in this period.</p>'}

    <h2>How accurate are the time estimates?</h2>
    ${accuracy.length ? `<div class="scroll"><table>
      <thead><tr><th>Job template</th><th class="num">Jobs</th><th class="num">Hours estimated</th><th class="num">Hours taken</th><th>Result</th><th>Suggestion</th></tr></thead>
      <tbody>${accuracy.map((t) => `<tr>
        <td><a href="/admin/templates/${t.id}">${esc(t.name)}</a></td><td class="num">${t.jobs}</td>
        <td class="num">${r2(N(t.est))}</td><td class="num">${r2(N(t.actual))}</td>
        <td>${Math.abs(t.ratio - 1) < 0.1 ? '<span class="tag ok">About right</span>' : t.ratio > 1 ? `<span class="tag urgent">${Math.round((t.ratio - 1) * 100)}% longer than estimated</span>` : `<span class="tag">${Math.round((1 - t.ratio) * 100)}% quicker than estimated</span>`}</td>
        <td>${t.suggest !== null ? `<form method="post" action="/admin/reports/template/${t.id}" class="inline">
            <input type="hidden" name="value" value="${t.suggest}">
            <button class="small">Change labour per unit from ${N(t.labour_per_unit)} to ${t.suggest}</button></form>`
          : t.jobs < 3 ? '<span class="muted">Needs 3 or more jobs</span>' : ''}</td></tr>`).join('')}
      </tbody></table></div>
      <p class="hint">Compares the hours on each finished job’s working estimate (or price guide) with the hours actually clocked. Uses every finished job, not just this period.</p>`
    : '<p class="empty">Not enough finished jobs with clocked time yet. This fills in as builders clock on and off.</p>'}

    <h2>People</h2>
    ${builders.length ? `<div class="scroll"><table>
      <thead><tr><th>Name</th><th class="num">Hours clocked</th><th class="num">Jobs finished</th><th class="num">Labour cost</th></tr></thead>
      <tbody>${builders.map((b) => `<tr><td><a href="/admin/users/${b.id}">${esc(b.name)}</a></td><td class="num">${r2(N(b.hours))}</td><td class="num">${b.finished}</td>
        <td class="num">${b.cost_rate === null ? '<span class="muted">No pay rate</span>' : m(N(b.hours) * N(b.cost_rate))}</td></tr>`).join('')}</tbody></table></div>`
    : '<p class="empty">No time clocked in this period.</p>'}

    <h2>Download</h2>
    <p><a class="button" href="${csv('payments')}">Payments (CSV)</a> <a class="button" href="${csv('jobs')}">Jobs finished (CSV)</a></p>
    <p class="hint">Opens in Excel, Numbers or Google Sheets, handy for your accountant.</p>`;
  res.send(page({ title: 'Reports', user: req.user, notice: req.query.applied ? 'Template updated. New price guides use the new figure.' : null, body }));
}));

router.post('/admin/reports/template/:id', admin, wrap(async (req, res) => {
  const v = Number(req.body.value);
  if (Number.isFinite(v) && v > 0) await query("UPDATE job_templates SET labour_per_unit = $1 WHERE id = $2 AND pricing_method <> 'fixed'", [v, Number(req.params.id) || 0]);
  res.redirect('/admin/reports?applied=1');
}));

const csvCell = (v) => {
  const s = v === null || v === undefined ? '' : String(v);
  return /[",\n\r]/.test(s) || /^[=+\-@]/.test(s) ? `"${s.replace(/"/g, '""').replace(/^([=+\-@])/, "'$1")}"` : s;
};
const sendCsv = (res, name, header, rows) => {
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="${name}"`);
  res.send('\uFEFF' + [header, ...rows].map((r) => r.map(csvCell).join(',')).join('\r\n'));
};

router.get('/admin/reports/payments.csv', admin, wrap(async (req, res) => {
  const p = period(req.query);
  const rows = (await query(
    `SELECT p.received_at, p.amount, p.method, p.reference, p.job_id, p.invoice_id, j.title, u.name
     FROM payments p JOIN jobs j ON j.id = p.job_id JOIN users u ON u.id = j.customer_id
     WHERE p.received_at >= $1 AND p.received_at < $2 ORDER BY p.received_at`, [ukTime(p.from, '00:00'), ukTime(addDays(p.to, 1), '00:00')])).rows;
  sendCsv(res, `payments-${p.from}-to-${p.to}.csv`, ['Date', 'Amount', 'Method', 'Reference', 'Job', 'Invoice', 'Work', 'Customer'],
    rows.map((r) => [ukDate(r.received_at), N(r.amount).toFixed(2), r.method, r.reference, ref(r.job_id), r.invoice_id ? `INV-${String(r.invoice_id).padStart(5, '0')}` : '', r.title, r.name]));
}));

router.get('/admin/reports/jobs.csv', admin, wrap(async (req, res) => {
  const p = period(req.query);
  const rows = (await query(
    `SELECT j.id, j.title, j.postcode, j.completed_at, j.status, u.name, b.name AS builder,
       (SELECT i.net FROM invoices i WHERE i.job_id = j.id AND i.kind = 'final' AND i.status <> 'void' ORDER BY i.id DESC LIMIT 1) AS net,
       (SELECT i.total FROM invoices i WHERE i.job_id = j.id AND i.kind = 'final' AND i.status <> 'void' ORDER BY i.id DESC LIMIT 1) AS total,
       ${ACTUAL_HOURS} AS hours
     FROM jobs j JOIN users u ON u.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id
     WHERE j.completed_at >= $1 AND j.completed_at < $2 ORDER BY j.completed_at`, [ukTime(p.from, '00:00'), ukTime(addDays(p.to, 1), '00:00')])).rows;
  sendCsv(res, `jobs-${p.from}-to-${p.to}.csv`, ['Job', 'Work', 'Customer', 'Postcode', 'Builder', 'Finished', 'Stage', 'Invoiced net', 'Invoiced total', 'Hours clocked'],
    rows.map((r) => [ref(r.id), r.title, r.name, r.postcode, r.builder, ukDate(r.completed_at), r.status, r.net === null ? '' : N(r.net).toFixed(2), r.total === null ? '' : N(r.total).toFixed(2), r2(N(r.hours))]));
}));

module.exports = router;
