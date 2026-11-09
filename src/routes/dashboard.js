const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireLogin } = require('../auth');
const { STATUSES, CLOSED, label } = require('../statuses');
const { ref, day } = require('../format');

const router = express.Router();

function jobsTable(jobs, { showCustomer = false, showBuilder = false } = {}) {
  if (!jobs.length) return '';
  const rows = jobs.map((j) => `<tr>
    <td><a href="/jobs/${j.id}">${ref(j.id)}</a></td>
    <td><a href="/jobs/${j.id}">${esc(j.title)}</a>${j.urgent ? ' <span class="tag urgent">Urgent</span>' : ''}</td>
    ${showCustomer ? `<td>${esc(j.customer_name)}</td>` : ''}
    <td>${esc(j.postcode)}</td>
    <td><span class="tag">${esc(label(j.status))}</span></td>
    ${showBuilder ? `<td>${esc(j.builder_name || 'Not assigned')}</td>` : ''}
    <td>${j.scheduled_start ? `<strong>${day(j.scheduled_start)}</strong>` : day(j.preferred_start)}</td>
  </tr>`).join('');
  return `<div class="scroll"><table>
    <thead><tr><th>Job</th><th>Work</th>${showCustomer ? '<th>Customer</th>' : ''}<th>Postcode</th><th>Stage</th>${showBuilder ? '<th>Builder</th>' : ''}<th>Date</th></tr></thead>
    <tbody>${rows}</tbody></table></div>`;
}

const JOB_SELECT = `SELECT j.*, c.name AS customer_name, b.name AS builder_name
  FROM jobs j JOIN users c ON c.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id`;

router.get('/dashboard', requireLogin, wrap(async (req, res) => {
  const user = req.user;

  if (user.role === 'customer') {
    const { rows } = await query(`${JOB_SELECT} WHERE j.customer_id = $1 ORDER BY j.created_at DESC`, [user.id]);
    const body = `
      <section class="panel callout">
        <h2>Need something done?</h2>
        <p>Tell us about the job, add photos, and pick when you’d like it done.</p>
        <p><a class="button primary" href="/jobs/new">Request a job</a></p>
      </section>
      <h2>Your jobs</h2>
      ${jobsTable(rows) || '<p class="empty">You haven’t requested any jobs yet.</p>'}`;
    return res.send(page({ title: 'Your dashboard', user, body }));
  }

  if (user.role === 'builder') {
    const { rows } = await query(
      `${JOB_SELECT} WHERE j.assigned_builder_id = $1 AND j.status <> ALL($2) ORDER BY coalesce(j.scheduled_start, j.preferred_start) NULLS LAST, j.created_at`,
      [user.id, CLOSED]
    );
    const clocked = (await query(
      `SELECT t.job_id, t.started_at, j.title FROM job_time_entries t JOIN jobs j ON j.id = t.job_id
       WHERE t.user_id = $1 AND t.ended_at IS NULL LIMIT 1`, [user.id])).rows[0];
    const body = `${clocked ? `<div class="notice">You’re clocked on to <a href="/jobs/${clocked.job_id}#time">${esc(clocked.title)}</a> since ${new Date(clocked.started_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}.</div>` : ''}
      <h2>Your jobs</h2>
      ${jobsTable(rows, { showCustomer: true }) || '<p class="empty">No jobs assigned to you yet. The office will assign them here.</p>'}`;
    return res.send(page({ title: 'Builder dashboard', user, body }));
  }

  // Admin
  const counts = await query('SELECT status, count(*)::int AS n FROM jobs GROUP BY status');
  const byStatus = Object.fromEntries(counts.rows.map((r) => [r.status, r.n]));
  const pipeline = STATUSES.filter(([k]) => !CLOSED.includes(k))
    .map(([k, l]) => `<li class="${byStatus[k] ? 'has' : ''}"><span class="n">${byStatus[k] || 0}</span><span>${esc(l)}</span></li>`)
    .join('');
  const open = await query(`${JOB_SELECT} WHERE j.status <> ALL($1) ORDER BY j.urgent DESC, j.created_at DESC LIMIT 50`, [CLOSED]);
  const s = (await query(
    `SELECT base_postcode, (SELECT count(*)::int FROM users WHERE role = 'builder' AND active AND coalesce(postcode, '') <> '') AS builder_postcodes
     FROM settings WHERE id = 1`)).rows[0];

  const ACTIONS = [
    ['request', 'Check the price guide'],
    ['inspection_required', 'Book an inspection'],
    ['inspected', 'Send the quote'],
    ['accepted', 'Request the deposit'],
    ['deposit_paid', 'Order parts and book the job in'],
    ['parts_ordered', 'Book the job in'],
    ['complete', 'Send the final invoice'],
  ];
  const actionRows = (await query(
    `SELECT id, title, status, urgent FROM jobs WHERE status = ANY($1) ORDER BY urgent DESC, updated_at`, [ACTIONS.map((a) => a[0])])).rows;
  const overdue = (await query(
    `SELECT i.id, i.job_id, j.title FROM invoices i JOIN jobs j ON j.id = i.job_id
     WHERE i.status = 'issued' AND i.due_date < current_date ORDER BY i.due_date`)).rows;
  const todoItems = [
    ...actionRows.map((j) => `<li><a href="/jobs/${j.id}"><strong>${esc(ACTIONS.find((a) => a[0] === j.status)[1])}</strong>: ${esc(j.title)} (${ref(j.id)})</a>${j.urgent ? ' <span class="tag urgent">Urgent</span>' : ''}</li>`),
    ...overdue.map((i) => `<li><a href="/jobs/${i.job_id}#invoices"><strong>Chase overdue invoice</strong>: ${esc(i.title)} (${ref(i.job_id)})</a></li>`),
  ];
  const todo = `<h2>Needs your attention</h2>${todoItems.length ? `<ul class="todo">${todoItems.join('')}</ul>` : '<p class="empty">Nothing waiting on you right now.</p>'}`;

  const body = `
    ${!s.base_postcode && !s.builder_postcodes ? '<div class="error">Add your builders’ home postcodes on the <a href="/admin/users">People</a> page so travel costs can be worked out.</div>' : ''}
    ${todo}
    <h2>Job pipeline</h2>
    <ol class="pipeline">${pipeline}</ol>
    <h2>Open jobs</h2>
    ${jobsTable(open.rows, { showCustomer: true, showBuilder: true }) || '<p class="empty">No open jobs. New customer requests will appear here.</p>'}`;
  res.send(page({ title: 'Office dashboard', user, body }));
}));

module.exports = router;
