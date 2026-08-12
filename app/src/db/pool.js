require('dotenv').config();
const { Pool } = require('pg');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  connectionTimeoutMillis: 3000,
});

pool.on('error', (err) => {
  console.error('Erro inesperado no pool do Postgres:', err.message);
});

module.exports = pool;
