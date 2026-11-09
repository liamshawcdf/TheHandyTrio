// Runs every hour in the background: certificate renewal reminders, day-before texts and review requests.
// Each message is recorded in reminders_sent first, so nothing is ever sent twice.
const { query } = require('./db');
const { sendEmail, fill, jobVars } = require('./notify');
const { sendSms } = require('./sms');
const { TYPES } = require('./certtypes');
const { day, ukDate, addDays, TZ } = require('./format');

let lastBaseUrl = process.env.APP_URL || 'http://localhost:3000';
const rememberBaseUrl = (url) => { if (!process.env.APP_URL && url) lastBaseUrl = url; };

async function claim(kind, refId, key = '') {
  const r = await query('INSERT INTO reminders_sent (kind, ref_id, key) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING id', [kind, refId, key]);
  return r.rows[0] ? r.rows[0].id : null;
}
const mark = (id, status) => query('UPDATE reminders_sent SET status = $1 WHERE id = $2', [status, id]);
const ukHour = () => Number(new Date().toLocaleString('en-GB', { timeZone: TZ, hour: '2-digit', hour12: false }));

async function emailTemplate(key) {
  return (await query('SELECT * FROM email_templates WHERE status = $1 AND enabled', [key])).rows[0] || null;
}

async function certificateReminders(s, base, out) {
  const tpl = await emailTemplate('cert_due');
  if (!tpl) return;
  const due = (await query(
    `SELECT c.*, j.customer_id, j.address_line, j.town, j.postcode, u.marketing_opt_out
     FROM certificates c JOIN jobs j ON j.id = c.job_id JOIN users u ON u.id = j.customer_id
     WHERE c.status = 'issued' AND c.next_due IS NOT NULL AND u.active
       AND c.next_due <= current_date + $1::int AND c.next_due >= current_date - 30
       AND NOT EXISTS (SELECT 1 FROM certificates n JOIN jobs nj ON nj.id = n.job_id
         WHERE n.type = c.type AND n.status IN ('issued', 'draft') AND n.id > c.id AND nj.customer_id = j.customer_id AND nj.postcode IS NOT DISTINCT FROM j.postcode)`,
    [Number(s.reminder_days_before) || 30])).rows;
  for (const c of due) {
    if (c.marketing_opt_out || !TYPES[c.type]) continue;
    const id = await claim('cert_due', c.id);
    if (!id) continue;
    const data = await jobVars(c.job_id, 'paid', base);
    const vars = {
      ...data.vars,
      cert_name: TYPES[c.type].name,
      due_date: day(c.next_due),
      address: [c.address_line, c.town, c.postcode].filter(Boolean).join(', '),
      landlord_note: c.type === 'gas_safety' ? ' and keeps you legal as a landlord' : '',
      book_link: `${base}/rebook/${c.id}`,
    };
    const body = fill(tpl.body, vars) + `\n\nDon’t want reminders like this? Turn them off in your account: ${base}/account`;
    const r = await sendEmail({ to: data.job.customer_email, subject: fill(tpl.subject, vars), body, jobId: c.job_id });
    await mark(id, r.status);
    out.certificates++;
  }
}

async function dayBeforeTexts(s, base, out) {
  if (!s.texts_enabled) return;
  const hour = ukHour();
  if (hour < 9 || hour >= 20) return; // no texts at unsociable hours
  const tomorrow = addDays(ukDate(new Date()), 1);
  const tpls = Object.fromEntries((await query('SELECT * FROM sms_templates WHERE enabled')).rows.map((t) => [t.key, t]));

  const inspections = tpls.inspection_reminder ? (await query(
    `SELECT j.id, j.inspection_at, u.phone, u.sms_opt_out FROM jobs j JOIN users u ON u.id = j.customer_id
     WHERE j.status = 'inspection_booked' AND j.inspection_at IS NOT NULL`)).rows.filter((j) => ukDate(j.inspection_at) === tomorrow) : [];
  for (const j of inspections) {
    if (j.sms_opt_out || !j.phone) continue;
    const id = await claim('inspection_text', j.id, new Date(j.inspection_at).toISOString());
    if (!id) continue;
    const data = await jobVars(j.id, 'inspection_booked', base);
    const r = await sendSms({ to: j.phone, body: fill(tpls.inspection_reminder.body, data.vars), jobId: j.id });
    await mark(id, r.status);
    out.texts++;
  }

  const starts = tpls.job_reminder ? (await query(
    `SELECT j.id, j.scheduled_start, u.phone, u.sms_opt_out FROM jobs j JOIN users u ON u.id = j.customer_id
     WHERE j.status = 'scheduled' AND j.scheduled_start = $1::date`, [tomorrow])).rows : [];
  for (const j of starts) {
    if (j.sms_opt_out || !j.phone) continue;
    const id = await claim('job_text', j.id, tomorrow);
    if (!id) continue;
    const data = await jobVars(j.id, 'scheduled', base);
    const r = await sendSms({ to: j.phone, body: fill(tpls.job_reminder.body, data.vars), jobId: j.id });
    await mark(id, r.status);
    out.texts++;
  }
}

async function reviewRequests(s, base, out) {
  if (!s.review_link) return;
  const tpl = await emailTemplate('review_request');
  if (!tpl) return;
  const delay = Math.max(0, Number(s.review_delay_days) || 0);
  const jobs = (await query(
    `SELECT j.id, u.marketing_opt_out FROM jobs j JOIN users u ON u.id = j.customer_id
     WHERE j.status = 'paid' AND EXISTS (SELECT 1 FROM job_status_history h WHERE h.job_id = j.id AND h.to_status = 'paid'
       AND h.created_at <= now() - make_interval(days => $1::int) AND h.created_at >= now() - interval '30 days')`, [delay])).rows;
  for (const j of jobs) {
    if (j.marketing_opt_out) continue;
    const id = await claim('review', j.id);
    if (!id) continue;
    const data = await jobVars(j.id, 'paid', base);
    const vars = { ...data.vars, review_link: s.review_link };
    const body = fill(tpl.body, vars) + `\n\nDon’t want emails like this? Turn them off in your account: ${base}/account`;
    const r = await sendEmail({ to: data.job.customer_email, subject: fill(tpl.subject, vars), body, jobId: j.id });
    await mark(id, r.status);
    out.reviews++;
  }
}

let running = false;
async function runReminders() {
  if (running) return null;
  running = true;
  const out = { certificates: 0, texts: 0, reviews: 0 };
  try {
    const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
    await certificateReminders(s, lastBaseUrl, out);
    await dayBeforeTexts(s, lastBaseUrl, out);
    await reviewRequests(s, lastBaseUrl, out);
  } catch (e) {
    console.error('Reminders failed:', e);
  } finally {
    running = false;
  }
  return out;
}

function startScheduler() {
  setTimeout(runReminders, 60 * 1000);
  setInterval(runReminders, 60 * 60 * 1000);
}

module.exports = { runReminders, startScheduler, rememberBaseUrl };
