#!/usr/bin/env bash
# TheHandyTrio: job history with search. Run with: bash history.sh
set -e
if [ ! -f package.json ]; then echo "Run this inside the TheHandyTrio folder"; exit 1; fi

cat > src/routes/joblist.js <<'HANDYTRIO_EOF'
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
  if (!isAdmin) add('j.assigned_builder_id = ?', user.id);
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
HANDYTRIO_EOF

cat > src/server.js <<'HANDYTRIO_EOF'
require('dotenv').config();
const path = require('path');
const express = require('express');
const session = require('express-session');
const PgSession = require('connect-pg-simple')(session);
const helmet = require('helmet');
const { pool, query } = require('./db');
const { page } = require('./layout');
const { wrap } = require('./auth');

if (!process.env.SESSION_SECRET || !process.env.DATABASE_URL) {
  console.error('Missing SESSION_SECRET or DATABASE_URL in .env');
  process.exit(1);
}

const app = express();
app.set('trust proxy', 1);
app.disable('x-powered-by');

app.use(helmet());
app.use(express.urlencoded({ extended: false, limit: '100kb' }));
app.use(express.static(path.join(__dirname, '..', 'public')));

app.use(session({
  name: 'handytrio.sid',
  store: new PgSession({ pool, createTableIfMissing: true }),
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, sameSite: 'lax', secure: 'auto', maxAge: 1000 * 60 * 60 * 24 * 7 },
}));

// Load the logged-in person on every request.
app.use(wrap(async (req, res, next) => {
  req.user = null;
  if (req.session.userId) {
    const { rows } = await query('SELECT id, role, name, email FROM users WHERE id = $1 AND active', [req.session.userId]);
    req.user = rows[0] || null;
    if (!req.user) delete req.session.userId;
  }
  next();
}));

app.use(require('./routes/account'));
app.use(require('./routes/dashboard'));
app.use(require('./routes/settings'));
app.use(require('./routes/users'));
app.use(require('./routes/joblist'));
app.use(require('./routes/jobs'));
app.use(require('./routes/pricing'));
app.use(require('./routes/onsite').router);
app.use(require('./routes/quotes').router);
app.use(require('./routes/workflow').router);
app.use(require('./routes/emails'));

app.use((req, res) => {
  res.status(404).send(page({ title: 'Page not found', user: req.user, body: '<p>That page doesn’t exist.</p><p><a href="/">Go to the start</a></p>' }));
});

app.use((err, req, res, next) => {
  console.error(err);
  if (res.headersSent) return next(err);
  res.status(500).send(page({ title: 'Something went wrong', user: req.user, body: '<p>The app hit an error. It has been logged. Go back and try again.</p><p><a href="/">Go to the start</a></p>' }));
});

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`TheHandyTrio running on port ${port}`));
HANDYTRIO_EOF

cat > src/layout.js <<'HANDYTRIO_EOF'
const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin' };

function nav(user) {
  if (!user) return '<a href="/login">Log in</a><a href="/register">Create account</a>';
  const links = ['<a href="/dashboard">Dashboard</a>'];
  if (user.role !== 'customer') links.push(`<a href="/jobs">${user.role === 'admin' ? 'All jobs' : 'My jobs'}</a>`);
  if (user.role === 'admin') {
    links.push('<a href="/admin/templates">Pricing</a>', '<a href="/admin/users">People</a>', '<a href="/admin/emails">Emails</a>', '<a href="/admin/settings">Settings</a>');
  }
  links.push('<form method="post" action="/logout" class="inline"><button class="linkish">Log out</button></form>');
  return links.join('');
}

function page({ title, user, body, notice, error }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} | TheHandyTrio</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow:wght@400;500;600&family=Barlow+Condensed:wght@600;700&display=swap">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<header class="top">
  <a class="brand" href="/">TheHandyTrio</a>
  <nav>${nav(user)}</nav>
</header>
<div class="stripe" aria-hidden="true"></div>
<main>
  ${user ? `<p class="who">Signed in as ${esc(user.name)} (${esc(ROLE_LABELS[user.role] || user.role)})</p>` : ''}
  <h1>${esc(title)}</h1>
  ${notice ? `<div class="notice" role="status">${esc(notice)}</div>` : ''}
  ${error ? `<div class="error" role="alert">${esc(error)}</div>` : ''}
  ${body}
