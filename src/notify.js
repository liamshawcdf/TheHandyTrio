// Customer emails. Sends through SMTP when it is set up in .env, and logs every email either way.
const nodemailer = require('nodemailer');
const { query } = require('./db');
const { label } = require('./statuses');
const { ref } = require('./format');
const { customerSummary } = require('./estimate');

let transport;
function getTransport() {
  if (transport !== undefined) return transport;
  if (!process.env.SMTP_HOST) {
    transport = null;
    return transport;
  }
  const port = Number(process.env.SMTP_PORT || 587);
  transport = nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port,
    secure: port === 465,
    auth: process.env.SMTP_USER ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS } : undefined,
  });
  return transport;
}

const emailReady = () => Boolean(process.env.SMTP_HOST);
const fill = (text, vars) => String(text).replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k] ?? '') : m));

async function sendEmail({ to, subject, body, jobId = null }) {
  const t = getTransport();
  let status = 'sent';
  let error = null;
  if (!to) {
    status = 'skipped';
    error = 'No email address';
  } else if (!t) {
    status = 'not sent';
    error = 'Email sending is not set up yet';
  } else {
    try {
      await t.sendMail({ from: process.env.SMTP_FROM || process.env.SMTP_USER, to, subject, text: body });
    } catch (e) {
      status = 'failed';
      error = String(e.message || e).slice(0, 300);
    }
  }
  await query('INSERT INTO email_log (job_id, to_address, subject, body, status, error) VALUES ($1, $2, $3, $4, $5, $6)',
    [jobId, to || null, subject, body, status, error]);
  return { status, error };
}

async function jobVars(jobId, status, baseUrl) {
  const job = (await query(
    'SELECT j.*, c.name AS customer_name, c.email AS customer_email FROM jobs j JOIN users c ON c.id = j.customer_id WHERE j.id = $1',
    [jobId])).rows[0];
  if (!job) return null;
  const s = (await query('SELECT business_name FROM settings WHERE id = 1')).rows[0];
  return {
    job,
    vars: {
      customer_name: job.customer_name,
      first_name: String(job.customer_name || '').split(' ')[0],
      job_ref: ref(job.id),
      job_title: job.title,
      stage: label(status),
      price_guide: job.estimate_snapshot ? customerSummary(job.estimate_snapshot) : 'to be confirmed',
      job_link: `${baseUrl}/jobs/${job.id}`,
      business_name: s.business_name,
    },
  };
}

// Never throws: a failed email must not stop the job being updated.
async function notifyStageChange(jobId, status, baseUrl) {
  try {
    const tpl = (await query('SELECT * FROM email_templates WHERE status = $1', [status])).rows[0];
    if (!tpl || !tpl.enabled) return;
    const data = await jobVars(jobId, status, baseUrl);
    if (!data) return;
    await sendEmail({ to: data.job.customer_email, subject: fill(tpl.subject, data.vars), body: fill(tpl.body, data.vars), jobId });
  } catch (e) {
    console.error('Customer email failed:', e);
  }
}

const PLACEHOLDERS = ['first_name', 'customer_name', 'job_ref', 'job_title', 'stage', 'price_guide', 'job_link', 'business_name'];

module.exports = { notifyStageChange, sendEmail, fill, emailReady, PLACEHOLDERS };
