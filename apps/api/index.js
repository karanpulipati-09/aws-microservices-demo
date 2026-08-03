const http = require('http');

const PORT = process.env.PORT || 3000;
const ENV  = process.env.APP_ENV || 'dev';
const SHA  = process.env.IMAGE_TAG || null;

const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Access-Control-Allow-Origin', '*');

  if (req.url === '/health' || req.url === '/api/health') {
    res.writeHead(200);
    res.end(JSON.stringify({ status: 'ok', env: ENV, version: '1.0.0', sha: SHA }));
  } else {
    res.writeHead(404);
    res.end(JSON.stringify({ error: 'not found' }));
  }
});

server.listen(PORT, () => console.log(`API running on port ${PORT} [${ENV}]`));
// v1.0.4
