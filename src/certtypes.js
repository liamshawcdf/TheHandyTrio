// Certificate types and their forms. Each field: [key, label, type, options?]
// Types: text, textarea, date, number, yn (Yes/No/N/A), pf (Pass/Fail/N/A), select (options).
// Groups repeat (appliances, observations, circuits, items). "table" groups print as a table on the PDF.

const YN = ['Yes', 'No', 'N/A'];
const PF = ['Pass', 'Fail', 'N/A'];
const FLUES = ['Room sealed', 'Open flue', 'Flueless', 'Balanced flue', 'Fanned flue'];
const EARTHING = ['TN-S', 'TN-C-S', 'TT', 'IT'];

const QUAL_KINDS = {
  gas: { label: 'Gas Safe registration', scheme: 'Gas Safe Register', categoriesHint: 'e.g. CCN1, CENWAT, HTR1, CKR1' },
  electrical: { label: 'Electrical competent person scheme', scheme: 'NICEIC', categoriesHint: 'e.g. Domestic Installer, 18th Edition, 2391' },
  pat: { label: 'PAT testing', scheme: 'City & Guilds 2377', categoriesHint: 'e.g. 2377-77' },
};

const TYPES = {
  gas_safety: {
    name: 'Landlord Gas Safety Record', prefix: 'GSR', requires: ['gas'], nextDueMonths: 12,
    sections: [
      { title: 'Landlord or agent', fields: [
        ['landlord_name', 'Landlord or agent name', 'text'],
        ['landlord_address', 'Landlord or agent address', 'textarea'],
        ['tenant_name', 'Tenant or occupier', 'text'],
      ] },
      { title: 'Appliances', group: 'appliances', blank: 1, itemLabel: 'Appliance', fields: [
        ['location', 'Location', 'text'],
        ['type', 'Appliance type', 'select', ['Boiler', 'Gas fire', 'Hob', 'Cooker', 'Water heater', 'Warm air unit', 'Other']],
        ['make', 'Make', 'text'],
        ['model', 'Model', 'text'],
        ['flue', 'Flue type', 'select', FLUES],
        ['landlords', 'Landlord’s appliance', 'yn'],
        ['inspected', 'Appliance inspected', 'yn'],
        ['pressure', 'Operating pressure (mbar) or heat input (kW)', 'text'],
        ['safety_device', 'Safety device correct operation', 'pf'],
        ['ventilation', 'Ventilation satisfactory', 'pf'],
        ['flue_visual', 'Visual condition of flue and termination', 'pf'],
        ['flue_test', 'Flue performance tests', 'pf'],
        ['co_ppm', 'Combustion CO (ppm)', 'number'],
        ['co2_pct', 'Combustion CO2 (%)', 'number'],
        ['ratio', 'CO/CO2 ratio', 'number'],
        ['serviced', 'Appliance serviced', 'yn'],
        ['safe', 'Appliance safe to use', 'yn'],
      ] },
      { title: 'Installation checks', fields: [
        ['tightness', 'Gas tightness test', 'pf'],
        ['pipework', 'Visual inspection of installation pipework', 'pf'],
        ['ecv', 'Emergency control valve accessible', 'yn'],
        ['bonding', 'Protective equipotential bonding satisfactory', 'yn'],
        ['co_alarm', 'Carbon monoxide alarm fitted and tested', 'yn'],
      ] },
      { title: 'Defects and action', fields: [
        ['defects', 'Defects identified', 'textarea'],
        ['remedial', 'Remedial action taken', 'textarea'],
        ['warning_notice', 'Warning notice issued', 'yn'],
      ] },
    ],
    outcome: (d) => ((d.appliances || []).some((a) => a.safe === 'No') || d.tightness === 'Fail' ? 'Unsafe items found' : 'Appliances safe to use'),
    bad: (o) => o.startsWith('Unsafe'),
  },

  boiler_service: {
    name: 'Boiler Service Record', prefix: 'BSR', requires: ['gas'], nextDueMonths: 12,
    sections: [
      { title: 'Appliance', fields: [
        ['make', 'Make', 'text'], ['model', 'Model', 'text'], ['serial', 'Serial number', 'text'], ['location', 'Location', 'text'],
        ['type', 'Boiler type', 'select', ['Combi', 'System', 'Regular (heat only)', 'Back boiler', 'Other']],
        ['fuel', 'Fuel', 'select', ['Natural gas', 'LPG']],
        ['flue', 'Flue type', 'select', FLUES],
      ] },
      { title: 'Readings', fields: [
        ['gas_rate', 'Gas rate (m³/h or kW)', 'text'], ['op_pressure', 'Operating pressure (mbar)', 'number'],
        ['burner_pressure', 'Burner pressure (mbar)', 'number'],
        ['co_high', 'CO high fire (ppm)', 'number'], ['co2_high', 'CO2 high fire (%)', 'number'], ['ratio_high', 'Ratio high fire', 'number'],
        ['co_low', 'CO low fire (ppm)', 'number'], ['co2_low', 'CO2 low fire (%)', 'number'], ['ratio_low', 'Ratio low fire', 'number'],
        ['system_pressure', 'System pressure (bar)', 'number'], ['expansion', 'Expansion vessel charge (bar)', 'number'],
      ] },
      { title: 'Checks', fields: [
        ['heat_exchanger', 'Heat exchanger', 'pf'], ['burner', 'Burner and injectors', 'pf'], ['ignition', 'Ignition', 'pf'],
        ['flame', 'Flame picture', 'pf'], ['seals', 'Case and seals', 'pf'], ['condensate', 'Condensate trap and pipe', 'pf'],
        ['safety_devices', 'Safety devices', 'pf'], ['flue_check', 'Flue route and termination', 'pf'],
        ['ventilation', 'Ventilation', 'pf'], ['controls', 'Controls and thermostats', 'pf'], ['tightness', 'Gas tightness', 'pf'],
      ] },
      { title: 'Work and advice', fields: [
        ['work_done', 'Work carried out', 'textarea'], ['parts', 'Parts fitted', 'textarea'],
        ['recommendations', 'Recommendations', 'textarea'], ['safe', 'Appliance safe to use', 'yn'],
      ] },
    ],
    outcome: (d) => (d.safe === 'No' ? 'Not safe to use' : 'Serviced, safe to use'),
    bad: (o) => o.startsWith('Not'),
  },

  warning_notice: {
    name: 'Gas Warning Notice', prefix: 'GWN', requires: ['gas'], nextDueMonths: 0,
    sections: [
      { title: 'Unsafe situation', fields: [
        ['location', 'Location', 'text'], ['appliance', 'Appliance or part of installation', 'text'], ['make_model', 'Make and model', 'text'],
        ['classification', 'Classification', 'select', ['Immediately Dangerous (ID)', 'At Risk (AR)']],
        ['fault', 'Details of the fault', 'textarea'],
        ['action', 'Action taken', 'select', ['Turned off and labelled', 'Disconnected and labelled', 'Turned off, customer refused disconnection', 'Advised only']],
        ['customer_refused', 'Customer refused permission to make safe', 'yn'],
        ['gas_emergency', 'Gas Emergency Service informed', 'yn'],
        ['riddor', 'Reportable under RIDDOR', 'yn'],
        ['customer_informed', 'Responsible person informed and given this notice', 'yn'],
      ] },
    ],
    outcome: (d) => d.classification || 'Warning notice',
    bad: () => true,
  },

  eicr: {
    name: 'Electrical Installation Condition Report', prefix: 'EICR', requires: ['electrical'], nextDueField: 'next_inspection',
    sections: [
      { title: 'Report details', fields: [
        ['client_name', 'Person ordering the report', 'text'], ['occupier', 'Occupier', 'text'],
        ['purpose', 'Purpose of the report', 'textarea'], ['extent', 'Extent of the installation covered', 'textarea'],
        ['limitations', 'Agreed limitations', 'textarea'], ['wiring_age', 'Estimated age of wiring (years)', 'number'],
        ['alterations', 'Evidence of additions or alterations', 'yn'], ['records', 'Installation records available', 'yn'],
      ] },
      { title: 'Supply and earthing', fields: [
        ['earthing', 'Earthing arrangement', 'select', EARTHING], ['phases', 'Supply', 'select', ['Single phase', 'Three phase']],
        ['voltage', 'Nominal voltage (V)', 'number'], ['ze', 'External loop impedance Ze (Ω)', 'number'],
        ['pfc', 'Prospective fault current (kA)', 'number'], ['main_switch', 'Main switch rating (A)', 'number'],
        ['main_earth', 'Main earthing conductor (mm²)', 'number'], ['bonding', 'Main bonding conductors (mm²)', 'number'],
        ['electrode', 'Earth electrode resistance (Ω)', 'number'],
      ] },
      { title: 'Observations', group: 'observations', blank: 3, table: true, itemLabel: 'Observation', fields: [
        ['ref', 'Ref', 'text'], ['observation', 'Observation', 'textarea'], ['location', 'Location', 'text'],
        ['code', 'Code', 'select', ['C1', 'C2', 'C3', 'FI']],
      ] },
      { title: 'Circuit test results', group: 'circuits', blank: 3, table: true, itemLabel: 'Circuit', fields: [
        ['no', 'Circuit', 'text'], ['description', 'Description', 'text'], ['ocpd', 'Device type/rating', 'text'],
        ['r1r2', 'R1+R2 (Ω)', 'number'], ['ir', 'Insulation (MΩ)', 'number'], ['zs', 'Zs (Ω)', 'number'],
        ['rcd', 'RCD (ms)', 'number'], ['polarity', 'Polarity', 'pf'], ['result', 'Result', 'pf'],
      ] },
      { title: 'Summary', fields: [
        ['condition', 'General condition of the installation', 'textarea'],
        ['next_inspection', 'Recommended next inspection', 'date'],
      ] },
    ],
    outcome: (d) => ((d.observations || []).some((o) => ['C1', 'C2', 'FI'].includes(o.code)) ? 'Unsatisfactory' : 'Satisfactory'),
    bad: (o) => o === 'Unsatisfactory',
    codesNote: 'C1 Danger present, immediate action required. C2 Potentially dangerous, urgent action required. C3 Improvement recommended. FI Further investigation required without delay.',
  },

  minor_works: {
    name: 'Minor Electrical Installation Works Certificate', prefix: 'MW', requires: ['electrical'], nextDueMonths: 0,
    sections: [
      { title: 'The work', fields: [
        ['description', 'Description of the minor works', 'textarea'], ['location', 'Location', 'text'],
        ['date_complete', 'Date completed', 'date'], ['departures', 'Departures from BS 7671', 'textarea'],
      ] },
      { title: 'Circuit', fields: [
        ['earthing', 'Earthing arrangement', 'select', EARTHING], ['circuit', 'Circuit affected', 'text'],
        ['ocpd', 'Protective device type and rating', 'text'], ['rcd', 'RCD type and rating', 'text'],
      ] },
      { title: 'Test results', fields: [
        ['r1r2', 'Continuity R1+R2 (Ω)', 'number'], ['ir', 'Insulation resistance (MΩ)', 'number'],
        ['polarity', 'Polarity', 'pf'], ['zs', 'Earth fault loop impedance Zs (Ω)', 'number'],
        ['rcd_time', 'RCD operating time (ms)', 'number'], ['rcd_test', 'RCD test button operation', 'pf'],
        ['comments', 'Comments on the existing installation', 'textarea'],
      ] },
    ],
    outcome: (d) => (d.polarity === 'Fail' || d.rcd_test === 'Fail' ? 'Not satisfactory' : 'Completed and tested'),
    bad: (o) => o.startsWith('Not'),
  },

  pat: {
    name: 'Portable Appliance Test Record', prefix: 'PAT', requires: ['pat', 'electrical'], nextDueFromItems: 'retest',
    sections: [
      { title: 'Site', fields: [['client_name', 'Client', 'text'], ['site', 'Site or premises', 'text']] },
      { title: 'Appliances tested', group: 'items', blank: 5, table: true, itemLabel: 'Appliance', fields: [
        ['asset', 'Asset ID', 'text'], ['description', 'Appliance', 'text'], ['location', 'Location', 'text'],
        ['class', 'Class', 'select', ['Class I', 'Class II', 'Class III']], ['visual', 'Visual', 'pf'],
        ['earth', 'Earth (Ω)', 'number'], ['insulation', 'Insulation (MΩ)', 'number'], ['polarity', 'Polarity', 'pf'],
        ['result', 'Result', 'pf'], ['retest', 'Retest (months)', 'select', ['3', '6', '12', '24', '36', '48']],
      ] },
    ],
    outcome: (d) => {
      const items = d.items || [];
      const fail = items.filter((i) => i.result === 'Fail').length;
      return `${items.length - fail} passed, ${fail} failed`;
    },
    bad: (o) => !/ 0 failed$/.test(o),
  },
};

const typeOptions = (t) => (t[2] === 'yn' ? YN : t[2] === 'pf' ? PF : t[3] || []);

module.exports = { TYPES, QUAL_KINDS, typeOptions };
