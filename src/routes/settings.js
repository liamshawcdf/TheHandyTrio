const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const privacyDefault = require('../privacy-default');

const router = express.Router();

// One list drives both the form and the save, so adding a setting is one line here plus a column in schema.sql.
const GROUPS = [
  ['Business', [
    ['business_name', 'Business name', 'text'],
    ['currency', 'Currency symbol', 'text'],
    ['base_postcode', 'Base postcode (used for travel only when no builder has a home postcode)', 'text'],
    ['service_radius_miles', 'Service area (miles)', 'number', '1'],
    ['vat_registered', 'VAT registered', 'bool'],
    ['vat_rate', 'VAT rate (%)', 'number', '0.1'],
  ]],
  ['Labour', [
    ['hourly_rate', 'Hourly rate per person', 'number', '0.01'],
    ['day_rate', 'Day rate per person', 'number', '0.01'],
    ['hours_per_day', 'Hours in a working day', 'number', '0.5'],
    ['default_crew', 'Default crew size', 'int', '1'],
    ['minimum_charge', 'Minimum charge per job', 'number', '0.01'],
  ]],
  ['Materials', [
    ['markup_pct', 'Markup on supplier prices (%)', 'number', '0.1'],
    ['waste_pct', 'Waste allowance on cut materials (%)', 'number', '0.1'],
  ]],
  ['Travel', [
    ['mileage_rate', 'Rate per mile', 'number', '0.01'],
    ['charge_travel_time', 'Charge for travel time', 'bool'],
    ['travel_hourly_rate', 'Travel time hourly rate', 'number', '0.01'],
  ]],
  ['Estimates', [
    ['contingency_pct', 'Contingency (%)', 'number', '0.1'],
    ['range_low_pct', 'Range shown below estimate (%)', 'number', '0.1'],
    ['range_high_pct', 'Range shown above estimate (%)', 'number', '0.1'],
    ['urgent_premium_pct', 'Urgent job premium (%)', 'number', '0.1'],
    ['urgent_within_hours', 'Counts as urgent if needed within (hours)', 'int', '1'],
  ]],
  ['Quotes and documents', [
    ['business_address', 'Business address (shown on quotes)', 'textarea'],
    ['business_phone', 'Business phone', 'text'],
    ['business_email', 'Business email', 'text'],
    ['quote_valid_days', 'Quotes valid for (days)', 'int', '1'],
    ['quote_terms', 'Terms printed on quotes', 'textarea'],
  ]],
  ['Privacy', [
    ['privacy_notice', 'Privacy notice shown to customers (review this so it matches how you work)', 'textarea'],
  ]],
  ['Payments', [
    ['deposit_pct', 'Deposit on accepted quotes (%)', 'number', '0.1'],
    ['payment_terms_days', 'Invoice payment terms (days)', 'int', '1'],
    ['payment_instructions', 'How customers can pay (shown on invoices)', 'textarea'],
    ['bank_details', 'Bank details for transfers (account name, sort code, account number)', 'textarea'],
  ]],
];
const FIELDS = GROUPS.flatMap(([, f]) => f);

function form(s) {
  const groups = GROUPS.map(([name, fields]) => `<fieldset class="panel"><legend>${esc(name)}</legend>
    ${fields.map(([key, lbl, type, step]) => type === 'bool'
      ? `<label class="check"><input type="checkbox" name="${key}" ${s[key] ? 'checked' : ''}> ${esc(lbl)}</label>`
      : type === 'textarea'
      ? `<label>${esc(lbl)}<textarea name="${key}" rows="${key === 'privacy_notice' ? 16 : 3}" maxlength="10000">${esc(s[key])}</textarea></label>`
      : `<label>${esc(lbl)}<input name="${key}" value="${esc(s[key])}" ${type === 'text' ? '' : `type="number" min="0" step="${step}" required`}></label>`
    ).join('')}
  </fieldset>`).join('');
  return `<form method="post" action="/admin/settings" class="settings">${groups}<button class="primary">Save settings</button></form>`;
}

router.get('/admin/settings', requireRole('admin'), wrap(async (req, res) => {
  const s = (await query('SELECT * FROM settings WHERE id = 1')).rows[0];
  if (!s.privacy_notice) s.privacy_notice = privacyDefault(s);
  res.send(page({ title: 'Rates & settings', user: req.user, notice: req.query.saved ? 'Settings saved.' : null, body: form(s) }));
}));

router.post('/admin/settings', requireRole('admin'), wrap(async (req, res) => {
  const values = [];
  for (const [key, lbl, type] of FIELDS) {
    const raw = req.body[key];
    if (type === 'bool') values.push(raw === 'on');
    else if (type === 'text' || type === 'textarea') values.push(String(raw || '').replace(/\r\n/g, '\n').trim().slice(0, 10000));
    else {
      const n = Number(raw);
      if (raw === '' || raw === undefined || !Number.isFinite(n) || n < 0 || (type === 'int' && !Number.isInteger(n))) {
        const s = { ...(await query('SELECT * FROM settings WHERE id = 1')).rows[0], ...req.body };
        return res.status(400).send(page({ title: 'Rates & settings', user: req.user, error: `Check “${lbl}”: it needs to be a number of 0 or more.`, body: form(s) }));
      }
      values.push(n);
    }
  }
  const pc = FIELDS.findIndex(([k]) => k === 'base_postcode');
  values[pc] = values[pc].toUpperCase();
  const sets = FIELDS.map(([key], i) => `${key} = $${i + 1}`).join(', ');
  await query(`UPDATE settings SET ${sets}, updated_at = now() WHERE id = 1`, values);
  res.redirect('/admin/settings?saved=1');
}));

module.exports = router;
