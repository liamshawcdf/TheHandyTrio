const express = require('express');
const { pool, query } = require('../db');
const { page } = require('../layout');
const { wrap, requireRole } = require('../auth');
const { when } = require('../format');
const { makeBackup } = require('../backup');

const router = express.Router();
const admin = requireRole('admin');

router.get('/admin/backups', admin, wrap(async (req, res) => {
  const log = (await query('SELECT b.*, u.name FROM backup_log b LEFT JOIN users u ON u.id = b.created_by ORDER BY b.created_at DESC LIMIT 20')).rows;
  const size = (n) => (n > 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`);
  const body = `<div class="twocol">
    <section>
      <form method="post" action="/admin/backups" class="panel">
        <p>Downloads everything: customers, jobs, quotes, invoices, payments, certificates, price list and settings, in one file.</p>
        <label class="check"><input type="checkbox" name="photos" checked> Include photos (bigger file)</label>
        <button class="primary">Download a backup now</button>
      </form>
      <div class="panel">
        <h2>Keeping backups safe</h2>
        <p>Save the file somewhere other than this app, such as iCloud Drive, OneDrive or a USB stick. It holds customers’ personal details, so keep it private.</p>
        <p>Aim for once a week. The dashboard reminds you if it’s been longer.</p>
        <p>To restore in an emergency, put the file in the project folder and run <code>npm run restore -- backup-file-name.json.gz</code> in the terminal. It replaces all current data with the backup.</p>
      </div>
    </section>
    <section>
      <h2>Recent backups</h2>
      ${log.length ? `<ul class="certlist">${log.map((b) => `<li>${when(b.created_at)} <span class="muted">${b.name ? `by ${b.name}, ` : ''}${b.include_photos ? 'with photos' : 'without photos'}, ${size(Number(b.size_bytes) || 0)}</span></li>`).join('')}</ul>` : '<p class="empty">No backups yet.</p>'}
    </section>
  </div>`;
  res.send(page({ title: 'Backups', user: req.user, body }));
}));

router.post('/admin/backups', admin, wrap(async (req, res) => {
  const includePhotos = req.body.photos === 'on';
  const client = await pool.connect();
  let gz;
  try {
    gz = await makeBackup(client, { includePhotos });
  } finally {
    client.release();
  }
  await query('INSERT INTO backup_log (created_by, include_photos, size_bytes) VALUES ($1, $2, $3)', [req.user.id, includePhotos, gz.length]);
  const stamp = new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-');
  res.setHeader('Content-Type', 'application/gzip');
  res.setHeader('Content-Disposition', `attachment; filename="handytrio-backup-${stamp}.json.gz"`);
  res.send(gz);
}));

module.exports = router;
