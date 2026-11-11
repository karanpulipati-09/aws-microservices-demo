// Idempotent schema migration. Runs as a Helm/ArgoCD PreSync Job before the API rolls out.
const pool = require('./db');

async function main() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS tasks (
      id         INT AUTO_INCREMENT PRIMARY KEY,
      title      VARCHAR(255) NOT NULL,
      done       BOOLEAN NOT NULL DEFAULT FALSE,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  `);
  console.log('migration complete');
  await pool.end();
}

main().catch((err) => {
  console.error('migration failed:', err.message);
  process.exit(1);
});
