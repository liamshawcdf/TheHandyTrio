// Text messages through Twilio, when it is set up in .env. Every text is logged either way.
const { query } = require('./db');

const smsReady = () => Boolean(process.env.TWILIO_ACCOUNT_SID && process.env.TWILIO_AUTH_TOKEN && process.env.TWILIO_FROM);

// UK numbers to international format: 07700 900123 -> +447700900123.
function ukMobile(raw) {
  const d = String(raw || '').replace(/[^\d+]/g, '');
  if (/^\+447\d{9}$/.test(d)) return d;
  if (/^447\d{9}$/.test(d)) return '+' + d;
  if (/^07\d{9}$/.test(d)) return '+44' + d.slice(1);
  return null;
}

async function sendSms({ to, body, jobId = null }) {
  const number = ukMobile(to);
  let status = 'sent';
  let error = null;
  if (!number) {
    status = 'skipped';
    error = 'No UK mobile number';
  } else if (!smsReady()) {
    status = 'not sent';
    error = 'Text messages are not set up yet';
  } else {
    try {
      const sid = process.env.TWILIO_ACCOUNT_SID;
      const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
        method: 'POST',
        headers: {
          Authorization: 'Basic ' + Buffer.from(`${sid}:${process.env.TWILIO_AUTH_TOKEN}`).toString('base64'),
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({ To: number, From: process.env.TWILIO_FROM, Body: body.slice(0, 640) }).toString(),
        signal: AbortSignal.timeout(15000),
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        status = 'failed';
        error = String(data.message || `Twilio error ${res.status}`).slice(0, 300);
      }
    } catch (e) {
      status = 'failed';
      error = String(e.message || e).slice(0, 300);
    }
  }
  await query('INSERT INTO sms_log (job_id, to_number, body, status, error) VALUES ($1, $2, $3, $4, $5)', [jobId, number || to || null, body, status, error]);
  return { status, error };
}

module.exports = { sendSms, smsReady, ukMobile };
