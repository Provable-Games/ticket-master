const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { validateQuote } = require('./web/pricing.cjs');
let cachedQuote = null, quoteFetchedAt = 0, pendingQuote = null;
async function lordsQuote() {
  if (cachedQuote && Date.now() - quoteFetchedAt < 300000) return validateQuote(cachedQuote);
  if (pendingQuote) return pendingQuote;
  pendingQuote = (async () => {
    const response = await fetch('https://api.coingecko.com/api/v3/simple/price?ids=lords&vs_currencies=usd&include_last_updated_at=true',
      { signal: AbortSignal.timeout(10000) });
    if (!response.ok) throw new Error('Price provider unavailable');
    const data = (await response.json()).lords;
    const quote = validateQuote({ usd: data?.usd, updatedAt: data?.last_updated_at * 1000, source: 'CoinGecko' });
    cachedQuote = quote; quoteFetchedAt = Date.now();
    return quote;
  })();
  try { return await pendingQuote; } finally { pendingQuote = null; }
}
const root = path.resolve(process.env.BEAST_STAGING_DIST || '/workspace/.scratch/beast-mode-restart/web-dist');
const files = { '/': ['index.html', 'text/html'], '/index.html': ['index.html', 'text/html'],
  '/app.js': ['app.js', 'text/javascript'], '/style.css': ['style.css', 'text/css'] };
const server = http.createServer(async (req, res) => {
  const pathname = new URL(req.url, 'http://localhost').pathname;
  if (pathname === '/api/lords-usd' && req.method === 'GET') {
    res.setHeader('content-type', 'application/json');
    res.setHeader('cache-control', 'no-store');
    try { return res.end(JSON.stringify(await lordsQuote())); }
    catch { res.writeHead(503); return res.end(JSON.stringify({ error: 'A recent LORDS/USD quote is unavailable.' })); }
  }
  const asset = files[pathname];
  if (!asset || req.method !== 'GET') { res.writeHead(404); return res.end('Not found'); }
  res.writeHead(200, { 'content-type': `${asset[1]}; charset=utf-8`, 'cache-control': 'no-store',
    'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' });
  fs.createReadStream(path.join(root, asset[0])).pipe(res);
});
server.listen(Number(process.env.PORT || 4178), process.env.HOST || '127.0.0.1', () => {
  const port = server.address().port;
  const file = path.join(path.dirname(root), 'web-server-process.json');
  fs.writeFileSync(file, JSON.stringify({ pid: process.pid, port, root }));
  console.log(`Beast Mode staging: http://localhost:${port}`);
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
