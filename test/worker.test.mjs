// Checks for the worker, with a stand-in badge server and a stand-in Connect.
// Run: node --test test/worker.test.mjs   (Node 20+, nothing to install)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker, { fromUnits, quickPicks, scoreLine } from '../worker/worker.js';

const HOST = 'https://solbadge-pay.example.workers.dev';
const KEY = 'test-connect-key';
const ENV = { CONNECT_API_KEY: KEY, BADGE_IDS: '7K2Q9M, 4HX2PD' }; // APP_ID left out: the default is solbadge-pay
const SCORE = readFileSync(new URL('./data/score.json', import.meta.url), 'utf8');
const BALANCE = readFileSync(new URL('./data/balance.json', import.meta.url), 'utf8'); // Connect's GET /drop/balance
const USDC = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

// The badge server: an Ed25519 key pair, its public half served at /api/http/key.
const pair = await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
const rawKey = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
const b64 = (bytes) => btoa(String.fromCharCode(...bytes));

let connectCalls = [];
let connectAnswer = () => ({ status: 201, body: '{"status":"submitted"}' });
let ethosAnswer = () => ({ status: 404, body: '{}' }); // Ethos knows nobody unless a test says so
globalThis.fetch = async (url, init = {}) => {
  url = String(url);
  if (url === 'https://badge-api.solana.com/api/http/key') {
    return new Response(JSON.stringify({ id: 'k1', alg: 'Ed25519', key: b64(rawKey) }));
  }
  if (url.startsWith('https://api.ethos.network/api/v2/score/userkey?userkey=service:x.com:username:')) {
    const a = ethosAnswer(url.split(':').pop());
    if (a === 'timeout') throw new DOMException('timed out', 'TimeoutError');
    return new Response(a.body, { status: a.status });
  }
  if (url.startsWith('https://api.connect.quid.li')) {
    const call = { method: init.method, path: url.slice('https://api.connect.quid.li'.length), headers: init.headers, body: init.body && JSON.parse(init.body) };
    connectCalls.push(call);
    const a = connectAnswer(call);
    if (a === 'timeout') throw new DOMException('timed out', 'TimeoutError');
    return new Response(a.body, { status: a.status });
  }
  throw new Error('unexpected fetch ' + url);
};

let counter = 0;
/** A request as the badge server sends it. `over` changes it after signing. */
async function badge(method, path, body, { id = '7K2Q9M', app = 'solbadge-pay', time = Date.now(), over = {} } = {}) {
  const text = body === undefined ? '' : JSON.stringify(body);
  const request = (counter++).toString(16).padStart(16, '0');
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
  const signed = ['badge-http-v1', method, HOST + path, [...hash].map((b) => b.toString(16).padStart(2, '0')).join(''),
    app, id, 'user-1', String(time), request].join('\n');
  const sig = new Uint8Array(await crypto.subtle.sign('Ed25519', pair.privateKey, new TextEncoder().encode(signed)));
  const headers = {
    'x-badge-app': app, 'x-badge-id': id, 'x-badge-user': 'user-1', 'x-badge-time': String(time),
    'x-badge-request': request, 'x-badge-key': 'k1', 'x-badge-signature': b64(sig), ...over.headers,
  };
  return new Request(HOST + (over.path ?? path), { method, headers, body: method === 'POST' ? (over.body ?? text) : undefined });
}
const call = async (req, env = ENV) => {
  const res = await worker.fetch(req, env);
  const text = await res.text();
  assert.ok(!text.includes(KEY), 'the Connect key must never reach the badge');
  assert.ok(text.length < 3500, 'answers fit the badge');
  return { status: res.status, data: text.startsWith('{') ? JSON.parse(text) : text };
};
const PAYMENT = { id: '3f2b8c1e-9a4d-4e6f-8b7a-1c2d3e4f5a6b', handle: 'quidliprotocol', asset: USDC, units: '1000000' };
const reset = (answer) => { connectCalls = []; connectAnswer = answer ?? (() => ({ status: 201, body: '{}' })); };

test('requests without a valid badge signature are refused before Connect is touched', async () => {
  reset();
  assert.equal((await call(new Request(HOST + '/pay', { method: 'POST', body: JSON.stringify(PAYMENT) }))).status, 401);
  assert.equal((await call(await badge('POST', '/pay', PAYMENT, { app: 'someone-elses-app' }))).status, 401);
  assert.equal((await call(await badge('POST', '/pay', PAYMENT, { time: Date.now() - 120_000 }))).status, 401);
  assert.equal((await call(await badge('POST', '/pay', PAYMENT, { over: { body: JSON.stringify({ ...PAYMENT, units: '5000000' }) } }))).status, 401);
  assert.equal((await call(await badge('POST', '/pay', PAYMENT, { over: { headers: { 'x-badge-id': '4HX2PD' } } }))).status, 401);
  assert.equal((await call(await badge('GET', '/assets', undefined, { over: { path: '/score/quidliprotocol' } }))).status, 401);
  assert.equal((await call(await badge('POST', '/pay', PAYMENT, { over: { headers: { 'x-badge-signature': '!!!' } } }))).status, 401);
  assert.equal(connectCalls.length, 0);
});

