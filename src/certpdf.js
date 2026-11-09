// Builds a certificate PDF in memory, so it can be downloaded or attached to an email.
const PDFDocument = require('pdfkit');
const { TYPES } = require('./certtypes');

const fmtDate = (d) => (d ? new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '');

function buildCertificatePdf({ cert, number, job, customer, s }) {
  const t = TYPES[cert.type];
  const d = cert.data || {};
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 40, bufferPages: true, info: { Title: `${t.name} ${number}`, Author: s.business_name } });
    const chunks = [];
    doc.on('data', (c) => chunks.push(c));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);

    const W = doc.page.width;
    const L = 40;
    const R = W - 40;
    const ink = '#1d2529';
    const muted = '#5d6a70';
    const line = '#c9d0cd';
    const ensure = (h) => { if (doc.y + h > doc.page.height - 60) { doc.addPage(); doc.y = 50; } };

    // Header
    doc.rect(0, 0, W, 78).fill('#24414f');
    doc.rect(0, 78, W, 5).fill('#f2c300');
    doc.fillColor('#ffffff').font('Helvetica-Bold').fontSize(18).text(s.business_name, L, 22, { width: 280 });
    const contact = [s.business_address, s.business_phone, s.business_email].filter(Boolean).join('\n');
    if (contact) doc.font('Helvetica').fontSize(8).text(contact, R - 220, 20, { width: 220, align: 'right' });

    doc.fillColor(ink).font('Helvetica-Bold').fontSize(16).text(t.name, L, 98, { width: R - L - 170 });
    const meta = [['Number', number], ['Issued', fmtDate(cert.issued_at) || 'Draft'], ['Next due', fmtDate(cert.next_due) || 'n/a'], ...(job.ref ? [['Job', job.ref]] : [])];
    let my = 98;
    for (const [k, v] of meta) {
      doc.font('Helvetica').fontSize(8).fillColor(muted).text(k, R - 160, my, { width: 60 });
      doc.font('Helvetica-Bold').fontSize(9).fillColor(ink).text(String(v), R - 100, my, { width: 100, align: 'right' });
      my += 13;
    }
    doc.y = Math.max(doc.y, my) + 8;

    // Outcome banner
    const bad = cert.outcome && t.bad(cert.outcome);
    const by = doc.y;
    doc.rect(L, by, R - L, 24).fill(bad ? '#fbe4e1' : '#e2f1e4');
    doc.fillColor(bad ? '#8a2418' : '#1f5a2a').font('Helvetica-Bold').fontSize(11).text(`Outcome: ${cert.outcome || 'Not yet issued'}`, L + 10, by + 7, { width: R - L - 20 });
    doc.y = by + 34;

    // Parties
    const colW = (R - L - 20) / 2;
    const py = doc.y;
    const party = (x, title, lines) => {
      doc.font('Helvetica-Bold').fontSize(8).fillColor(muted).text(title, x, py, { width: colW });
      doc.font('Helvetica').fontSize(9).fillColor(ink).text(lines.filter(Boolean).join('\n'), x, doc.y + 2, { width: colW });
      return doc.y;
    };
    const y1 = party(L, 'Installation address', [customer.name, job.address_line, job.town, job.postcode, customer.phone, customer.email]);
    const y2 = party(L + colW + 20, 'Engineer', [cert.engineer_name, cert.engineer_scheme && cert.engineer_number ? `${cert.engineer_scheme} no. ${cert.engineer_number}` : '', cert.engineer_categories]);
    doc.y = Math.max(y1, y2) + 14;

    // Sections
    const sectionTitle = (title) => {
      ensure(40);
      const y = doc.y;
      doc.rect(L, y, R - L, 18).fill('#e9ecea');
      doc.fillColor(ink).font('Helvetica-Bold').fontSize(10).text(title, L + 6, y + 4, { width: R - L - 12 });
      doc.y = y + 24;
    };
    const kvGrid = (fields, values) => {
      const filled = fields.filter(([k]) => values[k] !== undefined && String(values[k]).trim() !== '');
      const cw = (R - L - 16) / 2;
      for (let i = 0; i < filled.length; i += 2) {
        const pair = filled.slice(i, i + 2);
        const heights = pair.map(([k, lbl]) => doc.font('Helvetica').fontSize(8.5).heightOfString(String(values[k]), { width: cw * 0.5 }));
        const h = Math.max(12, ...heights);
        ensure(h + 4);
        const y = doc.y;
        pair.forEach(([k, lbl], j) => {
          const x = L + j * (cw + 16);
          doc.font('Helvetica').fontSize(8).fillColor(muted).text(lbl, x, y, { width: cw * 0.5 - 4 });
          doc.font('Helvetica-Bold').fontSize(8.5).fillColor(ink).text(String(values[k]), x + cw * 0.5, y, { width: cw * 0.5 });
        });
        doc.y = y + h + 4;
      }
      if (!filled.length) doc.font('Helvetica').fontSize(8.5).fillColor(muted).text('Nothing recorded.', L, doc.y).moveDown(0.5);
    };
    const table = (fields, rows) => {
      const widths = fields.map(([, , type]) => (type === 'textarea' ? 3 : type === 'text' ? 1.6 : 1));
      const sum = widths.reduce((a, b) => a + b, 0);
      const cols = widths.map((w) => ((R - L) * w) / sum);
      const head = () => {
        const hh = Math.max(...fields.map(([, lbl], i) => doc.font('Helvetica-Bold').fontSize(7).heightOfString(lbl, { width: cols[i] - 4 }))) + 6;
        ensure(hh + 14);
        const y = doc.y;
        doc.rect(L, y, R - L, hh).fill('#f3f5f4');
        let x = L;
        fields.forEach(([, lbl], i) => { doc.fillColor(ink).font('Helvetica-Bold').fontSize(7).text(lbl, x + 2, y + 3, { width: cols[i] - 4 }); x += cols[i]; });
        doc.y = y + hh + 2;
      };
      head();
      for (const r of rows) {
        const h = Math.max(11, ...fields.map(([k], i) => doc.font('Helvetica').fontSize(7.5).heightOfString(String(r[k] ?? ''), { width: cols[i] - 4 }))) + 4;
        if (doc.y + h > doc.page.height - 60) { doc.addPage(); doc.y = 50; head(); }
        const y = doc.y;
        let x = L;
        fields.forEach(([k], i) => {
          const v = String(r[k] ?? '');
          const red = v === 'Fail' || v === 'C1' || v === 'C2' || v === 'FI';
          doc.fillColor(red ? '#8a2418' : ink).font(red ? 'Helvetica-Bold' : 'Helvetica').fontSize(7.5).text(v, x + 2, y + 2, { width: cols[i] - 4 });
          x += cols[i];
        });
        doc.y = y + h;
        doc.moveTo(L, doc.y).lineTo(R, doc.y).lineWidth(0.4).strokeColor(line).stroke();
      }
      if (!rows.length) doc.font('Helvetica').fontSize(8.5).fillColor(muted).text('None recorded.', L, doc.y + 2);
      doc.y += 6;
    };

    for (const sec of t.sections) {
      sectionTitle(sec.title);
      if (!sec.group) { kvGrid(sec.fields, d); continue; }
      const items = d[sec.group] || [];
      if (sec.table) table(sec.fields, items);
      else if (!items.length) doc.font('Helvetica').fontSize(8.5).fillColor(muted).text('None recorded.', L, doc.y).moveDown(0.5);
      else items.forEach((item, i) => {
        ensure(30);
        doc.font('Helvetica-Bold').fontSize(9).fillColor(ink).text(`${sec.itemLabel} ${i + 1}${item.location ? `: ${item.location}` : ''}`, L, doc.y);
        doc.moveDown(0.2);
        kvGrid(sec.fields, item);
        doc.moveDown(0.3);
      });
      if (sec.group === 'observations' && t.codesNote) {
        doc.font('Helvetica').fontSize(7).fillColor(muted).text(t.codesNote, L, doc.y, { width: R - L });
        doc.moveDown(0.5);
      }
    }

    // Declaration
    ensure(70);
    sectionTitle('Declaration');
    doc.font('Helvetica').fontSize(8.5).fillColor(ink).text(
      `I confirm the inspection and tests recorded above were carried out by me, and the results are a true record at the time of the visit.`,
      L, doc.y, { width: R - L });
    doc.moveDown(0.6);
    doc.font('Helvetica').fontSize(8).fillColor(muted).text('Signed (typed)', L, doc.y, { continued: true }).fillColor(ink).font('Helvetica-Bold').text(`   ${cert.declaration_name || ''}`);
    doc.font('Helvetica').fontSize(8).fillColor(muted).text('Date', L, doc.y + 2, { continued: true }).fillColor(ink).font('Helvetica-Bold').text(`   ${fmtDate(cert.issued_at)}`);
    if (cert.status === 'void') {
      doc.moveDown(0.6).font('Helvetica-Bold').fontSize(12).fillColor('#8a2418').text(`CANCELLED: ${cert.void_reason || ''}`, L, doc.y, { width: R - L });
    }

    const range = doc.bufferedPageRange();
    for (let i = 0; i < range.count; i++) {
      doc.switchToPage(range.start + i);
      const bottom = doc.page.margins.bottom;
      doc.page.margins.bottom = 0;
      doc.font('Helvetica').fontSize(7.5).fillColor(muted)
        .text(`${s.business_name}  |  ${t.name} ${number}  |  Page ${i + 1} of ${range.count}`, L, doc.page.height - 28, { width: R - L, align: 'center' });
      if (cert.status === 'draft') {
        doc.save().rotate(-35, { origin: [W / 2, doc.page.height / 2] }).font('Helvetica-Bold').fontSize(90).fillColor('#e9ecea', 0.6)
          .text('DRAFT', 0, doc.page.height / 2 - 50, { width: W, align: 'center' }).restore();
      }
      doc.page.margins.bottom = bottom;
    }
    doc.end();
  });
}

module.exports = { buildCertificatePdf };
