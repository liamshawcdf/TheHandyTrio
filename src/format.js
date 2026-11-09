const ref = (id) => 'HT-' + String(id).padStart(5, '0');
const day = (d) => (d ? new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '');
const when = (d) => (d ? new Date(d).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '');

const WORK_TYPES = [
  'Carpentry and joinery',
  'Doors and windows',
  'Plumbing',
  'Electrical',
  'Painting and decorating',
  'Tiling and flooring',
  'Plastering',
  'Fencing, decking and garden',
  'Roofing and guttering',
  'Something else',
];

module.exports = { ref, day, when, WORK_TYPES };
