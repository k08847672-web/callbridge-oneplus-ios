"""Exercise the real rendered boot hook with fake Android commands; no device access."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[3]
RENDERER = ROOT / "scripts/device/render-callbridge-autostart.py"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("autostart_renderer", RENDERER)
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

FAKE_COMMAND = r'''
import json, os, pathlib, stat, subprocess, sys, time
root = pathlib.Path(os.environ["CALLBRIDGE_TEST_ROOT"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def state():
    return json.loads((root / "state.json").read_text())
def event(kind, **values):
    data = (json.dumps(dict(kind=kind, **values)) + "\n").encode()
    descriptor = os.open(root / "events.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(descriptor, data)
    os.close(descriptor)
current = state()
if name == "id":
    shell = os.environ.get("CALLBRIDGE_TEST_IN_SHELL") == "1"
    if args == ["-Z"]:
        print("u:r:shell:s0" if shell else "u:r:magisk:s0")
    else:
        print(current.get("shell_uid", 2000) if shell else 0)
elif name == "getprop":
    if args == ["sys.boot_completed"]:
        event("boot_probe")
        print("1" if current["boot"] else "0")
    else:
        print({"ro.product.model": "PJZ110", "ro.lineage.device": "dodge"}.get(args[0], ""))
elif name == "ip":
    event("ip_probe")
    if current["network"]:
        print("9: tun0    inet 100.64.0.7/32 scope global tun0")
elif name == "stat":
    print(format(stat.S_IMODE(os.stat(args[-1]).st_mode), "o"))
elif name == "pidof":
    event("process_scan")
    if current.get("existing"):
        print("101")
    else:
        sys.exit(1)
elif name == "sleep":
    time.sleep(0.03)
elif name == "su":
    event("su", flags=args[:5])
    environment = dict(os.environ, CALLBRIDGE_TEST_IN_SHELL="1")
    sys.exit(subprocess.call(["/bin/sh", "-c", args[5]], env=environment))
elif name == "app_process":
    event("bridge", argv=args, classpath=os.environ.get("CLASSPATH"),
          systemclasspath=os.environ.get("SYSTEMSERVERCLASSPATH"))
    print("synthetic bridge stdout", flush=True)
    print("synthetic bridge stderr", file=sys.stderr, flush=True)
    while state()["running"]:
        time.sleep(0.03)
else:
    raise AssertionError(name)
'''


class AutostartTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="callbridge-autostart-test-")
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.hook = self.root / "callbridge-autostart.sh"
        self.lock = self.root / "singleton.lock"
        self.config = self.root / "private dir's" / "android.properties"
        self.config.parent.mkdir()
        self.config.write_text("bindAddress=100.64.0.7\npairingKey=SYNTHETIC_NOT_A_REAL_KEY\n")
        self.config.chmod(0o600)
        self.jar = self.config.with_name("bridge's artifact.jar")
        self.jar.write_bytes(b"synthetic jar")
        self.log = self.config.with_name("bridge's output.log")
        self.log.write_text("existing bridge log\n")
        self.log.chmod(0o600)
        self.proc = self.root / "proc"
        (self.proc / "self").mkdir(parents=True)
        (self.proc / "self/status").write_text("CapEff:\t0000000000000000\n")
        self.classpath = self.root / "generated-classpath"
        self.classpath.write_text("export SYSTEMSERVERCLASSPATH /system/framework/synthetic.jar\n")
        fake = self.bin / "fake-command"
        fake.write_text(f"#!{sys.executable}\n" + FAKE_COMMAND)
        fake.chmod(0o700)
        for name in ("id", "getprop", "ip", "stat", "pidof", "sleep", "su", "app_process"):
            (self.bin / name).symlink_to(fake)
        (self.bin / "sed").symlink_to(shutil.which("sed"))
        self.state = dict(boot=False, network=False, running=True, existing=False)
        self.save_state()
        rendered = renderer.render(str(self.jar), str(self.config), str(self.bin / "su"), str(self.log))
        # Only map Android OS locations to a fixture; the boot logic is unchanged.
        for old, new in (
            ("/data/adb/service.d/callbridge-autostart.sh", str(self.hook)),
            ("/dev/.callbridge-autostart.lock", str(self.lock)),
            ("/data/system/environ/classpath", str(self.classpath)),
            ("/system/bin/", str(self.bin) + "/"),
            ("/proc/", str(self.proc) + "/"),
        ):
            rendered = rendered.replace(old, new)
        self.hook.write_text(rendered)
        self.environment = dict(os.environ, CALLBRIDGE_TEST_ROOT=str(self.root),
                                PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.environment.pop("SYSTEMSERVERCLASSPATH", None)
        self.groups = []

    def tearDown(self):
        for group in self.groups:
            try:
                os.killpg(group, signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.temporary.cleanup()

    def save_state(self, **changes):
        self.state.update(changes)
        staging = self.root / "state.tmp"
        staging.write_text(json.dumps(self.state))
        staging.replace(self.root / "state.json")

    def events(self, kind):
        path = self.root / "events.jsonl"
        return [item for line in path.read_text().splitlines()
                if (item := json.loads(line))["kind"] == kind] if path.exists() else []

    def until(self, condition):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.02)
        self.fail("boot-hook fixture did not reach the expected state")

    def launch(self):
        process = subprocess.Popen(["/bin/sh", str(self.hook)], env=self.environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        self.groups.append(process.pid)
        self.assertEqual(process.wait(timeout=2), 0)

    def existing(self, jar=None, argv0="app_process", config=None):
        directory = self.proc / "101"
        directory.mkdir()
        argv = [argv0, "/system/bin", "com.doitio.diagnostics.TelephonyNetworkBridge",
                str(config or self.config)]
        (directory / "cmdline").write_bytes(b"\0".join(value.encode() for value in argv) + b"\0")
        (directory / "environ").write_bytes(b"CLASSPATH=" + str(jar or self.jar).encode() + b"\0")
        self.save_state(boot=True, network=True, existing=True)

    def test_waits_for_boot_and_original_address_then_starts_once(self):
        self.launch()
        self.until(lambda: self.events("boot_probe"))
        self.assertFalse(self.events("su"))
        self.save_state(boot=True)
        self.until(lambda: self.events("ip_probe"))
        self.assertFalse(self.events("su"))
        # A simultaneous invocation must not race the startup owner.
        self.launch()
        self.save_state(network=True)
        self.until(lambda: self.events("bridge"))
        self.assertEqual(len(self.events("su")), 1)
        self.assertEqual(self.events("su")[0]["flags"], ["-d", "-Z", "u:r:shell:s0", "2000", "-c"])
        bridge = self.events("bridge")[0]
        self.assertEqual(bridge["classpath"], str(self.jar))
        self.assertEqual(bridge["argv"], ["/system/bin", "com.doitio.diagnostics.TelephonyNetworkBridge", str(self.config)])
        self.assertEqual(bridge["systemclasspath"], "/system/framework/synthetic.jar")
        self.save_state(running=False)
        self.until(lambda: not self.lock.exists())
        self.assertEqual(self.log.read_text(), "existing bridge log\nsynthetic bridge stdout\nsynthetic bridge stderr\n")
        self.assertEqual(self.log.stat().st_mode & 0o777, 0o600)
        time.sleep(0.1)
        self.assertEqual(len(self.events("bridge")), 1, "bridge exit must not cause a restart")

    def test_existing_exact_production_process_is_untouched(self):
        self.existing()
        self.launch()
        self.until(lambda: self.events("process_scan") and not self.lock.exists())
        self.assertFalse(self.events("su"))

    def test_conflicting_jar_does_not_start_second_bridge(self):
        self.existing(jar=self.root / "other.jar")
        self.launch()
        self.until(lambda: self.events("process_scan") and not self.lock.exists())
        self.assertFalse(self.events("su"))

    def test_parent_command_or_other_config_cannot_suppress_start(self):
        self.existing(argv0="su", config=self.root / "another.properties")
        self.launch()
        self.until(lambda: self.events("bridge"))
        self.assertEqual(len(self.events("su")), 1)

    def test_removing_hook_cancels_pending_bootstrap_and_cleans_lock(self):
        self.launch()
        self.until(lambda: self.events("boot_probe"))
        self.hook.unlink()
        self.until(lambda: not self.lock.exists())
        self.assertFalse(self.events("su"))

    def test_original_private_mode_is_required(self):
        self.config.chmod(0o644)
        self.save_state(boot=True, network=True)
        self.launch()
        time.sleep(0.2)
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.events("su"))

    def test_bridge_is_not_executed_if_su_does_not_drop_uid(self):
        self.save_state(boot=True, network=True, shell_uid=0)
        self.launch()
        self.until(lambda: self.events("su") and not self.lock.exists())
        self.assertFalse(self.events("bridge"))
        self.assertEqual(self.log.read_text(), "existing bridge log\n")

    def test_renderer_cli_quotes_paths_and_creates_private_output(self):
        output = self.root / "private-render.sh"
        result = subprocess.run([sys.executable, str(RENDERER), "--jar-path", str(self.jar),
                                 "--config-path", str(self.config), "--su-path", str(self.bin / "su"),
                                 "--log-path", str(self.log),
                                 "--output", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertEqual(subprocess.run(["/bin/sh", "-n", str(output)]).returncode, 0)
        self.assertNotIn("@@", output.read_text())
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