test('a replayed request is refused', async () => {
  reset();
  const req = await badge('POST', '/pay', PAYMENT);
  const again = req.clone();
  assert.equal((await call(req)).data.state, 'sent');
  assert.equal((await call(again)).status, 401);
  assert.equal(connectCalls.length, 1);
});

test('only listed badges get through', async () => {
  reset();
  const r = await call(await badge('POST', '/pay', PAYMENT, { id: 'ZZZZZZ' }));
  assert.equal(r.status, 403);
  assert.match(r.data.text, /ZZZZZZ/);
  assert.equal((await call(await badge('GET', '/assets'), { ...ENV, BADGE_IDS: '' })).status, 403);
  assert.equal((await call(await badge('POST', '/pay', PAYMENT, { id: '4HX2PD' }))).data.state, 'sent');
  assert.equal(connectCalls.length, 1);
});

test('a worker without a Connect key says so', async () => {
  reset();
  const r = await call(await badge('GET', '/assets'), { ...ENV, CONNECT_API_KEY: undefined });
  assert.equal(r.status, 403);
  assert.equal(connectCalls.length, 0);
});

test('/assets offers what the Connect wallet holds on Solana', async () => {
  reset(() => ({ status: 200, body: BALANCE }));
  const r = await call(await badge('GET', '/assets'));
  assert.equal(r.status, 200);
  assert.equal(connectCalls[0].path, '/drop/balance?chainId=1399811149');
  assert.equal(connectCalls[0].headers['x-api-key'], KEY);
  const [sol, bonk, usdc] = r.data.assets;
  assert.equal(r.data.assets.length, 3, 'entries Connect sent malformed are left out');
  assert.equal(r.data.wallet, 'Badge4BJRYfnu29GPWdksz7EMUbiqx5CKSZgov3AHQXe', 'the address to top the wallet up');
  assert.deepEqual(sol, { id: 'sol', label: 'SOL', chain: 'Solana', dec: 9, max: '0.052096561', amounts: ['0.005', '0.01', '0.02', '0.05'] },
    'SOL first, with 0.01 SOL kept back for fees');
  assert.deepEqual(bonk, { id: 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263', label: 'Bonk', chain: 'Solana', dec: 5, max: '1234567.89012', amounts: ['100000', '200000', '500000', '1000000'] });
  assert.deepEqual(usdc, { id: USDC, label: 'USDC', chain: 'Solana', dec: 6, max: '10', amounts: ['1', '2', '5', '10'] });
  // The Lua harness serves test/data/assets.json as the worker's answer; keep it in step.
  const fixture = JSON.parse(readFileSync(new URL('./data/assets.json', import.meta.url), 'utf8'));
  assert.deepEqual(fixture, r.data, 'test/data/assets.json is out of date with the worker');
});

test('/assets explains a wallet it cannot offer', async () => {
  const text = async (answer) => { reset(() => answer); return (await call(await badge('GET', '/assets'))).data; };
  assert.deepEqual(await text({ status: 200, body: '{"assets":[{"type":"native","decimals":9,"balanceInWei":"9000000"}]}' }),
    { text: 'The Connect wallet has nothing to send on Solana yet. Add some SOL first.' }, 'under 0.01 SOL is all kept for fees');
  assert.deepEqual(await text({ status: 200, body: '{"walletAddress":"Badge4BJRYfnu29GPWdksz7EMUbiqx5CKSZgov3AHQXe","assets":[]}' }),
    { text: 'The Connect wallet has nothing to send on Solana yet. Add some SOL first.', wallet: 'Badge4BJRYfnu29GPWdksz7EMUbiqx5CKSZgov3AHQXe' },
    'an empty wallet still says where to send funds');
  assert.equal((await text({ status: 200, body: '{"walletAddress":"<b>not an address</b>","assets":[]}' })).wallet, undefined);
  assert.deepEqual(await text({ status: 401, body: '{"message":"Invalid API key"}' }), { text: "Connect refused the worker's API key." });
  assert.deepEqual(await text('timeout'), { text: "Connect didn't answer in time." });
  const many = Array.from({ length: 12 }, (_, i) => ({ type: 'erc20', tokenContract: USDC.slice(0, -2) + String(10 + i), symbol: 'T' + i, decimals: 0, balanceInWei: '3' }));
  reset(() => ({ status: 200, body: JSON.stringify({ assets: many }) }));
  assert.equal((await call(await badge('GET', '/assets'))).data.assets.length, 8, 'the list stays short');
});

test('/score trims Connect\'s answer for the badge', async () => {
  reset(() => ({ status: 200, body: SCORE }));
  const r = await call(await badge('GET', '/score/quidliprotocol'));
  assert.equal(r.data.score, 96);
  assert.equal(r.data.lines[0], 'Farcaster reputation: 0.96');
  assert.equal(connectCalls[0].path, '/scores/twitter/quidliprotocol');
  assert.ok(!('x-api-key' in connectCalls[0].headers), 'a reputation check goes without the key');
  reset(() => ({ status: 200, body: '{"quidliScore":null,"categories":{}}' }));
  assert.deepEqual((await call(await badge('GET', '/score/nobody'))).data, { score: null, lines: [] });
  // Not a Connect member, but Connect knows their X reputation (Connect's answer for @toly).
  reset(() => ({ status: 200, body: '{"quidliScore":null,"categories":{"socials":[{"code":"ethos_twitter_reputation","label":"𝕏 reputation","source":"ethos","value":1985,"reference":"reputable","normalized":false}]}}' }));
  assert.deepEqual((await call(await badge('GET', '/score/toly'))).data, { score: null, lines: ['X reputation: 1985 (reputable)'] });
  reset(() => ({ status: 429, body: '{"message":"Too many requests"}' }));
  assert.equal((await call(await badge('GET', '/score/nobody'))).data.text, 'Too many requests');
  reset();
  assert.equal((await call(await badge('GET', '/score/not%20a%20handle'))).status, 400);
  assert.equal(connectCalls.length, 0);
});

test('/pay sends what the badge asked, with the worker\'s key', async () => {
  reset();
  assert.deepEqual((await call(await badge('POST', '/pay', PAYMENT))).data, { state: 'sent' });
  assert.equal(connectCalls.length, 1);
  const c = connectCalls[0];
  assert.equal(c.method, 'POST');
  assert.equal(c.path, '/drop');
  assert.equal(c.headers['x-api-key'], KEY);
  assert.deepEqual(c.body, {
    idempotencyKey: PAYMENT.id, chainId: 1399811149, tokenContract: USDC,
    recipients: [{ type: 'twitter', username: 'quidliprotocol' }], amountInWeiPerRecipient: '1000000',
  });
  reset();
  await call(await badge('POST', '/pay', { ...PAYMENT, asset: 'sol', units: '5000000' }));
  assert.equal(connectCalls[0].body.amountInWeiPerRecipient, '5000000');
  assert.ok(!('tokenContract' in connectCalls[0].body), 'SOL is sent without a token');
  reset();
  await call(await badge('POST', '/pay', { ...PAYMENT, units: '123456789012345678901234567890' }));
  assert.equal(connectCalls[0].body.amountInWeiPerRecipient, '123456789012345678901234567890', 'big amounts pass as written');
});

test('/pay refuses what it should, without calling Connect', async () => {
  reset();
  const bad = [
    { units: '0' }, { units: '007' }, { units: '1.5' }, { units: '-1' }, { units: '1e3' }, { units: 1 }, { units: '' }, { units: undefined },
    { asset: 'doge' }, { asset: 'not a mint at all, not even close' }, { asset: undefined },
    { asset: 'sol', units: '999999' },
    { handle: 'not a handle' }, { handle: '' }, { id: 'not-a-uuid' }, { id: undefined },
  ];
  for (const change of bad) {
    const r = await call(await badge('POST', '/pay', { ...PAYMENT, ...change }));
    assert.equal(r.data.state, 'failed', JSON.stringify(change));
  }
  assert.equal((await call(await badge('POST', '/pay', { ...PAYMENT, asset: 'sol', units: '999999' }))).data.text, 'The smallest SOL payment is 0.001 SOL.');
  assert.equal((await call(await badge('POST', '/pay', undefined, { over: {} }))).data.state, 'failed');
  assert.equal(connectCalls.length, 0);
});

test('/pay turns Connect\'s answers into what the badge should do next', async () => {
  const state = async (answer) => { reset(() => answer); return (await call(await badge('POST', '/pay', PAYMENT))).data; };
  assert.equal((await state({ status: 200, body: '{}' })).state, 'sent');
  assert.equal((await state({ status: 202, body: '{}' })).state, 'processing');
  assert.deepEqual(await state('timeout'), { state: 'unknown', text: "Connect didn't answer in time." });
  assert.deepEqual(await state({ status: 502, body: '<html>bad gateway</html>' }), { state: 'unknown', text: 'Connect answered 502' });
  assert.deepEqual(await state({ status: 400, body: '{"message":"Insufficient funds"}' }),
    { state: 'failed', text: 'Insufficient funds. Sending a token also takes about 0.002 SOL in fees.' });
  assert.deepEqual(await state({ status: 400, body: '{"message":["first","second"]}' }), { state: 'failed', text: 'first' });
  assert.equal((await state({ status: 401, body: '{"message":"API key missing"}' })).text, "Connect refused the worker's API key.");
});

test('/score fills in the X reputation from Ethos when Connect leaves it out', async () => {
  // @toly this afternoon: Connect has a fresh wallet scored 0 and no X reputation; Ethos has 1985.
  reset(() => ({ status: 200, body: '{"quidliScore":null,"categories":{"wallets":[{"code":"ethos_wallet_reputation","label":"Wallet reputation","source":"ethos","value":0,"reference":"untrusted"}]}}' }));
  ethosAnswer = (h) => (h === 'toly' ? { status: 200, body: '{"score":1985,"level":"reputable"}' } : { status: 404, body: '{}' });
  assert.deepEqual((await call(await badge('GET', '/score/toly'))).data, { score: null, lines: ['X reputation: 1985 (reputable)'] });
  // A real wallet score stays; Ethos's X score comes first.
  reset(() => ({ status: 200, body: '{"quidliScore":99,"categories":{"wallets":[{"code":"ethos_wallet_reputation","label":"Wallet reputation","value":1231,"reference":"neutral"}]}}' }));
  ethosAnswer = () => ({ status: 200, body: '{"score":1231,"level":"neutral"}' });
  assert.deepEqual((await call(await badge('GET', '/score/ahn_going'))).data.lines, ['X reputation: 1231 (neutral)', 'Wallet reputation: 1231 (neutral)']);
  // Connect already has it (@toly this morning): Connect's, not a second copy from Ethos.
  reset(() => ({ status: 200, body: '{"quidliScore":null,"categories":{"socials":[{"code":"ethos_twitter_reputation","label":"𝕏 reputation","value":1985,"reference":"reputable"}]}}' }));
  ethosAnswer = () => ({ status: 200, body: '{"score":1990,"level":"reputable"}' });
  assert.deepEqual((await call(await badge('GET', '/score/toly'))).data.lines, ['X reputation: 1985 (reputable)']);
  // Ethos down: Connect's answer alone.
  reset(() => ({ status: 200, body: '{"quidliScore":null,"categories":{}}' }));
  ethosAnswer = () => 'timeout';
  assert.deepEqual((await call(await badge('GET', '/score/nobody'))).data, { score: null, lines: [] });
  // Only a 0 wallet score: nothing to show.
  reset(() => ({ status: 200, body: '{"quidliScore":null,"categories":{"wallets":[{"code":"ethos_wallet_reputation","label":"Wallet reputation","value":0,"reference":"untrusted"}]}}' }));
  ethosAnswer = () => ({ status: 404, body: '{}' });
  assert.deepEqual((await call(await badge('GET', '/score/fresh'))).data, { score: null, lines: [] });
  ethosAnswer = () => ({ status: 404, body: '{}' });
});

test('scoreLine keeps to what the badge can draw', () => {
  assert.equal(scoreLine({ label: '𝕏 reputation', value: 1985, reference: 'reputable' }), 'X reputation: 1985 (reputable)');
  assert.equal(scoreLine({ label: 'Farcaster reputation', value: 0.96, reference: 0.96 }), 'Farcaster reputation: 0.96');
  assert.equal(scoreLine({ label: 'Lens ✨ score', value: '9606', reference: '9606' }), 'Lens score: 9606');
});

test('fromUnits and quickPicks', () => {
  assert.equal(fromUnits('1500000', 6), '1.5');
  assert.equal(fromUnits('1', 6), '0.000001');
  assert.equal(fromUnits('10000000', 6), '10');
  assert.equal(fromUnits('7', 0), '7');
  assert.deepEqual(quickPicks(890000n, 1n).map(String), ['50000', '100000', '200000', '500000']);
  assert.deepEqual(quickPicks(3n, 1n).map(String), ['1', '2']);
  assert.deepEqual(quickPicks(10n ** 30n, 1n).length, 4);
  assert.deepEqual(quickPicks(4n, 5n), []);
});
