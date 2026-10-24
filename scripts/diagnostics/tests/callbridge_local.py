"""Actual production JVM admission + Swift client on localhost, with synthetic Call/audio."""
import datetime, json, os, pathlib, plistlib, select, subprocess, sys, time
root = pathlib.Path(__file__).resolve().parents[3]
build, classpath, node = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
java = str(pathlib.Path(os.environ['JAVA_HOME']) / 'bin/java')

def ready(process, prefix):
    readable, _, _ = select.select([process.stdout], [], [], 15)
    if not readable: raise RuntimeError('fixture did not become ready')
    line = process.stdout.readline().strip()
    if not line.startswith(prefix + ' '): raise RuntimeError('fixture startup: ' + line)
    return line.split()[-1]

def stop(process):
    if process.poll() is None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()

def scenario(mode, provider=None, payload=None):
    environment = dict(os.environ)
    if provider: environment['CALLBRIDGE_FIXTURE_PROVIDER_URL'] = provider
    server = subprocess.Popen([java, '-cp', classpath, 'com.doitio.diagnostics.TelephonyNetworkBridge',
        'local-fixture', '0', mode], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment)
    try:
        port = ready(server, 'PJZ_LOCAL_READY')
        if payload:
            until = time.monotonic() + 10
            while not payload.exists() and time.monotonic() < until: time.sleep(0.01)
            if not payload.exists(): raise RuntimeError('provider did not deliver synthetic payload')
            command = [str(build/'push-join-client'), port, str(payload)]
        else: command = [str(build/'join-client'), port, mode]
        client = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=20)
        output = server.communicate(timeout=15)[0]
        log = client.stdout + output
        name = 'push-join' if payload else 'localhost-' + mode
        (build/(name+'.log')).write_text(log)
        print(log.strip(), flush=True)
        if client.returncode or server.returncode: raise RuntimeError(name + ' failed')
    finally: stop(server)

for mode in ['ringing', 'ended', 'mismatch', 'foreground']: scenario(mode)
provider = subprocess.Popen([node, str(root/'scripts/diagnostics/tests/callbridge_mock_delivery.mjs'), str(build)],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    port = ready(provider, 'PJZ_MOCK_READY')
    scenario('ringing', 'http://127.0.0.1:'+port, build/'mock-payload.json')
    state = json.loads((build/'mock-state.json').read_text())
    assert len(state['calls']) == 1 and state['calls'][0]['state'] == 'ended'
    assert state['calls'][0]['revision'] == 2
    print('PASS mock_provider production_android_publisher HTTP_ingress Swift_coordinator real_JOIN synthetic_PCM ended_tombstone', flush=True)
finally: stop(provider)

# Pairing delivery file expires at import; both durable configs use the same independent identifiers/keys.
pairdir = build/'private-pairing'
pairdir.mkdir(mode=0o700)
result = subprocess.run([str(build/'prepare-pairing'), '100.64.0.1', str(pairdir), '--provider-url', 'https://example.invalid'],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
if result.returncode: raise RuntimeError('pairing generator failed: '+result.stdout)
iphone = plistlib.loads((pairdir/'CallBridgePairing.plist').read_bytes())
android = dict(line.split('=',1) for line in (pairdir/'android.properties').read_text().splitlines())
providerpair = json.loads((pairdir/'provider-pair.json').read_text())
import hashlib
assert iphone['pairing_id'] == android['pairingId'] == providerpair['pairing_id']
assert iphone['pairingKey'] == android['pairingKey']
assert iphone['providerToken'] == android['providerToken'] != android['pairingKey']
assert hashlib.sha256(android['providerToken'].encode()).hexdigest() == providerpair['provider_token_hash']
assert 0 < iphone['expiresAt'].replace(tzinfo=datetime.timezone.utc).timestamp() - time.time() < 601
assert all(p.stat().st_mode & 0o777 == 0o600 for p in pairdir.iterdir())
print('PASS private_pairing matching_ids independent_provider_key private_modes import_only_expiry', flush=True)
