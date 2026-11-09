// Shared job helpers: loading a job the current person may see, and recording stage changes.
const { query } = require('./db');
const { page } = require('./layout');

const JOB_SELECT = `SELECT j.*, c.name AS customer_name, c.phone AS customer_phone, c.email AS customer_email,
    b.name AS builder_name
  FROM jobs j JOIN users c ON c.id = j.customer_id LEFT JOIN users b ON b.id = j.assigned_builder_id`;

function canSee(user, job) {
  return user.role === 'admin'
    || (user.role === 'customer' && job.customer_id === user.id)
    || (user.role === 'builder' && job.assigned_builder_id === user.id);
}

async function loadJob(req) {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id < 1) return null;
  const { rows } = await query(`${JOB_SELECT} WHERE j.id = $1`, [id]);
  const job = rows[0];
  return job && canSee(req.user, job) ? job : null;
}

const notFound = (req, res) =>
  res.status(404).send(page({ title: 'Job not found', user: req.user, body: '<p>That job doesn’t exist or isn’t yours to view.</p><p><a href="/dashboard">Back to your dashboard</a></p>' }));

async function setStatus(client, jobId, from, to, userId, note) {
  await client.query('UPDATE jobs SET status = $1, updated_at = now() WHERE id = $2', [to, jobId]);
  await client.query(
    'INSERT INTO job_status_history (job_id, from_status, to_status, changed_by, note) VALUES ($1, $2, $3, $4, $5)',
    [jobId, from, to, userId, note || null]
  );
}

const baseUrlOf = (req) => (process.env.APP_URL || `${req.protocol}://${req.get('host')}`).replace(/\/$/, '');

module.exports = { JOB_SELECT, canSee, loadJob, notFound, setStatus, baseUrlOf };
