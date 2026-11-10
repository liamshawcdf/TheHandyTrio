// The business's name, colours and logo, kept in memory so every page can use them.
// Reloaded whenever Settings are saved.
const { query } = require('./db');

let cache = null;
const HEX = /^#[0-9a-f]{6}$/i;

// Dark text on light colours, white text on dark ones.
function inkFor(hex) {
  const n = parseInt(hex.slice(1), 16);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => {
    const v = c / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.4 ? '#1d2529' : '#ffffff';
}

async function loadBrand() {
  const s = (await query(
    `SELECT business_name, brand_primary, brand_accent, logo IS NOT NULL AS has_logo,
       coalesce(extract(epoch FROM logo_updated_at)::bigint, 0) AS logo_version FROM settings WHERE id = 1`)).rows[0] || {};
  const primary = HEX.test(s.brand_primary || '') ? s.brand_primary : '#2e6fb7';
  const accent = HEX.test(s.brand_accent || '') ? s.brand_accent : '#dbe8f5';
  cache = {
    name: s.business_name || 'SWAT Maintenance',
    primary, accent,
    primaryInk: inkFor(primary),
    accentInk: inkFor(accent),
    hasLogo: Boolean(s.has_logo),
    logoVersion: s.logo_version || 0,
  };
  return cache;
}

const brand = () => cache || { name: 'SWAT Maintenance', primary: '#2e6fb7', accent: '#dbe8f5', primaryInk: '#ffffff', accentInk: '#1d2529', hasLogo: false, logoVersion: 0 };

module.exports = { loadBrand, brand, HEX };
