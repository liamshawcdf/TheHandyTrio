// Database connection settings. Uses SSL for databases reached over the internet
// (like Render's external address) and plain connections for local or private ones.
// Force it either way with DATABASE_SSL=1 or DATABASE_SSL=0.
function pgConfig(url = process.env.DATABASE_URL) {
  let ssl = false;
  if (process.env.DATABASE_SSL === '1') ssl = true;
  else if (process.env.DATABASE_SSL !== '0') {
    try {
      const host = new URL(url).hostname;
      ssl = host.includes('.') && !/^(localhost|127\.0\.0\.1)$/.test(host);
    } catch (e) {
      ssl = false;
    }
  }
  return { connectionString: url, ssl: ssl ? { rejectUnauthorized: false } : false };
}
module.exports = { pgConfig };
