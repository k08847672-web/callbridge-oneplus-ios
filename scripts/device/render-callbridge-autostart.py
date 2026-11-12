#!/usr/bin/env python3
"""Render one private Magisk hook; never read pairing contents or access a device."""
import argparse
import os
from pathlib import Path
import shlex


def absolute_path(value):
    if not value.startswith("/") or any(character in value for character in "\0\r\n"):
        raise argparse.ArgumentTypeError("use an absolute path without control characters")
    return value


def render(jar_path, config_path, su_path, log_path):
    template = Path(__file__).with_name("callbridge-autostart.sh").read_text()
    # Check the actual child identity before executing any bridge code. No new
    # Android permission, SELinux rule, supplementary group or capability is added.
    shell_command = "\n".join([
        '[ "$(/system/bin/id -u)" = 2000 ] || exit 1',
        '[ "$(/system/bin/id -g)" = 2000 ] || exit 1',
        '[ "$(/system/bin/id -Z)" = u:r:shell:s0 ] || exit 1',
        'CALLBRIDGE_CAPS="$(/system/bin/sed -n \'s/^CapEff:[[:space:]]*//p\' /proc/self/status)"',
        'case "$CALLBRIDGE_CAPS" in ""|*[!0]*) exit 1 ;; esac',
        f"CLASSPATH={shlex.quote(jar_path)}",
        "export CLASSPATH",
        "exec /system/bin/app_process /system/bin "
        "com.doitio.diagnostics.TelephonyNetworkBridge " + shlex.quote(config_path)
        + " >> " + shlex.quote(log_path) + " 2>&1",
    ])
    values = {
        "JAR_PATH": jar_path,
        "CONFIG_PATH": config_path,
        "SU_PATH": su_path,
        "SHELL_COMMAND": shell_command,
    }
    for name, value in values.items():
        template = template.replace(f"@@{name}@@", shlex.quote(value))
    return template


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar-path", type=absolute_path, required=True)
    parser.add_argument("--config-path", type=absolute_path, required=True)
    parser.add_argument("--su-path", type=absolute_path, required=True)
    parser.add_argument("--log-path", type=absolute_path, required=True)
    parser.add_argument("--output", type=absolute_path, required=True)
    args = parser.parse_args()
    result = render(args.jar_path, args.config_path, args.su_path, args.log_path)
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o700)
    with os.fdopen(descriptor, "w") as output:
        os.fchmod(output.fileno(), 0o700)
        output.write(result)


if __name__ == "__main__":
    main()
