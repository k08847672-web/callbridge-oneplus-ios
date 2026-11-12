import { mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { dirname } from 'node:path';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MESSAGE_ID = /^[0-9a-f]{64}$/;
export const SMS_PAGE_SIZE = 100;

export function smsValid(value) {
  return UUID.test(value?.pairing_id ?? '') && MESSAGE_ID.test(value.message_id ?? '')
    && Number.isSafeInteger(value.received_at_ms) && value.received_at_ms >= 0
    && typeof value.sender === 'string' && typeof value.body === 'string'
    && (value.code === null || (typeof value.code === 'string' && /^[0-9]+$/.test(value.code)));
}

export function smsPayload(message) {
  return {
    aps: { alert: { title: '收到验证码短信', body: '打开应用查看' }, sound: 'default' },
    kind: 'verification_sms', pairing_id: message.pairing_id, message_id: message.message_id,
  };
}

function registrationValid(value) {
  return UUID.test(value?.pairing_id ?? '') && typeof value.push_token === 'string'
    && /^[0-9a-f]+$/i.test(value.push_token) && value.push_token.length % 2 === 0
    && ['sandbox', 'production'].includes(value.environment);
}

function messageKey(message) { return JSON.stringify([message.pairing_id, message.message_id]); }

async function readState(filename) {
  try {
    const state = JSON.parse(await readFile(filename, 'utf8'));
    if (state.version !== 1 || !Array.isArray(state.registrations) || !Array.isArray(state.messages)
      || !state.registrations.every(registrationValid)) throw new Error('invalid_sms_state');
    const registrations = new Set();
    for (const entry of state.registrations) {
      if (registrations.has(entry.pairing_id)) throw new Error('duplicate_sms_registration');
      registrations.add(entry.pairing_id);
    }
    const sequences = new Map(), seen = new Set();
    for (const message of state.messages) {
      const key = messageKey(message);
      if (!smsValid(message) || message.seq !== (sequences.get(message.pairing_id) ?? 0) + 1 || seen.has(key)) {
        throw new Error('invalid_sms_sequence');
      }
      sequences.set(message.pairing_id, message.seq); seen.add(key);
    }
    return state;
  } catch (error) {
    if (error.code === 'ENOENT') return { version: 1, registrations: [], messages: [] };
    throw new Error('Cannot load SMS state');
  }
}

async function writeState(filename, registrations, messages) {
  await mkdir(dirname(filename), { recursive: true, mode: 0o700 });
  const temporary = `${filename}.${randomBytes(8).toString('hex')}.tmp`;
  try {
    await writeFile(temporary, JSON.stringify({
      version: 1, registrations: [...registrations.values()], messages: [...messages.values()],
    }), { encoding: 'utf8', mode: 0o600, flag: 'wx' });
    await rename(temporary, filename);
  } finally {
    await unlink(temporary).catch((error) => { if (error.code !== 'ENOENT') throw error; });
  }
}

export async function createSmsInbox(filename) {
  const stored = await readState(filename);
  let registrations = new Map(stored.registrations.map((entry) => [entry.pairing_id, entry]));
  let messages = new Map(stored.messages.map((entry) => [messageKey(entry), entry]));
  const sequences = new Map();
  for (const message of stored.messages) sequences.set(message.pairing_id, message.seq);
  let queue = Promise.resolve();
  function ordered(operation) {
    const result = queue.then(operation);
    queue = result.catch(() => {});
    return result;
  }
  return {
    register(body) {
      return ordered(async () => {
        const next = new Map(registrations);
        next.set(body.pairing_id, {
          pairing_id: body.pairing_id, push_token: body.push_token.toLowerCase(), environment: body.environment,
        });
        await writeState(filename, next, messages);
        registrations = next;
      });
    },
    save(body) {
      return ordered(async () => {
        const key = messageKey(body), previous = messages.get(key);
        if (previous) return { duplicate: true, message: previous };
        const seq = (sequences.get(body.pairing_id) ?? 0) + 1;
        if (!Number.isSafeInteger(seq)) throw new Error('SMS sequence exhausted');
        const message = {
          pairing_id: body.pairing_id, message_id: body.message_id, received_at_ms: body.received_at_ms,
          sender: body.sender, body: body.body, code: body.code, seq,
        };
        const next = new Map(messages); next.set(key, message);
        await writeState(filename, registrations, next);
        messages = next; sequences.set(body.pairing_id, seq);
        return { duplicate: false, message, registration: registrations.get(body.pairing_id) };
      });
    },
    sync(pairingID, afterSeq) {
      return ordered(() => {
        const pending = [...messages.values()].filter((item) => item.pairing_id === pairingID && item.seq > afterSeq);
        const page = pending.slice(0, SMS_PAGE_SIZE);
        return { messages: page, next_after_seq: page.at(-1)?.seq ?? afterSeq, has_more: pending.length > page.length };
      });
    },
    flush() { return queue; },
  };
}
