#!/usr/bin/env node
import http from 'node:http';
import http2 from 'node:http2';
import { createHash, createPrivateKey, randomBytes, sign, timingSafeEqual } from 'node:crypto';
import { chmod, mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createSmsInbox, smsPayload, smsValid } from './sms.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HASH = /^[0-9a-f]{64}$/;
const ENVIRONMENTS = new Set(['sandbox', 'production']);
const APNS_JWT_CACHE = new WeakMap();
// Only Apple-defined reason values may leave the response parser. Never log response bodies.
const APNS_REASONS = new Set([
  'BadCollapseId', 'BadDeviceToken', 'BadExpirationDate', 'BadMessageId', 'BadPriority', 'BadTopic',
  'DeviceTokenNotForTopic', 'DuplicateHeaders', 'IdleTimeout', 'InvalidPushType', 'MissingDeviceToken',
  'MissingTopic', 'PayloadEmpty', 'TopicDisallowed', 'BadCertificate', 'BadCertificateEnvironment',
  'ExpiredProviderToken', 'Forbidden', 'InvalidProviderToken', 'MissingProviderToken', 'UnrelatedKeyIdInToken',
  'BadEnvironmentKeyIdInToken', 'BadPath', 'MethodNotAllowed', 'ExpiredToken', 'Unregistered',
  'PayloadTooLarge', 'TooManyProviderTokenUpdates', 'TooManyRequests', 'InternalServerError',
  'ServiceUnavailable', 'Shutdown',
]);
const ERROR_CLASSES = new Set(['Error', 'TypeError', 'RangeError', 'AggregateError', 'SyntaxError',
  'ReferenceError', 'URIError', 'EvalError']);

function diagnostic(stage, fields) {
  console.log(JSON.stringify({ stage, ...fields }));
}

function apnsDiagnostic(status, chunks = [], length = 0, transportError = null) {
  let reason = null;
  if (status !== 200 && length <= 4096) {
    try {
      const value = JSON.parse(Buffer.concat(chunks).toString('utf8')).reason;
      if (APNS_REASONS.has(value)) reason = value;
    } catch { /* Missing or unrecognized response bodies stay private. */ }
  }
  diagnostic('apns_result', {
    http_status: status, reason,
    ...(transportError === null ? {} : {
      transport_error_class: ERROR_CLASSES.has(transportError?.name) ? transportError.name : 'Error',
    }),
  });
}

export function tokenHash(token) {
  return createHash('sha256').update(token).digest('hex');
}

export async function loadConfig(filename) {
  const file = resolve(filename);
  const config = JSON.parse(await readFile(file, 'utf8'));
  for (const field of ['state_file', 'sms_state_file']) {
    if (typeof config[field] === 'string' && !isAbsolute(config[field])) {
      config[field] = resolve(dirname(file), config[field]);
    }
  }
  if (typeof config.apns?.private_key_path === 'string' && !isAbsolute(config.apns.private_key_path)) {
    config.apns.private_key_path = resolve(dirname(file), config.apns.private_key_path);
  }
  return config;
}

export function voipPayload(event) {
  const payload = {
    aps: {},
    pairing_id: event.pairing_id,
    call_id: event.call_id,
    revision: event.revision,
    state: 'ringing',
  };
  for (const field of ['caller_name', 'caller_number']) {
    if (typeof event[field] !== 'string') continue;
    const value = event[field].replace(/[\u0000-\u001f\u007f]/g, '').trim();
    if (value) payload[field] = value;
  }
  return payload;
}

export function createApnsJWT(apns, now = Date.now()) {
  const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: apns.key_id })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({ iss: apns.team_id, iat: Math.floor(now / 1000) })).toString('base64url');
  const input = `${header}.${claims}`;
  const signature = sign('sha256', Buffer.from(input), {
    key: apns.privateKey,
    dsaEncoding: 'ieee-p1363',
  }).toString('base64url');
  return `${input}.${signature}`;
}

function cachedApnsJWT(apns, now) {
  const cached = APNS_JWT_CACHE.get(apns);
  if (cached && now >= cached.issuedAt && now - cached.issuedAt < 50 * 60 * 1000) return cached.token;
  const token = createApnsJWT(apns, now);
  APNS_JWT_CACHE.set(apns, { issuedAt: now, token });
  return token;
}

