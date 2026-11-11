const mysql = require('mysql2/promise');

// Credentials arrive as env vars, injected from a Kubernetes Secret
// that External Secrets Operator syncs from AWS Secrets Manager.
const pool = mysql.createPool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  waitForConnections: true,
  connectionLimit: 5,
  connectTimeout: 5000,
});

module.exports = pool;
