// The job lifecycle, in order. Keys must match the CHECK list in db/schema.sql.
const STATUSES = [
  ['request', 'New request'],
  ['inspection_required', 'Inspection required'],
  ['estimated', 'Estimate sent'],
  ['inspection_booked', 'Inspection booked'],
  ['inspected', 'Inspected'],
  ['quoted', 'Quote sent'],
  ['accepted', 'Quote accepted'],
  ['declined', 'Declined'],
  ['deposit_requested', 'Deposit requested'],
  ['deposit_paid', 'Deposit paid'],
  ['parts_ordered', 'Parts ordered'],
  ['scheduled', 'Scheduled'],
  ['in_progress', 'In progress'],
  ['complete', 'Work complete'],
  ['invoiced', 'Invoiced'],
  ['paid', 'Paid'],
  ['cancelled', 'Cancelled'],
];

const LABELS = Object.fromEntries(STATUSES);
const CLOSED = ['paid', 'declined', 'cancelled'];

module.exports = {
  STATUSES,
  CLOSED,
  label: (key) => LABELS[key] || key,
};