export function apnsRequest({ apns, registration, payload, pushType = 'voip' }, now = Date.now()) {
  return {
    origin: registration.environment === 'sandbox'
      ? 'https://api.sandbox.push.apple.com'
      : 'https://api.push.apple.com',
    headers: {
      ':method': 'POST',
      ':path': `/3/device/${registration.push_token}`,
      authorization: `bearer ${cachedApnsJWT(apns, now)}`,
      'apns-topic': pushType === 'alert' ? (apns.alert_topic ?? apns.topic.replace(/\.voip$/, '')) : apns.topic,
      'apns-push-type': pushType,
      'apns-priority': '10',
      // Transport expiry only; it does not impose a lifetime on the Android Call.
      ...(pushType === 'voip' ? { 'apns-expiration': '0' } : {}),
      'content-type': 'application/json',
    },
    body: JSON.stringify(payload),
  };
}

export async function sendApnsPush(message, { connect = http2.connect, now = Date.now() } = {}) {
  const request = apnsRequest(message, now);
  let session;
  try { session = connect(request.origin); }
  catch (error) { apnsDiagnostic(0, [], 0, error); throw error; }
  try {
    await new Promise((accept, reject) => {
      let settled = false;
      let status = 0;
      let stream;
      const responseChunks = [];
      let responseLength = 0;
      const finish = (error, transportError = null) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        apnsDiagnostic(status, responseChunks, responseLength, transportError);
        if (error) reject(error); else accept();
      };
      const timer = setTimeout(() => {
        stream?.close(http2.constants.NGHTTP2_CANCEL);
        const error = new Error('APNs request timed out');
        finish(error, error);
      }, 10_000);
      timer.unref();
      session.once('error', (error) => finish(new Error('APNs connection failed'), error));
      try {
        stream = session.request(request.headers);
        stream.on('response', (headers) => { status = Number(headers[':status']); });
        stream.on('data', (chunk) => {
          responseLength += chunk.length;
          if (responseLength <= 4096) responseChunks.push(Buffer.from(chunk));
        });
        stream.once('error', (error) => finish(new Error('APNs request failed'), error));
        stream.once('end', () => finish(status === 200 ? undefined : new Error(`APNs rejected request (${status})`)));
        stream.end(request.body);
      } catch (error) {
        finish(new Error('APNs request failed'), error);
      }
    });
  } finally {
    session.destroy();
  }
}

function reply(response, status, value) {
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify(value));
}

async function bodyJSON(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > 16_384) throw new Error('invalid_body');
    chunks.push(chunk);
  }
  const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!body || Array.isArray(body) || typeof body !== 'object') throw new Error('invalid_body');
  return body;
}

function registrationValid(value) {
  return UUID.test(value?.pairing_id ?? '')
    && typeof value.push_token === 'string'
    && /^[0-9a-f]+$/i.test(value.push_token)
    && value.push_token.length % 2 === 0
    && ENVIRONMENTS.has(value.environment);
}

function callValid(value) {
  return UUID.test(value?.pairing_id ?? '') && UUID.test(value.call_id ?? '')
    && Number.isSafeInteger(value.revision) && value.revision > 0
    && (value.state === 'ringing' || value.state === 'ended');
}

function callKey(value) {
  return JSON.stringify([value.pairing_id, value.call_id]);
}

async function readState(filename) {
  try {
    const state = JSON.parse(await readFile(filename, 'utf8'));
    if (state.version !== 1 || !Array.isArray(state.registrations) || !Array.isArray(state.calls)
      || !state.registrations.every(registrationValid)
      || !state.calls.every((value) => callValid(value) && typeof value.notification_attempted === 'boolean')) {
      throw new Error('invalid_state');
    }
    return state;
  } catch (error) {
    if (error.code === 'ENOENT') return { version: 1, registrations: [], calls: [] };
    throw new Error('Cannot load provider state');
  }
}

