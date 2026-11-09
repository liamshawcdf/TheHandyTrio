const { Pool } = require('pg');
const { pgConfig } = require('./pgconfig');

const pool = new Pool({ ...pgConfig(), max: 10 });

module.exports = {
  pool,
  query: (text, params) => pool.query(text, params),
};
