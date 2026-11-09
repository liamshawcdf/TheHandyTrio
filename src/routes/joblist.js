// All jobs, past and present, with search and filters. Nothing is ever deleted:
// finished jobs simply drop off the dashboard and live here.
const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin } = require('../auth');
const { STATUSES, CLOSED, label } = require('../statuses');
const { ref, day } = require('../format');
const { money } = require('../estimate');

const router = express.Router();
const PER_PAGE = 50;

router.get('/jobs', requireLogin, wrap(async (req, res) => {
  const user = req.user;
  if (user.role === 'customer') return res.redirect('/dashboard');
  const isAdmin = user.role === 'admin';

  const q = String(req.query.q || '').trim().slice(0, 80);
  const show = ['open', 'finished', 'all'].includes(req.query.show) ? req.query.show : 'all';
  const status = STATUSES.some(([k]) => k === req.query.status) ? req.query.status : '';
  const builder = isAdmin ? Number(req.query.builder) || 0 : 0;
  const pageNo = Math.max(1, Number(req.query.page) || 1);

  const where = [];
  const params = [];
  const add = (sql, v) => { params.push(v); where.push(sql.replace('?', `$${params.length}`)); };
  if (!isAdmin) add('(j.assigned_builder_id = ? OR j.id IN (SELECT job_id FROM job_team WHERE user_id = $Y))'.replace('$Y', `$${params.length + 1}`), user.id);
  if (builder) add('j.assigned_builder_id = ?', builder);
  if (status) add('j.status = ?', status);
  else if (show === 'open') add('j.status <> ALL(?)', CLOSED);
  else if (show === 'finished') add('j.status = ANY(?)', CLOSED);
  if (q) {
    const refNo = q.match(/^(?:ht-?)?0*(\d+)$/i);
    if (refNo) add('j.id = ?', Number(refNo[1]));
    else add(`(j.title ILIKE ? OR c.name ILIKE $X OR j.postcode ILIKE $X OR j.address_line ILIKE $X OR c.email ILIKE $X)`.replace(/\$X/g, `$${params.length + 1}`), `%${q}%`);
  }
  const whereSql = where.length ? 'WHERE ' + where.join(' AND ') : '';

  const total = (await query(`SELECT count(*)::int AS n FROM jobs j JOIN users c ON c.id = j.customer_id ${whereSql}`, params)).rows[0].n;
  const rows = (await query(
    `SELECT j.id, j.title, j.status, j.postcode, j.urgent, j.created_at, j.scheduled_start, j.completed_at, j.updated_at,
       c.name AS customer_name, b.name AS builder_name,
       coalesce(
         (SELECT i.total FROM invoices i WHERE i.job_id = j.id AND i.kind = 'final' AND i.status <> 'void' ORDER BY i.id DESC LIMIT 1),
         (SELECT qq.total FROM quotes qq WHERE qq.job_id = j.id AND qq.status = 'accepted' ORDER BY qq.id DESC LIMIT 1)
       ) AS value
     FROM jobs j JOIN users c ON c.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id
     ${whereSql}
     ORDER BY j.updated_at DESC
     LIMIT ${PER_PAGE} OFFSET ${(pageNo - 1) * PER_PAGE}`, params)).rows;
  const cur = (await query('SELECT currency FROM settings WHERE id = 1')).rows[0].currency;
  const builders = isAdmin ? (await query("SELECT id, name FROM users WHERE role = 'builder' ORDER BY name")).rows : [];

  const keep = (extra) => {
    const p = new URLSearchParams({ q, show, status, builder: builder || '', ...extra });
    for (const [k, v] of [...p]) if (!v) p.delete(k);
    return '/jobs?' + p.toString();
  };

  const filters = `<form method="get" action="/jobs" class="filters">
    <label>Search<input name="q" value="${esc(q)}" placeholder="Job, customer, postcode or HT number"></label>
    <label>Show<select name="show">
      <option value="all" ${show === 'all' ? 'selected' : ''}>All jobs</option>
      <option value="open" ${show === 'open' ? 'selected' : ''}>Open jobs</option>
      <option value="finished" ${show === 'finished' ? 'selected' : ''}>Finished and closed</option>
    </select></label>
    <label>Stage<select name="status"><option value="">Any stage</option>${STATUSES.map(([k, l]) => `<option value="${k}" ${k === status ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
    ${isAdmin ? `<label>Builder<select name="builder"><option value="">Any builder</option>${builders.map((b) => `<option value="${b.id}" ${b.id === builder ? 'selected' : ''}>${esc(b.name)}</option>`).join('')}</select></label>` : ''}
    <button class="small">Find</button>
    ${q || status || builder || show !== 'all' ? '<a href="/jobs">Clear</a>' : ''}
  </form>`;

  const table = rows.length ? `<div class="scroll"><table>
    <thead><tr><th>Job</th><th>Work</th><th>Customer</th><th>Postcode</th><th>Stage</th>${isAdmin ? '<th>Builder</th>' : ''}<th class="num">Value</th><th>Finished</th><th>Last change</th></tr></thead>
    <tbody>${rows.map((j) => `<tr class="${CLOSED.includes(j.status) ? 'closedjob' : ''}">
      <td><a href="/jobs/${j.id}">${ref(j.id)}</a></td>
      <td><a href="/jobs/${j.id}">${esc(j.title)}</a></td>
      <td>${esc(j.customer_name)}</td>
      <td>${esc(j.postcode)}</td>
      <td><span class="tag ${j.status === 'paid' ? 'ok' : ''}">${esc(label(j.status))}</span></td>
      ${isAdmin ? `<td>${esc(j.builder_name || '')}</td>` : ''}
      <td class="num">${j.value !== null ? money(j.value, cur) : ''}</td>
      <td>${day(j.completed_at)}</td>
      <td>${day(j.updated_at)}</td>
    </tr>`).join('')}</tbody></table></div>`
    : '<p class="empty">No jobs match. Try a different search or clear the filters.</p>';

  const pages = Math.ceil(total / PER_PAGE);
  const pager = pages > 1 ? `<nav class="pager">
    ${pageNo > 1 ? `<a href="${esc(keep({ page: pageNo - 1 }))}">Newer</a>` : ''}
    <span>Page ${pageNo} of ${pages}</span>
    ${pageNo < pages ? `<a href="${esc(keep({ page: pageNo + 1 }))}">Older</a>` : ''}
  </nav>` : '';

  const body = `${filters}<p class="muted">${total} job${total === 1 ? '' : 's'}</p>${table}${pager}`;
  res.send(page({ title: isAdmin ? 'All jobs' : 'My jobs', user, body }));
}));

module.exports = router;
