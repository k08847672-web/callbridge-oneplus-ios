// Synthetic local ingress/delivery adapter only; no APNs network or credentials.
import { createProvider, tokenHash } from '../../../callbridge_push/server.mjs';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
const directory = process.argv[2];
const token = '5a'.repeat(32);
const pairing = '00000000-0000-4000-8000-000000000010';
const provider = await createProvider({ listen: '127.0.0.1', port: 0, mode: 'mock',
  state_file: join(directory, 'mock-state.json'), pairs: [{ pairing_id: pairing, provider_token_hash: tokenHash(token) }],
}, { pushSender: async ({ payload }) => {
  await writeFile(join(directory, 'mock-payload.json'), JSON.stringify(payload), { mode: 0o600 });
} });
const address = await provider.listen();
const origin = `http://127.0.0.1:${address.port}`;
const registration = await fetch(`${origin}/v1/register`, { method: 'POST',
  headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
  body: JSON.stringify({ pairing_id: pairing, push_token: 'ab'.repeat(32), environment: 'sandbox' }),
});
if (registration.status !== 200) throw new Error('fixture_registration');
console.log(`PJZ_MOCK_READY ${address.port}`);
process.once('SIGTERM', async () => { await provider.close(); process.exit(0); });
