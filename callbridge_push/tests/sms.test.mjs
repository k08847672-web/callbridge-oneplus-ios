import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { apnsRequest, createProvider, tokenHash } from '../server.mjs';
import { SMS_PAGE_SIZE, smsPayload } from '../sms.mjs';

const PAIR = '00000000-0000-4000-8000-000000000001';
const OTHER = '00000000-0000-4000-8000-000000000002';
const TOKEN = 'synthetic-sms-provider-token';
const OTHER_TOKEN = 'synthetic-other-pair-token';
const ALERT_TOKEN = 'cd'.repeat(32);
const VOIP_TOKEN = 'ab'.repeat(32);
const message = (extra = {}) => ({
  pairing_id: PAIR, message_id: 'a'.repeat(64), received_at_ms: 1_700_000_000_123,
  sender: 'synthetic-sender', body: 'synthetic verification text 572901', code: '572901', ...extra,
});
const registration = (extra = {}) => ({ pairing_id: PAIR, push_token: ALERT_TOKEN, environment: 'production', ...extra });

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'callbridge-sms-test-'));
  const config = { listen: '127.0.0.1', port: 0, mode: 'mock', state_file: join(directory, 'calls.json'),
    apns: { topic: 'example.callbridge.voip' },
    pairs: [{ pairing_id: PAIR, provider_token_hash: tokenHash(TOKEN) },
      { pairing_id: OTHER, provider_token_hash: tokenHash(OTHER_TOKEN) }] };
  let provider, base;
  async function start() {
    provider = await createProvider(config, options);
    base = `http://127.0.0.1:${(await provider.listen()).port}`;
  }
  await start();
  t.after(async () => { await provider.close(); await rm(directory, { recursive: true, force: true }); });
  return { config, smsFile: `${config.state_file}.sms.json`,
    async post(path, body, token = TOKEN) {
      const response = await fetch(base + path, { method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` }, body: JSON.stringify(body) });
      return { status: response.status, body: await response.json() };
    },
    async restart() { await provider.close(); await start(); },
  };
}

test('SMS survives restart, deduplicates persistently and syncs without an alert token', async (t) => {
  const sent = [];
  const f = await fixture(t, { pushSender: async (value) => sent.push(value) });
  assert.deepEqual(await f.post('/v1/sms', message()), { status: 200, body: { accepted: true, duplicate: false, seq: 1 } });
  assert.deepEqual(await f.post('/v1/sms', message({ body: 'changed duplicate' })),
    { status: 200, body: { accepted: true, duplicate: true, seq: 1 } });
  await f.restart();
  assert.equal((await f.post('/v1/sms', message())).body.duplicate, true);
  assert.deepEqual((await f.post('/v1/sms/sync', { pairing_id: PAIR, after_seq: 0 })).body,
    { messages: [{ ...message(), seq: 1 }], next_after_seq: 1, has_more: false });
  assert.equal((await f.post('/v1/sms', message({ message_id: 'b'.repeat(64), code: null }))).body.seq, 2);
  assert.equal(sent.length, 0, 'VoIP registration is not required to durably receive SMS');
  if (process.platform !== 'win32') assert.equal((await stat(f.smsFile)).mode & 0o777, 0o600);
});

test('SMS and VoIP registrations and stored states remain independent', async (t) => {
  const sent = [];
  const f = await fixture(t, { pushSender: async (value) => sent.push(value) });
  await f.post('/v1/register', registration({ push_token: VOIP_TOKEN }));
  const call = { pairing_id: PAIR, call_id: OTHER, revision: 1, state: 'ringing' };
  assert.equal((await f.post('/v1/calls', call)).status, 200);
  const originalCallState = await readFile(f.config.state_file, 'utf8');
  assert.equal((await f.post('/v1/sms', message())).status, 200);
  assert.equal(sent.length, 1, 'a VoIP token is never used for ordinary SMS alerts');
  assert.deepEqual(await f.post('/v1/sms/register', registration()), { status: 200, body: { accepted: true } });
  const next = message({ message_id: 'b'.repeat(64) });
  await f.post('/v1/sms', next);
  assert.equal(sent.length, 2);
  assert.equal(sent[0].registration.push_token, VOIP_TOKEN);
  assert.equal(sent[1].registration.push_token, ALERT_TOKEN);
  assert.equal(sent[1].pushType, 'alert');
  assert.deepEqual(sent[1].payload, smsPayload(next));
  await f.post('/v1/sms/sync', { pairing_id: PAIR, after_seq: 0 });
  assert.equal(await readFile(f.config.state_file, 'utf8'), originalCallState);
  const legacy = JSON.parse(originalCallState);
  assert.deepEqual(Object.keys(legacy).sort(), ['calls', 'registrations', 'version']);
  assert.equal(legacy.version, 1);
});

test('SMS is persisted before APNs, accepted on APNs failure and never pushed twice after restart', async (t) => {
  let attempts = 0, persistedAtSend;
  const f = await fixture(t, { pushSender: async () => {
    attempts++;
    persistedAtSend = JSON.parse(await readFile(f.smsFile, 'utf8'));
    throw new Error('synthetic private delivery failure');
  } });
  await f.post('/v1/sms/register', registration());
  assert.deepEqual(await f.post('/v1/sms', message()), { status: 200, body: { accepted: true, duplicate: false, seq: 1 } });
  assert.deepEqual(persistedAtSend.messages, [{ ...message(), seq: 1 }]);
  await f.restart();
  assert.equal((await f.post('/v1/sms', message())).body.duplicate, true);
  assert.equal(attempts, 1);
  assert.deepEqual((await f.post('/v1/sms/sync', { pairing_id: PAIR, after_seq: 0 })).body.messages,
    [{ ...message(), seq: 1 }]);
});

test('concurrent duplicates produce one seq and each pairing has its own inbox and sequence', async (t) => {
  const sent = [];
  const f = await fixture(t, { pushSender: async (value) => sent.push(value) });
  await f.post('/v1/sms/register', registration());
  const responses = await Promise.all([f.post('/v1/sms', message()), f.post('/v1/sms', message())]);
  assert.equal(responses.filter((entry) => entry.body.duplicate === false).length, 1);
  assert.equal(sent.length, 1);
  const otherMessage = message({ pairing_id: OTHER, body: 'other synthetic inbox', code: null });
  assert.equal((await f.post('/v1/sms', otherMessage, OTHER_TOKEN)).body.seq, 1);
  assert.equal((await f.post('/v1/sms/sync', { pairing_id: OTHER, after_seq: 0 })).status, 401);
  const mine = (await f.post('/v1/sms/sync', { pairing_id: PAIR, after_seq: 0 })).body.messages;
  const theirs = (await f.post('/v1/sms/sync', { pairing_id: OTHER, after_seq: 0 }, OTHER_TOKEN)).body.messages;
  assert.deepEqual(mine, [{ ...message(), seq: 1 }]);
  assert.deepEqual(theirs, [{ ...otherMessage, seq: 1 }]);
});

test('sync pagination preserves all messages and advances only the requesting pairing cursor', async (t) => {
  t.mock.method(console, 'log', () => {});
  const f = await fixture(t);
  for (let index = 1; index <= SMS_PAGE_SIZE + 1; index++) {
    assert.equal((await f.post('/v1/sms', message({ message_id: index.toString(16).padStart(64, '0'), code: null }))).body.seq, index);
  }
  const first = (await f.post('/v1/sms/sync', { pairing_id: PAIR, after_seq: 0 })).body;
  assert.equal(first.messages.length, SMS_PAGE_SIZE);
  assert.equal(first.next_after_seq, SMS_PAGE_SIZE);
  assert.equal(first.has_more, true);
  await f.restart();
  const second = (await f.post('/v1/sms/sync', { pairing_id: PAIR, after_seq: first.next_after_seq })).body;
  assert.deepEqual(second.messages.map((item) => item.seq), [SMS_PAGE_SIZE + 1]);
  assert.equal(second.next_after_seq, SMS_PAGE_SIZE + 1);
  assert.equal(second.has_more, false);
  assert.equal(JSON.parse(await readFile(f.smsFile, 'utf8')).messages.length, SMS_PAGE_SIZE + 1);
});

test('SMS validates fields and routes without logging sender, body, code or credentials', async (t) => {
  const logs = [];
  t.mock.method(console, 'log', (line) => logs.push(JSON.parse(line)));
  const f = await fixture(t);
  assert.equal((await f.post('/v1/sms', message(), 'wrong-token')).status, 401);
  for (const invalid of [{ message_id: 'not-a-hash' }, { received_at_ms: -1 }, { body: {} }, { sender: null }, { code: '57x901' }]) {
    assert.equal((await f.post('/v1/sms', message(invalid))).status, 400);
  }
  assert.equal((await f.post('/v1/sms/register', registration({ push_token: 'not-hex' }))).status, 400);
  assert.equal((await f.post('/v1/sms/sync', { pairing_id: PAIR, after_seq: -1 })).status, 400);
  await f.post('/v1/sms/register', registration());
  await f.post('/v1/sms', message());
  await f.post('/v1/sms/sync', { pairing_id: PAIR, after_seq: 0 });
  for (const secret of [message().sender, message().body, message().code, TOKEN, ALERT_TOKEN]) {
    assert.equal(JSON.stringify(logs).includes(secret), false);
  }
  assert.ok(logs.every((entry) => Object.keys(entry).sort().join(',') === 'route,stage,status'));
});

test('ordinary alert request has minimal privacy payload, independent topic and shared JWT', () => {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const apns = { key_id: 'FIXTUREKEY', team_id: 'FIXTURETEAM', topic: 'example.callbridge.voip', privateKey };
  const payload = smsPayload(message());
  assert.deepEqual(payload, { aps: { alert: { title: '收到验证码短信', body: '打开应用查看' }, sound: 'default' },
    kind: 'verification_sms', pairing_id: PAIR, message_id: message().message_id });
  const alert = apnsRequest({ apns, registration: registration(), payload, pushType: 'alert' });
  assert.equal(alert.headers['apns-topic'], 'example.callbridge');
  assert.equal(alert.headers['apns-push-type'], 'alert');
  assert.equal('apns-expiration' in alert.headers, false);
  const voip = apnsRequest({ apns, registration: registration({ push_token: VOIP_TOKEN }), payload: {} });
  assert.equal(voip.headers['apns-topic'], 'example.callbridge.voip');
  assert.equal(voip.headers['apns-expiration'], '0');
  assert.equal(alert.headers.authorization, voip.headers.authorization);
  assert.equal(apnsRequest({ apns: { ...apns, alert_topic: 'other.explicit.bundle' },
    registration: registration(), payload, pushType: 'alert' }).headers['apns-topic'], 'other.explicit.bundle');
  for (const secret of [message().sender, message().body, message().code]) assert.equal(alert.body.includes(secret), false);
});

test('slow ordinary APNs delivery does not block the existing call event queue', async (t) => {
  let begin, release;
  const begun = new Promise((resolve) => { begin = resolve; });
  const held = new Promise((resolve) => { release = resolve; });
  t.after(() => release());
  const f = await fixture(t, { pushSender: async (value) => { if (value.pushType === 'alert') { begin(); await held; } } });
  await f.post('/v1/sms/register', registration());
  const pending = f.post('/v1/sms', message());
  await begun;
  await f.post('/v1/register', registration({ push_token: VOIP_TOKEN }));
  assert.equal((await f.post('/v1/calls', { pairing_id: PAIR, call_id: OTHER, revision: 1, state: 'ringing' })).status, 200);
  release();
  assert.equal((await pending).body.accepted, true);
});
