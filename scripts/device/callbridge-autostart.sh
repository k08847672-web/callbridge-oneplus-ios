#!/system/bin/sh
# Template: render with render-callbridge-autostart.py before installing.
# Root bootstraps the existing shell bridge; it never runs bridge code as root.
CALLBRIDGE_HOOK=/data/adb/service.d/callbridge-autostart.sh
CALLBRIDGE_LOCK=/dev/.callbridge-autostart.lock
CALLBRIDGE_JAR=@@JAR_PATH@@
CALLBRIDGE_CONFIG=@@CONFIG_PATH@@
CALLBRIDGE_SU=@@SU_PATH@@
CALLBRIDGE_SHELL_COMMAND=@@SHELL_COMMAND@@

(
    [ "$(id -u)" = 0 ] || exit 1
    [ "$(/system/bin/getprop ro.product.model)" = PJZ110 ] || exit 1
    [ "$(/system/bin/getprop ro.lineage.device)" = dodge ] || exit 1
    [ -f "$CALLBRIDGE_HOOK" ] && [ ! -L "$CALLBRIDGE_HOOK" ] || exit 1
    mkdir "$CALLBRIDGE_LOCK" 2>/dev/null || exit 0
    trap 'rmdir "$CALLBRIDGE_LOCK" 2>/dev/null' EXIT
    trap 'exit 0' HUP INT TERM

    [ -f "$CALLBRIDGE_JAR" ] && [ ! -L "$CALLBRIDGE_JAR" ] || exit 1
    [ -f "$CALLBRIDGE_CONFIG" ] && [ ! -L "$CALLBRIDGE_CONFIG" ] || exit 1
    [ "$(stat -c %a "$CALLBRIDGE_CONFIG")" = 600 ] || exit 1
    [ -x "$CALLBRIDGE_SU" ] || exit 1
    # The pairing generator writes this literal IPv4 property. Never source it.
    CALLBRIDGE_BIND="$(sed -n 's/^bindAddress=//p' "$CALLBRIDGE_CONFIG")"
    [ -n "$CALLBRIDGE_BIND" ] || exit 1
    while :; do
        # Removing only our hook also cancels a bootstrap still waiting for VPN.
        [ -f "$CALLBRIDGE_HOOK" ] || exit 0
        if [ "$(/system/bin/getprop sys.boot_completed)" = 1 ] &&
            /system/bin/ip -o -4 addr show up | awk -v address="$CALLBRIDGE_BIND" '
                { split($4, parts, "/"); if (parts[1] == address) found = 1 }
                END { exit !found }
            '; then
            break
        fi
        sleep 2
    done

    # Match real app_process argv, not a su/sh command mentioning this class.
    CALLBRIDGE_SUFFIX="$(printf '\n%s\n%s\n%s' /system/bin \
        com.doitio.diagnostics.TelephonyNetworkBridge "$CALLBRIDGE_CONFIG")"
    for CALLBRIDGE_PID in $(pidof app_process app_process64 app_process32 2>/dev/null); do
        CALLBRIDGE_ARGV="$(tr '\000' '\n' <"/proc/$CALLBRIDGE_PID/cmdline" 2>/dev/null)"
        case "$CALLBRIDGE_ARGV" in
            "app_process$CALLBRIDGE_SUFFIX"|"/system/bin/app_process$CALLBRIDGE_SUFFIX")
                CALLBRIDGE_CP="$(tr '\000' '\n' <"/proc/$CALLBRIDGE_PID/environ" 2>/dev/null |
                    sed -n 's/^CLASSPATH=//p')"
                # An existing production bridge is left untouched. A conflicting
                # JAR using the same command/config is not a reason to start two.
                [ "$CALLBRIDGE_CP" = "$CALLBRIDGE_JAR" ] || exit 1
                exit 0
                ;;
        esac
    done

    # Unlike ADB, Magisk's boot environment may not contain the derived classpath.
    if [ -z "${SYSTEMSERVERCLASSPATH:-}" ]; then
        SYSTEMSERVERCLASSPATH="$(sed -n 's/^export SYSTEMSERVERCLASSPATH //p' \
            /data/system/environ/classpath | head -n 1)"
        [ -n "$SYSTEMSERVERCLASSPATH" ] || exit 1
        export SYSTEMSERVERCLASSPATH
    fi
    [ -f "$CALLBRIDGE_HOOK" ] || exit 0
    # Wait only to retain/clean the singleton lock. No restart loop on bridge exit.
    "$CALLBRIDGE_SU" -d -Z u:r:shell:s0 2000 -c "$CALLBRIDGE_SHELL_COMMAND"
) </dev/null >/dev/null 2>&1 &
