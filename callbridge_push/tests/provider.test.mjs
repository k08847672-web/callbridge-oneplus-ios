import test from 'node:test';
import assert from 'node:assert/strict';
import http2 from 'node:http2';
import { EventEmitter } from 'node:events';
import { generateKeyPairSync, verify } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { apnsRequest, createApnsJWT, createProvider, loadConfig, sendApnsPush, tokenHash, voipPayload } from '../server.mjs';

const PAIR = '00000000-0000-4000-8000-000000000001';
const CALL = '00000000-0000-4000-8000-000000000002';
const CALL_TWO = 'abcdef00-0000-4000-8000-000000000003';
const TOKEN = 'synthetic-provider-bearer-token';
const PUSH_TOKEN = 'ab'.repeat(32);

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'callbridge-provider-test-'));
  const config = {
    listen: '127.0.0.1', port: 0, mode: 'mock', state_file: join(directory, 'state.json'),
    pairs: [{ pairing_id: PAIR, provider_token_hash: tokenHash(TOKEN) }],
  };
  const provider = await createProvider(config, options);
  const address = await provider.listen();
  t.after(async () => { await provider.close(); await rm(directory, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${address.port}`;
  async function post(path, body, token = TOKEN) {
    const response = await fetch(base + path, {
      method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() };
  }
  return { directory, config, provider, post };
}

function registration(extra = {}) {
  return { pairing_id: PAIR, push_token: PUSH_TOKEN, environment: 'sandbox', ...extra };
}

function event(extra = {}) {
  return { pairing_id: PAIR, call_id: CALL, revision: 1, state: 'ringing', ...extra };
}

test('HTTP API authenticates the independent token and validates registration', async (t) => {
  const f = await fixture(t);
  assert.equal((await f.post('/v1/register', registration(), 'wrong-fixture-token')).status, 401);
  assert.equal((await f.post('/v1/register', registration({ pairing_id: CALL }))).status, 401);
  assert.equal((await f.post('/v1/register', registration({ environment: 'development' }))).status, 400);
  assert.equal((await f.post('/v1/register', registration({ push_token: '../invalid' }))).status, 400);
  assert.deepEqual(await f.post('/v1/register', registration()), { status: 200, body: { accepted: true } });
  assert.deepEqual(await f.post('/v1/register', registration({ environment: 'production' })),
    { status: 200, body: { accepted: true } });
  const state = await readFile(f.config.state_file, 'utf8');
  assert.equal(state.includes(TOKEN), false, 'the raw provider token is never persisted');
  if (process.platform !== 'win32') assert.equal((await stat(f.config.state_file)).mode & 0o777, 0o600);
});

test('completed request diagnostics normalize routes and expose no request material', async (t) => {
  const f = await fixture(t);
  const logs = [];
  t.mock.method(console, 'log', (line) => logs.push(JSON.parse(line)));
  const base = `http://127.0.0.1:${f.provider.server.address().port}`;
  const privatePath = '/private-fixture-path?token=private-fixture-query';
  assert.equal((await fetch(base + privatePath)).status, 404);
  assert.equal((await fetch(base + '/v1/register')).status, 405);
  assert.equal((await fetch(base + '/v1/register', { method: 'POST', body: 'private-fixture-invalid-json' })).status, 400);
  assert.equal((await f.post('/v1/register', registration(), 'private-fixture-bearer')).status, 401);
  assert.equal((await f.post('/v1/register', registration({ environment: 'invalid' }))).status, 400);
  assert.equal((await f.post('/v1/calls', event())).status, 409);
  await mkdir(f.config.state_file);
  assert.equal((await f.post('/v1/register', registration())).status, 500);
  assert.deepEqual(logs, [
    { stage: 'provider_request_result', route: 'other', status: 404 },
    { stage: 'provider_request_result', route: '/v1/register', status: 405 },
    { stage: 'provider_request_result', route: '/v1/register', status: 400 },
    { stage: 'provider_request_result', route: '/v1/register', status: 401 },
    { stage: 'provider_request_result', route: '/v1/register', status: 400 },
    { stage: 'provider_request_result', route: '/v1/calls', status: 409 },
    { stage: 'provider_request_result', route: '/v1/register', status: 500 },
  ]);
  for (const privateValue of [privatePath, TOKEN, PUSH_TOKEN, PAIR, CALL, 'private-fixture-bearer']) {
    assert.equal(JSON.stringify(logs).includes(privateValue), false);
  }
  assert.equal(f.provider.server.listening, true);
});

test('one ringing push, repeated revisions and ended tombstone use the same API', async (t) => {
  const deliveries = [];
  const f = await fixture(t, { pushSender: async (message) => deliveries.push(message) });
  await f.post('/v1/register', registration());
  assert.deepEqual((await f.post('/v1/calls', event())).body, { accepted: true, duplicate: false, state: 'ringing' });
  assert.deepEqual((await f.post('/v1/calls', event())).body, { accepted: true, duplicate: true, state: 'ringing' });
  assert.equal((await f.post('/v1/calls', event({ revision: 2 }))).body.duplicate, true);
  assert.equal(deliveries.length, 1);
  assert.deepEqual(deliveries[0].payload, { aps: {}, pairing_id: PAIR, call_id: CALL, revision: 1, state: 'ringing' });
  assert.deepEqual(Object.keys(deliveries[0].payload).sort(), ['aps', 'call_id', 'pairing_id', 'revision', 'state']);
  assert.deepEqual((await f.post('/v1/calls', event({ revision: 3, state: 'ended' }))).body,
    { accepted: true, duplicate: false, state: 'ended' });
  assert.deepEqual((await f.post('/v1/calls', event({ revision: 4 }))).body,
    { accepted: true, duplicate: true, state: 'ended' });
  assert.equal(deliveries.length, 1, 'ended never pushes, and a terminal Call never rings again');
});

test('ended before ringing stays terminal, and a new Call can independently ring', async (t) => {
  const deliveries = [];
  const f = await fixture(t, { pushSender: async (message) => deliveries.push(message) });
  assert.equal((await f.post('/v1/calls', event())).status, 409);
  assert.equal((await f.post('/v1/calls', event({ revision: 2, state: 'ended' }))).status, 200);
  await f.post('/v1/register', registration());
  assert.equal((await f.post('/v1/calls', event())).body.state, 'ended');
  assert.equal(deliveries.length, 0);
  assert.equal((await f.post('/v1/calls', event({ call_id: CALL_TWO }))).status, 200);
  assert.equal(deliveries.length, 1);
  assert.equal((await f.post('/v1/calls', event({ call_id: CALL_TWO.toUpperCase() }))).status, 400);
  assert.equal((await f.post('/v1/calls', event({ revision: 1.5 }))).status, 400);
});

test('publication is persisted before dispatch and is not replayed after uncertain failure/restart', async (t) => {
  let attempts = 0;
  const f = await fixture(t, { pushSender: async () => {
    attempts++;
    const persisted = JSON.parse(await readFile(f.config.state_file, 'utf8'));
    assert.equal(persisted.calls[0].notification_attempted, true);
    throw new Error('synthetic transport failure');
  } });
  await f.post('/v1/register', registration());
  assert.deepEqual(await f.post('/v1/calls', event()), { status: 502, body: { error: 'push_attempt_failed' } });
  assert.equal((await f.post('/v1/calls', event())).body.duplicate, true);
  assert.equal(attempts, 1);
  await f.provider.close();
  const restarted = await createProvider(f.config, { pushSender: async () => { attempts++; } });
  const address = await restarted.listen();
  t.after(() => restarted.close());
  const response = await fetch(`http://127.0.0.1:${address.port}/v1/calls`, {
    method: 'POST', headers: { authorization: `Bearer ${TOKEN}` }, body: JSON.stringify(event()),
  });
  assert.deepEqual(await response.json(), { accepted: true, duplicate: true, state: 'ringing' });
  assert.equal(attempts, 1);
});

test('concurrent duplicate event requests produce one publication', async (t) => {
  let attempts = 0;
  const f = await fixture(t, { pushSender: async () => { attempts++; } });
  await f.post('/v1/register', registration());
  const responses = await Promise.all([f.post('/v1/calls', event()), f.post('/v1/calls', event())]);
  assert.equal(responses.filter((r) => r.body.duplicate === false).length, 1);
  assert.equal(attempts, 1);
});

test('APNs JWT and request assembly use ES256, correct environment, topic and minimal payload', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const apns = { key_id: 'FIXTUREKEY', team_id: 'FIXTURETEAM', topic: 'example.callbridge.voip', privateKey };
  const now = 1_700_000_000_000;
  const jwt = createApnsJWT(apns, now);
  const [header, claims, signature] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: 'FIXTUREKEY' });
  assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url')), { iss: 'FIXTURETEAM', iat: 1_700_000_000 });
  assert.equal(Buffer.from(signature, 'base64url').length, 64);
  assert.equal(verify('sha256', Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')), true);
  const payload = voipPayload(event());
  const request = apnsRequest({ apns, registration: registration(), payload }, now);
  assert.equal(request.origin, 'https://api.sandbox.push.apple.com');
  assert.equal(request.headers[':path'], `/3/device/${PUSH_TOKEN}`);
  assert.equal(request.headers['apns-topic'], 'example.callbridge.voip');
  assert.equal(request.headers['apns-push-type'], 'voip');
  assert.equal(request.headers['apns-priority'], '10');
  assert.equal(request.headers['apns-expiration'], '0');
  assert.equal(request.headers.authorization.startsWith('bearer '), true);
  assert.deepEqual(JSON.parse(request.body), payload);
  assert.equal(apnsRequest({ apns, registration: registration(), payload }, now + 60_000).headers.authorization,
    request.headers.authorization, 'provider JWT is reused instead of refreshed for each call');
  const refreshed = apnsRequest({ apns, registration: registration(), payload }, now + 51 * 60_000);
  const refreshedClaims = refreshed.headers.authorization.slice('bearer '.length).split('.')[1];
  assert.equal(JSON.parse(Buffer.from(refreshedClaims, 'base64url')).iat, Math.floor((now + 51 * 60_000) / 1000));
  assert.equal(apnsRequest({ apns, registration: registration({ environment: 'production' }), payload }, now).origin,
    'https://api.push.apple.com');
});