async function writeState(filename, registrations, calls) {
  await mkdir(dirname(filename), { recursive: true, mode: 0o700 });
  const temporary = `${filename}.${randomBytes(8).toString('hex')}.tmp`;
  try {
    const state = { version: 1, registrations: [...registrations.values()], calls: [...calls.values()] };
    await writeFile(temporary, JSON.stringify(state), { encoding: 'utf8', mode: 0o600, flag: 'wx' });
    await rename(temporary, filename);
    await chmod(filename, 0o600);
  } finally {
    await unlink(temporary).catch((error) => { if (error.code !== 'ENOENT') throw error; });
  }
}

async function prepareConfig(raw) {
  if (!raw || !['mock', 'apns'].includes(raw.mode) || typeof raw.listen !== 'string' || !raw.listen
    || !Number.isInteger(raw.port) || raw.port < 0 || raw.port > 65535
    || typeof raw.state_file !== 'string' || !raw.state_file
    || !Array.isArray(raw.pairs) || !raw.pairs.length) throw new Error('Invalid provider configuration');
  const pairs = new Map();
  for (const pair of raw.pairs) {
    if (!UUID.test(pair.pairing_id ?? '') || !HASH.test(pair.provider_token_hash ?? '') || pairs.has(pair.pairing_id)) {
      throw new Error('Invalid configured pairing');
    }
    pairs.set(pair.pairing_id, Buffer.from(pair.provider_token_hash, 'hex'));
  }
  const apns = { ...raw.apns };
  const smsStateFile = raw.sms_state_file ?? `${raw.state_file}.sms.json`;
  if (typeof smsStateFile !== 'string' || !smsStateFile || resolve(smsStateFile) === resolve(raw.state_file)) {
    throw new Error('SMS state must use a separate file');
  }
  if (raw.mode === 'apns') {
    if (![apns.team_id, apns.key_id, apns.topic, apns.private_key_path].every((value) => typeof value === 'string' && value)
      || !apns.topic.endsWith('.voip')) throw new Error('Invalid APNs configuration');
    apns.alert_topic ??= apns.topic.slice(0, -'.voip'.length);
    if (typeof apns.alert_topic !== 'string' || !apns.alert_topic) throw new Error('Invalid APNs alert topic');
    apns.privateKey = createPrivateKey(await readFile(apns.private_key_path));
    if (apns.privateKey.asymmetricKeyType !== 'ec' || apns.privateKey.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
      throw new Error('APNs signing key must be P-256');
    }
  }
  return { ...raw, sms_state_file: smsStateFile, pairs, apns };
}

