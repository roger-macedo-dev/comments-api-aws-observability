const pool = require('./pool');

async function migrate() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS comments (
      id SERIAL PRIMARY KEY,
      email TEXT NOT NULL,
      comment TEXT NOT NULL,
      content_id INTEGER NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);

  await pool.query(`
    CREATE INDEX IF NOT EXISTS idx_comments_content_id
    ON comments (content_id)
  `);

  console.log('Migration OK: tabela comments pronta.');
}

module.exports = migrate;

if (require.main === module) {
  migrate()
    .then(() => process.exit(0))
    .catch((err) => {
      console.error('Migration falhou:', err);
      process.exit(1);
    });
}
