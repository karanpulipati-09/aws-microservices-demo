const express = require('express');
const client = require('prom-client');
const pool = require('./db');

const PORT = process.env.PORT || 3000;
const ENV = process.env.APP_ENV || 'dev';
const SHA = process.env.IMAGE_TAG || null;

const app = express();
app.use(express.json());

// --- metrics ---
client.collectDefaultMetrics();
const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1, 2],
});
app.use((req, res, next) => {
  const end = httpDuration.startTimer();
  res.on('finish', () => {
    const route = req.route ? req.baseUrl + req.route.path : 'unmatched';
    end({ method: req.method, route, status: res.statusCode });
  });
  next();
});

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

// --- health ---
// liveness: process is up (no DB call, so a DB outage does not restart pods)
const health = (_req, res) =>
  res.json({ status: 'ok', env: ENV, version: '1.1.0', sha: SHA, deployedBy: 'ArgoCD' });
app.get('/health', health);
app.get('/api/health', health);

// readiness: can we reach the database?
const ready = async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ready', db: 'ok' });
  } catch (err) {
    res.status(503).json({ status: 'not ready', db: 'unreachable' });
  }
};
app.get('/ready', ready);
app.get('/api/ready', ready);

// --- tasks ---
const wrap = (fn) => (req, res) =>
  fn(req, res).catch((err) => {
    console.error(err.message);
    res.status(500).json({ error: 'internal error' });
  });

app.get('/api/tasks', wrap(async (_req, res) => {
  const [rows] = await pool.query('SELECT id, title, done, created_at FROM tasks ORDER BY id DESC LIMIT 100');
  res.json(rows);
}));

app.post('/api/tasks', wrap(async (req, res) => {
  const title = (req.body && req.body.title || '').toString().trim();
  if (!title || title.length > 255) {
    return res.status(400).json({ error: 'title is required (max 255 chars)' });
  }
  const [result] = await pool.query('INSERT INTO tasks (title) VALUES (?)', [title]);
  res.status(201).json({ id: result.insertId, title, done: false });
}));

app.patch('/api/tasks/:id', wrap(async (req, res) => {
  const done = Boolean(req.body && req.body.done);
  const [result] = await pool.query('UPDATE tasks SET done = ? WHERE id = ?', [done, req.params.id]);
  if (!result.affectedRows) return res.status(404).json({ error: 'not found' });
  res.json({ id: Number(req.params.id), done });
}));

app.delete('/api/tasks/:id', wrap(async (req, res) => {
  const [result] = await pool.query('DELETE FROM tasks WHERE id = ?', [req.params.id]);
  if (!result.affectedRows) return res.status(404).json({ error: 'not found' });
  res.status(204).end();
}));

app.use((_req, res) => res.status(404).json({ error: 'not found' }));

app.listen(PORT, () => console.log(`API running on port ${PORT} [${ENV}]`));