export async function createProvider(rawConfig, { pushSender } = {}) {
  const config = await prepareConfig(rawConfig);
  const stored = await readState(config.state_file);
  const smsInbox = await createSmsInbox(config.sms_state_file);
  let registrations = new Map(stored.registrations.map((entry) => [entry.pairing_id, entry]));
  let calls = new Map(stored.calls.map((entry) => [callKey(entry), entry]));
  let queue = Promise.resolve();
  const sendPush = pushSender ?? (config.mode === 'apns' ? sendApnsPush : async () => {});

  const server = http.createServer(async (request, response) => {
    const routes = ['/v1/register', '/v1/calls', '/v1/sms/register', '/v1/sms', '/v1/sms/sync'];
    const route = routes.includes(request.url) ? request.url : 'other';
    response.once('finish', () => diagnostic('provider_request_result', { route, status: response.statusCode }));
    if (route === 'other') return reply(response, 404, { error: 'not_found' });
    if (request.method !== 'POST') return reply(response, 405, { error: 'method_not_allowed' });
    let body;
    try { body = await bodyJSON(request); } catch { return reply(response, 400, { error: 'invalid_json' }); }
    const expected = config.pairs.get(body.pairing_id);
    const bearer = /^Bearer ([^\s]+)$/.exec(request.headers.authorization ?? '');
    if (!expected || !bearer || !timingSafeEqual(expected, Buffer.from(tokenHash(bearer[1]), 'hex'))) {
      return reply(response, 401, { error: 'unauthorized' });
    }
    if (route.startsWith('/v1/sms')) {
      try {
        if (route === '/v1/sms/register') {
          if (!registrationValid(body)) return reply(response, 400, { error: 'invalid_registration' });
          await smsInbox.register(body);
          return reply(response, 200, { accepted: true });
        }
        if (route === '/v1/sms/sync') {
          if (!Number.isSafeInteger(body.after_seq) || body.after_seq < 0) {
            return reply(response, 400, { error: 'invalid_cursor' });
          }
          return reply(response, 200, await smsInbox.sync(body.pairing_id, body.after_seq));
        }
        if (!smsValid(body)) return reply(response, 400, { error: 'invalid_sms' });
        const saved = await smsInbox.save(body);
        if (!saved.duplicate && saved.registration) {
          try {
            await sendPush({ apns: config.apns, registration: saved.registration,
              payload: smsPayload(saved.message), pushType: 'alert' });
          } catch { /* The inbox is durable; APNs failure must not undo acceptance. */ }
        }
        return reply(response, 200, { accepted: true, duplicate: saved.duplicate, seq: saved.message.seq });
      } catch { return reply(response, 500, { error: 'sms_state_update_failed' }); }
    }
    const execute = async () => {
      if (request.url === '/v1/register') {
        if (!registrationValid(body)) return reply(response, 400, { error: 'invalid_registration' });
        const next = new Map(registrations);
        next.set(body.pairing_id, {
          pairing_id: body.pairing_id,
          push_token: body.push_token.toLowerCase(),
          environment: body.environment,
        });
        await writeState(config.state_file, next, calls);
        registrations = next;
        return reply(response, 200, { accepted: true });
      }
      if (!callValid(body)) return reply(response, 400, { error: 'invalid_call' });
      const key = callKey(body);
      const previous = calls.get(key);
      if (previous && (previous.state === 'ended' || body.revision <= previous.revision)) {
        return reply(response, 200, { accepted: true, duplicate: true, state: previous.state });
      }
      const registration = registrations.get(body.pairing_id);
      if (body.state === 'ringing' && !previous && !registration) {
        return reply(response, 409, { error: 'registration_required' });
      }
      const next = new Map(calls);
      const record = {
        pairing_id: body.pairing_id,
        call_id: body.call_id,
        revision: body.revision,
        state: body.state,
        notification_attempted: previous?.notification_attempted ?? body.state === 'ringing',
      };
      next.set(key, record);
      // Persist before any external effect. An uncertain attempt is never replayed after restart.
      await writeState(config.state_file, registrations, next);
      calls = next;
      const duplicate = body.state === 'ringing' && Boolean(previous);
      if (body.state === 'ringing' && !duplicate) {
        try {
          // Identity belongs only to this immediate delivery, never the persisted Call record.
          const payload = voipPayload({
            ...record, caller_name: body.caller_name, caller_number: body.caller_number,
          });
          await sendPush({ apns: config.apns, registration, payload });
        } catch {
          return reply(response, 502, { error: 'push_attempt_failed' });
        }
      }
      return reply(response, 200, { accepted: true, duplicate, state: record.state });
    };
    // State changes and publication share one order, including concurrent ended/ringing events.
    const operation = queue.then(execute);
    queue = operation.catch(() => {});
    try { await operation; } catch { if (!response.headersSent) reply(response, 500, { error: 'state_update_failed' }); }
  });
  return {
    server,
    async listen() {
      await new Promise((accept, reject) => {
        const failed = (error) => reject(error);
        server.once('error', failed);
        server.listen(config.port, config.listen, () => { server.off('error', failed); accept(); });
      });
      return server.address();
    },
    async close() {
      await queue;
      await smsInbox.flush();
      if (!server.listening) return;
      server.closeIdleConnections();
      await new Promise((accept, reject) => server.close((error) => error ? reject(error) : accept()));
    },
  };
}

async function main() {
  if (process.argv.length !== 4 || process.argv[2] !== '--config') {
    console.error('Usage: node server.mjs --config /path/to/private-config.json');
    process.exitCode = 2;
    return;
  }
  const provider = await createProvider(await loadConfig(process.argv[3]));
  await provider.listen();
  console.log('CallBridge provider started. Request bodies, tokens and credentials are not logged.');
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.once(signal, () => { provider.close().then(() => process.exit(0), () => process.exit(1)); });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => {
    console.error('Provider could not start. Check the private configuration, key, state file and listen address.');
    process.exitCode = 1;
  });
}