test('real HTTP/2 sender writes the assembled request to a local synthetic APNs peer', async (t) => {
  const logs = [];
  t.mock.method(console, 'log', (line) => logs.push(JSON.parse(line)));
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const peer = http2.createServer();
  const received = [];
  peer.on('stream', (stream, headers) => {
    let body = '';
    stream.on('data', (chunk) => { body += chunk; });
    stream.on('end', () => {
      received.push({ headers, payload: JSON.parse(body) });
      stream.respond({ ':status': 200 }); stream.end();
    });
  });
  await new Promise((accept) => peer.listen(0, '127.0.0.1', accept));
  t.after(() => new Promise((accept) => peer.close(accept)));
  const address = peer.address();
  let selectedOrigin;
  await sendApnsPush({
    apns: { key_id: 'FIXTUREKEY', team_id: 'FIXTURETEAM', topic: 'example.callbridge.voip', privateKey },
    registration: registration({ environment: 'production' }), payload: voipPayload(event()),
  }, { connect: (origin) => {
    selectedOrigin = origin;
    return http2.connect(`http://127.0.0.1:${address.port}`);
  } });
  assert.equal(selectedOrigin, 'https://api.push.apple.com');
  assert.equal(received.length, 1);
  assert.equal(received[0].headers['apns-push-type'], 'voip');
  assert.deepEqual(received[0].payload, voipPayload(event()));
  assert.deepEqual(logs, [{ stage: 'apns_result', http_status: 200, reason: null }]);
});

