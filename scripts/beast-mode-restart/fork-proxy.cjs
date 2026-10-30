'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const origin = 'https://api.cartridge.gg/x/starknet/mainnet/rpc/v0_10';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const allowed = new Set(['starknet_chainId', 'starknet_specVersion', 'starknet_blockNumber',
  'starknet_getBlockWithTxHashes', 'starknet_getBlockWithTxs', 'starknet_getClassHashAt',
  'starknet_getClassAt', 'starknet_getClass', 'starknet_getStorageAt', 'starknet_getNonce', 'starknet_call']);

// Fork hydration can burst hundreds of origin reads. Serialize them, cache only
// immutable block-specific replies, and never forward any transaction/devnet RPC.
async function startForkProxy({ cacheDirectory, intervalMs = 100, fetcher = fetch }) {
  fs.mkdirSync(cacheDirectory, { recursive: true });
  let queue = Promise.resolve(), lastRead = 0;
  const server = http.createServer(async (req, res) => {
    let id = null;
    try {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks).toString());
      id = body.id;
      if (!allowed.has(body.method)) throw new Error('Read-only fork origin: method refused');
      const params = body.params || {};
      const fixedBlock = params.block_id && typeof params.block_id === 'object' &&
        ('block_number' in params.block_id || 'block_hash' in params.block_id);
      const key = createHash('sha256').update(JSON.stringify([body.method, params])).digest('hex');
      const file = path.join(cacheDirectory, `${key}.json`);
      async function read() {
        if (fixedBlock && fs.existsSync(file)) return JSON.parse(fs.readFileSync(file, 'utf8'));
        for (let attempt = 0; attempt < 7; attempt++) {
          await sleep(Math.max(0, lastRead + intervalMs - Date.now()));
          lastRead = Date.now();
          const response = await fetcher(origin, { method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ ...body, id: 1 }), signal: AbortSignal.timeout(120000) });
          if (response.status === 429 || response.status >= 500) {
            if (attempt === 6) throw new Error(`Fork origin returned HTTP ${response.status}`);
            await sleep(Math.min(30000, 2000 * 2 ** attempt)); continue;
          }
          if (!response.ok) throw new Error(`Fork origin returned HTTP ${response.status}`);
          const reply = await response.json();
          if (fixedBlock && !reply.error) fs.writeFileSync(file, JSON.stringify(reply));
          return reply;
        }
      }
      const task = queue.then(read); queue = task.catch(() => {});
      const reply = await task;
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ...reply, id }));
    } catch (error) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32600, message: error.message } }));
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { url: `http://127.0.0.1:${server.address().port}/rpc`,
    close: () => new Promise(resolve => server.close(resolve)) };
}
module.exports = { startForkProxy };