</main>
</body>
</html>`;
}

module.exports = { esc, page, ROLE_LABELS };
HANDYTRIO_EOF

cat > src/routes/dashboard.js <<'HANDYTRIO_EOF'
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
      ${jobsTable(rows, { showCustomer: true }) || '<p class="empty">No jobs assigned to you yet. The office will assign them here.</p>'}
      <p><a class="button" href="/jobs?show=finished">See my past jobs</a></p>`;
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
    ${jobsTable(open.rows, { showCustomer: true, showBuilder: true }) || '<p class="empty">No open jobs. New customer requests will appear here.</p>'}
    <p><a class="button" href="/jobs?show=finished">See finished and closed jobs</a></p>`;
  res.send(page({ title: 'Office dashboard', user, body }));
}));

module.exports = router;
HANDYTRIO_EOF

cat > public/style.css <<'HANDYTRIO_EOF'
:root {
  --bg: #e9ecea;          /* site concrete */
  --surface: #ffffff;
  --ink: #1d2529;
  --muted: #5d6a70;
  --line: #c9d0cd;
  --slate: #24414f;       /* van livery */
  --hivis: #f2c300;       /* hi-vis yellow */
  --hivis-ink: #1d2529;
  --ok-bg: #e2f1e4; --ok-ink: #1f5a2a;
  --bad-bg: #fbe4e1; --bad-ink: #8a2418;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14191c; --surface: #1d2428; --ink: #e5eaec; --muted: #9aa8ae; --line: #33403f;
    --slate: #10232c; --ok-bg: #1d3a24; --ok-ink: #b6e3bf; --bad-bg: #4a1f1a; --bad-ink: #ffc9c1;
    color-scheme: dark;
  }
}

* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.5 Barlow, "Segoe UI", system-ui, sans-serif; }
a { color: inherit; text-underline-offset: 3px; }
:focus-visible { outline: 3px solid var(--hivis); outline-offset: 2px; }

.top { background: var(--slate); color: #fff; display: flex; flex-wrap: wrap; gap: .5rem 1.5rem; align-items: center; justify-content: space-between; padding: .75rem 1.25rem; }
.brand { font: 700 1.6rem/1 "Barlow Condensed", Barlow, sans-serif; text-decoration: none; letter-spacing: .01em; }
.top nav { display: flex; flex-wrap: wrap; gap: 1rem; align-items: center; }
.top nav a { text-decoration: none; opacity: .9; }
.top nav a:hover { opacity: 1; text-decoration: underline; }
.stripe { height: 8px; background: repeating-linear-gradient(-45deg, var(--hivis) 0 14px, var(--slate) 14px 28px); }

main { max-width: 1100px; margin: 0 auto; padding: 1.25rem; }
h1 { font: 700 2.2rem/1.1 "Barlow Condensed", Barlow, sans-serif; margin: .25rem 0 1rem; }
h2 { font: 600 1.4rem/1.2 "Barlow Condensed", Barlow, sans-serif; margin: 1.75rem 0 .75rem; }
.who { color: var(--muted); margin: 0; font-size: .9rem; }
.muted, .empty { color: var(--muted); }

.panel { background: var(--surface); border: 1px solid var(--line); border-radius: 6px; padding: 1rem 1.25rem; margin: 0 0 1rem; }
.narrow { max-width: 480px; }
.callout { border-left: 6px solid var(--hivis); }
.callout h2 { margin-top: 0; }

label { display: block; font-weight: 500; margin: 0 0 .85rem; }
input, select { display: block; width: 100%; margin-top: .3rem; padding: .6rem .7rem; font: inherit; color: var(--ink); background: var(--bg); border: 1px solid var(--line); border-radius: 4px; }
label.check { display: flex; gap: .6rem; align-items: center; }
label.check input { width: auto; margin: 0; }
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 0 1rem; }

button { font: inherit; cursor: pointer; }
button.primary { background: var(--hivis); color: var(--hivis-ink); border: 0; border-radius: 4px; padding: .7rem 1.4rem; font-weight: 600; }
button.primary:hover { filter: brightness(.95); }
button.small { background: transparent; color: var(--ink); border: 1px solid var(--line); border-radius: 4px; padding: .25rem .6rem; font-size: .85rem; }
button.linkish { background: none; border: 0; color: inherit; padding: 0; opacity: .9; }
button.linkish:hover { text-decoration: underline; opacity: 1; }
form.inline { display: inline; }

.notice, .error { padding: .7rem 1rem; border-radius: 4px; margin: 0 0 1rem; }
.notice { background: var(--ok-bg); color: var(--ok-ink); }
.error { background: var(--bad-bg); color: var(--bad-ink); }

.settings { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1rem; align-items: start; }
.settings .panel { margin: 0; }
.settings legend { font: 600 1.2rem "Barlow Condensed", Barlow, sans-serif; padding: 0 .3rem; }
.settings > button { justify-self: start; }

.scroll { overflow-x: auto; background: var(--surface); border: 1px solid var(--line); border-radius: 6px; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: .6rem .8rem; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { font-weight: 600; color: var(--muted); font-size: .9rem; }
tr:last-child td { border-bottom: 0; }
tr.off td { color: var(--muted); }

.tag { display: inline-block; padding: .1rem .5rem; border-radius: 3px; font-size: .85rem; background: var(--bg); border: 1px solid var(--line); }
.tag.urgent { background: var(--hivis); color: var(--hivis-ink); border-color: transparent; }

.pipeline { list-style: none; padding: 0; margin: 0; display: flex; overflow-x: auto; gap: 2px; }
.pipeline li { flex: 1 0 110px; background: var(--surface); padding: .7rem .6rem; display: flex; flex-direction: column; gap: .2rem; font-size: .85rem; color: var(--muted); border-top: 4px solid var(--line); }
.pipeline li.has { color: var(--ink); border-top-color: var(--hivis); }
.pipeline .n { font: 700 1.8rem/1 "Barlow Condensed", Barlow, sans-serif; }

@media (max-width: 560px) {
  .row { grid-template-columns: 1fr; }
  h1 { font-size: 1.9rem; }
}

/* Stage 2: job requests and job pages */
textarea { display: block; width: 100%; margin-top: .3rem; padding: .6rem .7rem; font: inherit; color: var(--ink); background: var(--bg); border: 1px solid var(--line); border-radius: 4px; resize: vertical; }
input[type="file"] { padding: .5rem; }
.hint { color: var(--muted); font-size: .9rem; margin: -.4rem 0 .6rem; }
.request { max-width: 640px; }
.request legend { font: 600 1.2rem "Barlow Condensed", Barlow, sans-serif; padding: 0 .3rem; }

a.button { display: inline-block; text-decoration: none; border: 1px solid var(--line); background: var(--surface); color: var(--ink); border-radius: 4px; padding: .55rem 1.1rem; font-weight: 600; }
a.button.primary { background: var(--hivis); color: var(--hivis-ink); border-color: transparent; }
button.danger { color: var(--bad-ink); border-color: var(--bad-ink); }

.jobhead { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin: -.5rem 0 1rem; }
.jobhead .ref { font: 700 1.1rem "Barlow Condensed", Barlow, sans-serif; color: var(--muted); }
.jobgrid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1rem; }
.jobgrid .panel { margin: 0; }
.jobgrid h2 { margin-top: 0; }
dl { margin: 0; display: grid; grid-template-columns: max-content 1fr; gap: .5rem 1rem; }
dt { color: var(--muted); }
dd { margin: 0; overflow-wrap: anywhere; }
.pre { white-space: pre-wrap; }

.photos { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: .5rem; margin-bottom: .75rem; }
.photos img { width: 100%; aspect-ratio: 4 / 3; object-fit: cover; border-radius: 4px; border: 1px solid var(--line); display: block; }
.inline-form { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin: 0 0 1rem; }
.inline-form input[type="file"] { width: auto; flex: 1 1 220px; margin: 0; }
.admin-actions { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 1rem; margin-top: 1rem; }
.admin-actions .panel { margin: 0; }

.history { list-style: none; padding: 0; margin: 0 0 1rem; border-left: 3px solid var(--line); }
.history li { padding: .3rem 0 .6rem 1rem; }

@media (max-width: 560px) {
  dl { grid-template-columns: 1fr; gap: .1rem; }
  dd { margin-bottom: .5rem; }
}

/* Stage 3: pricing and estimates */
.lead { max-width: 65ch; }
.subnav { display: flex; flex-wrap: wrap; gap: .25rem; margin: 0 0 1.25rem; border-bottom: 2px solid var(--line); }
.subnav a { text-decoration: none; padding: .45rem .8rem; border-bottom: 3px solid transparent; margin-bottom: -2px; color: var(--muted); }
.subnav a[aria-current="page"] { color: var(--ink); border-bottom-color: var(--hivis); font-weight: 600; }
.twocol { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 1.5rem; align-items: start; }
.twocol h2:first-child { margin-top: 0; }
.filters { display: flex; flex-wrap: wrap; gap: .75rem; align-items: end; margin: 0 0 1rem; }
.filters label { margin: 0; }
.filters input, .filters select { width: auto; min-width: 160px; }
td.num, th.num { text-align: right; }
.addmat { display: grid; grid-template-columns: 1fr 120px auto; gap: .75rem; align-items: end; margin-top: .75rem; }
.addmat label { margin: 0; }
.accessrow { display: grid; grid-template-columns: 1fr 120px auto auto; gap: .75rem; align-items: end; margin-bottom: .5rem; }
.accessrow label { margin: 0; }
.accessrow.off { opacity: .6; }

.choices { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: .75rem; }
.choice { display: flex; flex-direction: column; gap: .25rem; text-decoration: none; background: var(--surface); border: 1px solid var(--line); border-left: 5px solid var(--slate); border-radius: 6px; padding: .9rem 1rem; }
.choice:hover { border-left-color: var(--hivis); }
.choice span { color: var(--muted); font-size: .92rem; }
.picked { display: flex; gap: .75rem; align-items: baseline; margin: 0 0 .75rem; }
.fieldlabel { font-weight: 500; margin: 0 0 .4rem; }

.estimate .bigprice { font: 700 2rem/1.1 "Barlow Condensed", Barlow, sans-serif; margin: .25rem 0 .5rem; }
.estimate details { margin: .75rem 0; }
.estimate summary { cursor: pointer; font-weight: 600; }
.breakdown td { white-space: normal; }
.breakdown tr.group th { background: var(--bg); color: var(--ink); }
.breakdown tr.sum td { font-weight: 600; }
.breakdown tr.grand td { font-weight: 700; font-size: 1.1rem; border-top: 2px solid var(--ink); }
.warnings { background: var(--bad-bg); color: var(--bad-ink); border-radius: 4px; padding: .6rem 1rem .6rem 2rem; margin: .75rem 0 0; }

@media (max-width: 560px) {
  .addmat, .accessrow { grid-template-columns: 1fr; }
}

/* Stage 3b: worksheets, time, emails */
.staffonly { border-left: 6px solid var(--slate); }
.staffonly h2 { margin-top: 0; display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; }
.staffonly h2 .tag { font: 500 .8rem Barlow, sans-serif; }
.small { font-size: .9rem; }
.buttons { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; }
.clock { display: flex; flex-wrap: wrap; gap: .75rem; align-items: end; margin-bottom: .75rem; }
.clock p { margin: 0; flex-basis: 100%; }
.clock label { margin: 0; flex: 1 1 220px; }
.clock.on { background: var(--ok-bg); color: var(--ok-ink); padding: .75rem; border-radius: 4px; }
.clock.on input { background: var(--surface); color: var(--ink); }

.worksheet { max-width: 1000px; }
.wline { display: grid; grid-template-columns: 120px 1fr 80px 80px 100px 90px 90px; gap: .5rem; align-items: end; padding: .5rem 0; border-bottom: 1px solid var(--line); }
.wline label { margin: 0; font-size: .85rem; }
.wline.new { opacity: .8; }
.wline .ltotal { text-align: right; padding-bottom: .6rem; font-weight: 600; }
.wline .del { padding-bottom: .55rem; }
.wtotals { max-width: 360px; margin: 1rem 0 1rem auto; }
.wtotals div { display: flex; justify-content: space-between; padding: .2rem 0; }
.wtotals .sum { border-top: 1px solid var(--line); font-weight: 600; margin-top: .3rem; padding-top: .4rem; }
.wtotals .grand { font-weight: 700; font-size: 1.15rem; border-top: 2px solid var(--ink); margin-top: .3rem; padding-top: .4rem; }

.emailtpl summary { cursor: pointer; display: flex; flex-wrap: wrap; gap: .5rem; align-items: baseline; }
.emailtpl form { margin-top: 1rem; }
.preview { white-space: pre-wrap; background: var(--bg); border: 1px solid var(--line); border-radius: 4px; padding: .75rem 1rem; font-size: .95rem; }
code { background: var(--bg); padding: 0 .3rem; border-radius: 3px; font-size: .9em; }

@media (max-width: 760px) {
  .wline { grid-template-columns: 1fr 1fr 1fr; }
  .wline .desc { grid-column: 1 / -1; grid-row: 1; }
  .wline .ltotal { text-align: left; }
}

/* Stage 4: quotes */
.quote { border-top: 6px solid var(--hivis); }
.quotehead { display: flex; flex-wrap: wrap; gap: .75rem; align-items: center; justify-content: space-between; }
.quotehead h2 { margin: 0; }
.quote h3 { font: 600 1.1rem "Barlow Condensed", Barlow, sans-serif; margin: 1rem 0 .3rem; }
.quote .wtotals { margin: 1rem 0 1rem auto; }
.quotetable td { white-space: normal; }
.tag.ok { background: var(--ok-bg); color: var(--ok-ink); border-color: transparent; }
.respond { display: flex; flex-wrap: wrap; gap: 1rem; align-items: start; margin-top: 1rem; padding-top: 1rem; border-top: 1px solid var(--line); }
.respond details summary { cursor: pointer; padding: .6rem 0; color: var(--muted); }
.sendquote { margin: 1rem 0 0; background: var(--bg); }
.sendquote summary { cursor: pointer; }
.sendquote form { margin-top: 1rem; }

/* Stage 5: after the quote */
.nextstep h3, .invoices h3 { font: 600 1.15rem "Barlow Condensed", Barlow, sans-serif; margin: 1rem 0 .5rem; }
.nextstep h3:first-of-type { margin-top: .25rem; }
.nextstep form.inline { display: inline-block; margin: .25rem .5rem .25rem 0; }
.schedule { display: grid; grid-template-columns: 1.2fr 1fr 1fr auto; gap: .75rem; align-items: end; }
.schedule label { margin: 0; }
.invoices .invoice { border-top: 1px solid var(--line); padding-top: .75rem; margin-top: .75rem; }
.invoices .invoice:first-of-type { border-top: 0; margin-top: 0; padding-top: 0; }
.invoices .invoice.void { opacity: .6; }
.invoices .wtotals { margin: .5rem 0 .75rem auto; }
.payhow { background: var(--bg); border-radius: 4px; padding: .5rem 1rem; margin-top: .75rem; }
.recordpay { margin-top: .75rem; }
.recordpay summary { cursor: pointer; font-weight: 600; }
.recordpay .panel { margin-top: .5rem; }
.payments { margin: 0; padding-left: 1.2rem; }
.pline { display: grid; grid-template-columns: 1fr 80px 160px 150px 1fr 90px; gap: .5rem; align-items: end; padding: .5rem 0; border-bottom: 1px solid var(--line); }
.pline label { margin: 0; font-size: .85rem; }
.pline.new { opacity: .8; }
.pline .del { padding-bottom: .55rem; }
.route .stops { padding-left: 1.3rem; margin: 0 0 1rem; }
.route .stops li { margin-bottom: .6rem; }
.todo { list-style: none; padding: 0; margin: 0; display: grid; gap: .4rem; }
.todo li { background: var(--surface); border: 1px solid var(--line); border-left: 5px solid var(--hivis); border-radius: 4px; padding: .6rem .8rem; }
.todo a { text-decoration: none; }
@media (max-width: 760px) {
  .schedule { grid-template-columns: 1fr 1fr; }
  .pline { grid-template-columns: 1fr 1fr; }
  .pline .desc { grid-column: 1 / -1; }
}

/* Job history */
tr.closedjob td { color: var(--muted); }
tr.closedjob td a { color: var(--ink); }
.pager { display: flex; gap: 1rem; align-items: center; justify-content: center; margin: 1rem 0; }
HANDYTRIO_EOF

touch src/server.js
echo ""
echo "Job history installed. The app restarts by itself; otherwise run: npm run dev"
