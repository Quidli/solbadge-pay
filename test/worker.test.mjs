// Checks for the worker, with a stand-in badge server and a stand-in Connect.
// Run: node --test test/worker.test.mjs   (Node 20+, nothing to install)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker, { ASSETS, toUnits } from '../worker/worker.js';

const HOST = 'https://connect-pay.example.workers.dev';
const KEY = 'test-connect-key';
const ENV = { CONNECT_API_KEY: KEY, BADGE_IDS: '7K2Q9M, 4HX2PD' }; // APP_ID left out: the default is connect-pay
const SCORE = readFileSync(new URL('./data/score.json', import.meta.url), 'utf8');

// The badge server: an Ed25519 key pair, its public half served at /api/http/key.
const pair = await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
const rawKey = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
const b64 = (bytes) => btoa(String.fromCharCode(...bytes));

let connectCalls = [];
let connectAnswer = () => ({ status: 201, body: '{"status":"submitted"}' });
globalThis.fetch = async (url, init = {}) => {
  url = String(url);
  if (url === 'https://badge-api.solana.com/api/http/key') {
    return new Response(JSON.stringify({ id: 'k1', alg: 'Ed25519', key: b64(rawKey) }));
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
async function badge(method, path, body, { id = '7K2Q9M', app = 'connect-pay', time = Date.now(), over = {} } = {}) {
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
const PAYMENT = { id: '3f2b8c1e-9a4d-4e6f-8b7a-1c2d3e4f5a6b', handle: 'quidliprotocol', asset: 'usdc-sol', amount: '1' };
const reset = (answer) => { connectCalls = []; connectAnswer = answer ?? (() => ({ status: 201, body: '{}' })); };

test('requests without a valid badge signature are refused before Connect is touched', async () => {
  reset();
  assert.equal((await call(new Request(HOST + '/pay', { method: 'POST', body: JSON.stringify(PAYMENT) }))).status, 401);
  assert.equal((await call(await badge('POST', '/pay', PAYMENT, { app: 'someone-elses-app' }))).status, 401);
  assert.equal((await call(await badge('POST', '/pay', PAYMENT, { time: Date.now() - 120_000 }))).status, 401);
  assert.equal((await call(await badge('POST', '/pay', PAYMENT, { over: { body: JSON.stringify({ ...PAYMENT, amount: '5' }) } }))).status, 401);
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

test('/assets lists what the badge may send', async () => {
  const r = await call(await badge('GET', '/assets'));
  assert.equal(r.status, 200);
  assert.deepEqual(r.data.assets.map((a) => a.id), ASSETS.map((a) => a.id));
  assert.deepEqual(Object.keys(r.data.assets[0]).sort(), ['amounts', 'chain', 'dec', 'id', 'label', 'max']);
  // The Lua harness serves test/data/assets.json as the worker's list; keep it in step.
  const fixture = JSON.parse(readFileSync(new URL('./data/assets.json', import.meta.url), 'utf8'));
  assert.deepEqual(fixture, r.data, 'test/data/assets.json is out of date with ASSETS in worker.js');
});

test('/score trims Connect\'s answer for the badge', async () => {
  reset(() => ({ status: 200, body: SCORE }));
  const r = await call(await badge('GET', '/score/quidliprotocol'));
  assert.equal(r.data.score, 96);
  assert.equal(r.data.lines[0], 'Farcaster reputation: 0.96');
  assert.equal(connectCalls[0].path, '/scores/twitter/quidliprotocol');
  reset(() => ({ status: 200, body: '{"quidliScore":null,"categories":{}}' }));
  assert.deepEqual((await call(await badge('GET', '/score/nobody'))).data, { score: null, lines: [] });
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
    idempotencyKey: PAYMENT.id, chainId: 1399811149, tokenContract: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    recipients: [{ type: 'twitter', username: 'quidliprotocol' }], amountInWeiPerRecipient: '1000000',
  });
  reset();
  await call(await badge('POST', '/pay', { ...PAYMENT, asset: 'eth-base', amount: '0.0005' }));
  assert.equal(connectCalls[0].body.amountInWeiPerRecipient, '500000000000000');
  assert.equal(connectCalls[0].body.chainId, 8453);
  assert.ok(!('tokenContract' in connectCalls[0].body));
});

test('/pay refuses what it should, without calling Connect', async () => {
  reset();
  const bad = [
    { amount: '5.01' }, { amount: '0' }, { amount: '0.000' }, { amount: '1.' }, { amount: '.' }, { amount: '1,5' },
    { amount: '-1' }, { amount: '1e3' }, { amount: 1 }, { amount: '1.2345678' }, { amount: '' },
    { asset: 'doge' }, { handle: 'not a handle' }, { handle: '' }, { id: 'not-a-uuid' }, { id: undefined },
  ];
  for (const change of bad) {
    const r = await call(await badge('POST', '/pay', { ...PAYMENT, ...change }));
    assert.equal(r.data.state, 'failed', JSON.stringify(change));
  }
  assert.equal((await call(await badge('POST', '/pay', { ...PAYMENT, amount: '5.01' }))).data.text, 'Most per payment: 5 USDC');
  assert.equal((await call(await badge('POST', '/pay', undefined, { over: {} }))).data.state, 'failed');
  assert.equal(connectCalls.length, 0);
});

test('/pay turns Connect\'s answers into what the badge should do next', async () => {
  const state = async (answer) => { reset(() => answer); return (await call(await badge('POST', '/pay', PAYMENT))).data; };
  assert.equal((await state({ status: 200, body: '{}' })).state, 'sent');
  assert.equal((await state({ status: 202, body: '{}' })).state, 'processing');
  assert.deepEqual(await state('timeout'), { state: 'unknown', text: "Connect didn't answer in time." });
  assert.deepEqual(await state({ status: 502, body: '<html>bad gateway</html>' }), { state: 'unknown', text: 'Connect answered 502' });
  assert.deepEqual(await state({ status: 400, body: '{"message":"Insufficient funds"}' }), { state: 'failed', text: 'Insufficient funds' });
  assert.deepEqual(await state({ status: 400, body: '{"message":["first","second"]}' }), { state: 'failed', text: 'first' });
  assert.equal((await state({ status: 401, body: '{"message":"API key missing"}' })).text, "Connect refused the worker's API key.");
});

test('toUnits', () => {
  assert.equal(toUnits('1.5', 6), '1500000');
  assert.equal(toUnits('.5', 6), '500000');
  assert.equal(toUnits('0.000001', 6), '1');
  assert.equal(toUnits('007', 0), '7');
  assert.equal(toUnits('0.0000001', 6), null);
});