test('APNs rejection diagnostics retain the known reason and discard private or oversized bodies', async (t) => {
  const logs = [];
  t.mock.method(console, 'log', (line) => logs.push(JSON.parse(line)));
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const responses = [
    JSON.stringify({ reason: 'TopicDisallowed', token: PUSH_TOKEN, pairing_id: PAIR, call_id: CALL }),
    JSON.stringify({ reason: 'private-fixture-reason', token: PUSH_TOKEN }),
    'private-fixture-invalid-json',
    JSON.stringify({ reason: 'TopicDisallowed', private: 'x'.repeat(4096) }),
  ];
  const peer = http2.createServer();
  peer.on('stream', (stream) => {
    stream.on('data', () => {});
    stream.on('end', () => {
      const response = responses.shift();
      stream.respond({ ':status': 400 });
      stream.write(response.slice(0, 5)); stream.end(response.slice(5));
    });
  });
  await new Promise((accept) => peer.listen(0, '127.0.0.1', accept));
  t.after(() => new Promise((accept) => peer.close(accept)));
  const message = {
    apns: { key_id: 'FIXTUREKEY', team_id: 'FIXTURETEAM', topic: 'example.callbridge.voip', privateKey },
    registration: registration({ environment: 'production' }), payload: voipPayload(event()),
  };
  for (let attempt = 0; attempt < 4; attempt++) {
    await assert.rejects(sendApnsPush(message, {
      connect: () => http2.connect(`http://127.0.0.1:${peer.address().port}`),
    }), /APNs rejected request \(400\)/);
  }
  assert.deepEqual(logs, [
    { stage: 'apns_result', http_status: 400, reason: 'TopicDisallowed' },
    { stage: 'apns_result', http_status: 400, reason: null },
    { stage: 'apns_result', http_status: 400, reason: null },
    { stage: 'apns_result', http_status: 400, reason: null },
  ]);
  for (const privateValue of [TOKEN, PUSH_TOKEN, PAIR, CALL, 'private-fixture', 'FIXTUREKEY', 'FIXTURETEAM']) {
    assert.equal(JSON.stringify(logs).includes(privateValue), false);
  }
});

