const express = require('express');
const { query } = require('../db');
const { page, esc } = require('../layout');
const { wrap, requireRole } = require('../auth');
const privacyDefault = require('../privacy-default');
const multer = require('multer');
const { loadBrand, HEX } = require('../brand');

const logoUpload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 2 * 1024 * 1024, files: 1 } });

const router = express.Router();

// One list drives both the form and the save, so adding a setting is one line here plus a column in schema.sql.
const GROUPS = [
  ['Business', [
    ['business_name', 'Business name (shown everywhere: website, emails, quotes, invoices, certificates)', 'text'],
    ['brand_primary', 'Brand colour (buttons, links, highlights, PDF headers)', 'color'],
    ['brand_accent', 'Soft colour (the thin stripe under PDF headers)', 'color'],
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
  ['Inspection bookings', [
    ['inspection_days', 'Days customers can book (e.g. Mon,Tue,Wed,Thu,Fri)', 'text'],
    ['inspection_start', 'First visit starts (24-hour, e.g. 09:00)', 'text'],
    ['inspection_end', 'Last visit finishes by (e.g. 16:00)', 'text'],
    ['inspection_slot_minutes', 'Length of a visit (minutes)', 'int', '5'],
    ['inspection_notice_hours', 'Minimum notice for booking or changing (hours)', 'int', '1'],
    ['inspection_horizon_days', 'How far ahead customers can book (days)', 'int', '1'],
  ]],
  ['Reminders and reviews', [
    ['reminder_days_before', 'Email customers this many days before a certificate is due', 'int', '1'],
    ['texts_enabled', 'Send day-before text reminders', 'bool'],
    ['review_link', 'Your Google (or other) review link, e.g. https://g.page/r/…/review', 'text'],
    ['review_delay_days', 'Ask for a review this many days after a job is paid', 'int', '1'],
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
      : type === 'color'
      ? `<label class="colour">${esc(lbl)}<span><input type="color" name="${key}" value="${esc(s[key])}"> <code>${esc(s[key])}</code></span></label>`
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
  const logoPanel = `<section class="panel branding" id="branding">
    <h2>Logo</h2>
    ${s.logo ? `<p><img class="logoprev" src="/brand/logo?v=${s.logo_updated_at ? new Date(s.logo_updated_at).getTime() : 0}" alt="Current logo"></p>` : '<p class="muted">No logo yet, so the business name is shown on its own.</p>'}
    <form method="post" action="/admin/settings/logo" enctype="multipart/form-data" class="inline-form">
      <input type="file" name="logo" accept="image/png,image/jpeg" required>
      <button class="small">${s.logo ? 'Replace logo' : 'Upload logo'}</button>
    </form>
    ${s.logo ? '<form method="post" action="/admin/settings/logo/remove" class="inline"><button class="small danger">Remove logo</button></form>' : ''}
    <p class="hint">PNG or JPEG, under 2 MB. A wide logo on a transparent background works best. It appears in the website header, as the browser icon, and on quotes, invoices and certificates.</p>
  </section>`;
  res.send(page({ title: 'Rates & settings', user: req.user, notice: req.query.saved ? 'Settings saved.' : null, error: req.query.error ? String(req.query.error).slice(0, 200) : null, body: logoPanel + form(s) }));
}));

router.post('/admin/settings', requireRole('admin'), wrap(async (req, res) => {
  const values = [];
  for (const [key, lbl, type] of FIELDS) {
    const raw = req.body[key];
    if (type === 'bool') values.push(raw === 'on');
    else if (type === 'color') values.push(HEX.test(String(raw || '')) ? String(raw).toLowerCase() : (key === 'brand_accent' ? '#dbe8f5' : '#2e6fb7'));
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
  await loadBrand();
  res.redirect('/admin/settings?saved=1');
}));

// ---------- Logo ----------
router.get('/brand/logo', wrap(async (req, res) => {
  const r = (await query('SELECT logo, logo_mime FROM settings WHERE id = 1')).rows[0];
  if (!r || !r.logo) return res.sendStatus(404);
  res.set('Cache-Control', 'public, max-age=31536000, immutable');
  res.type(r.logo_mime);
  res.send(r.logo);
}));

router.post('/admin/settings/logo', requireRole('admin'), (req, res, next) => {
  logoUpload.single('logo')(req, res, async (err) => {
    try {
      if (err) return res.redirect('/admin/settings?error=' + encodeURIComponent(err.code === 'LIMIT_FILE_SIZE' ? 'The logo must be under 2 MB.' : 'The logo couldn’t be uploaded.') + '#branding');
      const f = req.file;
      if (!f || !['image/png', 'image/jpeg'].includes(f.mimetype)) {
        return res.redirect('/admin/settings?error=' + encodeURIComponent('Upload the logo as a PNG or JPEG image.') + '#branding');
      }
      await query('UPDATE settings SET logo = $1, logo_mime = $2, logo_updated_at = now() WHERE id = 1', [f.buffer, f.mimetype]);
      await loadBrand();
      res.redirect('/admin/settings?saved=1#branding');
    } catch (e) {
      next(e);
    }
  });
});

router.post('/admin/settings/logo/remove', requireRole('admin'), wrap(async (req, res) => {
  await query('UPDATE settings SET logo = NULL, logo_mime = NULL, logo_updated_at = now() WHERE id = 1');
  await loadBrand();
  res.redirect('/admin/settings?saved=1#branding');
}));

module.exports = router;
