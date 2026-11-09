// Branded A4 documents (quotes and invoices) with page numbers.
const PDFDocument = require('pdfkit');

/*
  opts: { res, download, filename, s (settings), title, meta: [[label, value]], customer: {name, lines},
          heading, intro, itemised, rows: [{description, qty, unit, price, total}], money,
          totals: [[label, value, bold?]], afterTotals: [text], blocks: [{title, text}] }
*/
function renderDocument(opts) {
  const { res, s, money: m } = opts;
  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `${opts.download ? 'attachment' : 'inline'}; filename="${opts.filename}"`);
  const doc = new PDFDocument({ size: 'A4', margin: 50, bufferPages: true, info: { Title: `${opts.title} ${opts.filename}`, Author: s.business_name } });
  doc.pipe(res);

  const W = doc.page.width;
  const L = 50;
  const R = W - 50;
  const ink = '#1d2529';
  const muted = '#5d6a70';

  doc.rect(0, 0, W, 86).fill('#24414f');
  doc.rect(0, 86, W, 6).fill('#f2c300');
  doc.fillColor('#ffffff').font('Helvetica-Bold').fontSize(22).text(s.business_name, L, 28, { width: 300 });
  const contact = [s.business_address, s.business_phone, s.business_email].filter(Boolean).join('\n');
  if (contact) doc.font('Helvetica').fontSize(9).text(contact, R - 220, 26, { width: 220, align: 'right' });

  doc.fillColor(ink).font('Helvetica-Bold').fontSize(20).text(opts.title, L, 115);
  let my = 115;
  for (const [k, v] of opts.meta) {
    doc.font('Helvetica').fontSize(9).fillColor(muted).text(k, R - 200, my, { width: 80 });
    doc.font('Helvetica-Bold').fillColor(ink).text(String(v ?? ''), R - 120, my, { width: 120, align: 'right' });
    my += 14;
  }
  doc.font('Helvetica').fontSize(9).fillColor(muted).text('For', L, 150);
  doc.font('Helvetica-Bold').fontSize(11).fillColor(ink).text(opts.customer.name, L, 162);
  doc.font('Helvetica').fontSize(10).text(opts.customer.lines.filter(Boolean).join('\n'), L, doc.y + 2, { width: 260 });

  doc.y = Math.max(doc.y, my) + 22;
  doc.font('Helvetica-Bold').fontSize(13).fillColor(ink).text(opts.heading, L, doc.y, { width: R - L });
  if (opts.intro) doc.moveDown(0.3).font('Helvetica').fontSize(10).text(opts.intro, { width: R - L });
  doc.moveDown(1);

  const cols = opts.itemised
    ? [['Description', L, 245, 'left'], ['Qty', L + 250, 45, 'right'], ['Unit', L + 300, 45, 'left'], ['Price', L + 350, 70, 'right'], ['Total', R - 75, 75, 'right']]
    : [['Description', L, 360, 'left'], ['Total', R - 100, 100, 'right']];
  const header = () => {
    const y = doc.y;
    doc.rect(L, y - 4, R - L, 20).fill('#e9ecea');
    doc.fillColor(ink).font('Helvetica-Bold').fontSize(9);
    for (const [t, x, w, a] of cols) doc.text(t, x + 4, y + 2, { width: w - 8, align: a });
    doc.y = y + 22;
  };
  header();
  doc.font('Helvetica').fontSize(10);
  const q = (n) => (n === null || n === undefined ? '' : String(Math.round(n * 100) / 100));
  for (const r of opts.rows) {
    const vals = opts.itemised ? [r.description, q(r.qty), r.unit || '', r.price === null ? '' : m(r.price), m(r.total)] : [r.description, m(r.total)];
    const h = Math.max(14, doc.heightOfString(r.description, { width: cols[0][2] - 8 }));
    if (doc.y + h > doc.page.height - 140) { doc.addPage(); doc.y = 60; header(); doc.font('Helvetica').fontSize(10); }
    const y = doc.y;
    cols.forEach(([, x, w, a], i) => doc.fillColor(ink).text(vals[i], x + 4, y, { width: w - 8, align: a }));
    doc.y = y + h + 6;
    doc.moveTo(L, doc.y - 3).lineTo(R, doc.y - 3).lineWidth(0.5).strokeColor('#c9d0cd').stroke();
  }

  if (doc.y > doc.page.height - 220) { doc.addPage(); doc.y = 60; }
  doc.moveDown(0.5);
  for (const [k, v, bold] of opts.totals) {
    const y = doc.y;
    if (bold) doc.moveTo(R - 220, y - 2).lineTo(R, y - 2).lineWidth(1.2).strokeColor(ink).stroke();
    doc.font(bold ? 'Helvetica-Bold' : 'Helvetica').fontSize(bold ? 12 : 10).fillColor(ink);
    doc.text(k, R - 220, y + (bold ? 3 : 0), { width: 120 });
    doc.text(v, R - 100, y + (bold ? 3 : 0), { width: 100, align: 'right' });
    doc.y = y + (bold ? 22 : 16);
  }
  for (const t of opts.afterTotals || []) {
    doc.font('Helvetica').fontSize(10).fillColor(muted).text(t, R - 300, doc.y + 2, { width: 300, align: 'right' });
  }

  doc.x = L;
  doc.moveDown(1.5);
  for (const b of opts.blocks || []) {
    if (!b.text) continue;
    if (doc.y > doc.page.height - 120) { doc.addPage(); doc.y = 60; }
    if (b.title) doc.font('Helvetica-Bold').fontSize(b.small ? 9 : 10).fillColor(b.small ? muted : ink).text(b.title, L, doc.y, { width: R - L });
    doc.font('Helvetica').fontSize(b.small ? 8.5 : 10).fillColor(b.small ? muted : ink).text(b.text, L, doc.y, { width: R - L });
    doc.moveDown(1);
  }

  const range = doc.bufferedPageRange();
  for (let i = 0; i < range.count; i++) {
    doc.switchToPage(range.start + i);
    const bottom = doc.page.margins.bottom;
    doc.page.margins.bottom = 0;
    doc.font('Helvetica').fontSize(8).fillColor(muted)
      .text(`${s.business_name}  |  ${opts.filename.replace(/\.pdf$/, '')}  |  Page ${i + 1} of ${range.count}`, L, doc.page.height - 35, { width: R - L, align: 'center' });
    doc.page.margins.bottom = bottom;
  }
  doc.end();
}

module.exports = { renderDocument };