test('APNs transport diagnostics keep only a standard error class', async (t) => {
  const logs = [];
  t.mock.method(console, 'log', (line) => logs.push(JSON.parse(line)));
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const message = {
    apns: { key_id: 'FIXTUREKEY', team_id: 'FIXTURETEAM', topic: 'example.callbridge.voip', privateKey },
    registration: registration(), payload: voipPayload(event()),
  };
  await assert.rejects(sendApnsPush(message, {
    connect: () => { throw new TypeError('private-fixture-connect-message'); },
  }), TypeError);
  for (const failure of ['session', 'stream']) {
    const session = new EventEmitter();
    session.destroy = () => {};
    session.request = () => {
      const stream = new EventEmitter();
      stream.end = () => queueMicrotask(() => {
        const error = new RangeError('private-fixture-transport-message');
        if (failure === 'stream') error.name = 'private-fixture-error-name';
        (failure === 'session' ? session : stream).emit('error', error);
      });
      return stream;
    };
    await assert.rejects(sendApnsPush(message, { connect: () => session }), /APNs .* failed/);
  }
  assert.deepEqual(logs, [
    { stage: 'apns_result', http_status: 0, reason: null, transport_error_class: 'TypeError' },
    { stage: 'apns_result', http_status: 0, reason: null, transport_error_class: 'RangeError' },
    { stage: 'apns_result', http_status: 0, reason: null, transport_error_class: 'Error' },
  ]);
  assert.equal(JSON.stringify(logs).includes('private-fixture'), false);
});

test('private configuration resolves relative paths and APNs startup accepts a generated P-256 key', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'callbridge-provider-config-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  await writeFile(join(directory, 'fixture.p8'), privateKey.export({ format: 'pem', type: 'pkcs8' }), { mode: 0o600 });
  const configFile = join(directory, 'private.json');
  await writeFile(configFile, JSON.stringify({
    listen: '127.0.0.1', port: 0, mode: 'apns', state_file: 'state.json',
    pairs: [{ pairing_id: PAIR, provider_token_hash: tokenHash(TOKEN) }],
    apns: { key_id: 'FIXTUREKEY', team_id: 'FIXTURETEAM', topic: 'example.callbridge.voip', private_key_path: 'fixture.p8' },
  }), { mode: 0o600 });
  const config = await loadConfig(configFile);
  assert.equal(config.state_file, join(directory, 'state.json'));
  assert.equal(config.apns.private_key_path, join(directory, 'fixture.p8'));
  const provider = await createProvider(config);
  t.after(() => provider.close());
  await provider.listen();
  const wrongKey = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey;
  await writeFile(join(directory, 'wrong.p8'), wrongKey.export({ format: 'pem', type: 'pkcs8' }), { mode: 0o600 });
  await assert.rejects(createProvider({ ...config, apns: { ...config.apns, private_key_path: join(directory, 'wrong.p8') } }), /P-256/);
});
