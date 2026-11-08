#!/bin/bash
# Local fixtures only. Never uses ADB, real APNs, phone calls, microphones or signing identities.
set -eu
CALLBRIDGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then export JAVA_HOME="$(/usr/libexec/java_home -v 17)"; fi
: "${JAVA_HOME:?Set JAVA_HOME to JDK 17 or later}"
CALLBRIDGE_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
: "${CALLBRIDGE_SDK:?Set ANDROID_SDK_ROOT or ANDROID_HOME}"
CALLBRIDGE_NODE="${NODE:-node}"
CALLBRIDGE_PYTHON="${PYTHON:-python3}"
CALLBRIDGE_TEST_BUILD="${CALLBRIDGE_TEST_BUILD:-$(mktemp -d "${TMPDIR:-/tmp}/callbridge-local.XXXXXX")}"
mkdir -p "$CALLBRIDGE_TEST_BUILD/classes"
CALLBRIDGE_ANDROID_JAR="$CALLBRIDGE_SDK/platforms/${CALLBRIDGE_ANDROID_PLATFORM:-android-36}/android.jar"
"$JAVA_HOME/bin/javac" --release 8 -cp "$CALLBRIDGE_ANDROID_JAR" -d "$CALLBRIDGE_TEST_BUILD/classes" \
  "$CALLBRIDGE_ROOT/scripts/diagnostics/TelephonyNetworkBridge.java" \
  "$CALLBRIDGE_ROOT/android/callbridgehelper/src/main/java/com/doitio/callbridgehelper/CallBridgeControl.java"
CALLBRIDGE_CP="$CALLBRIDGE_TEST_BUILD/classes:$CALLBRIDGE_ANDROID_JAR"
CALLBRIDGE_SWIFT="$CALLBRIDGE_ROOT/ios/CallBridge/CallBridge"
CALLBRIDGE_TESTS="$CALLBRIDGE_ROOT/ios/CallBridge/Tests"
xcrun --sdk macosx swiftc "$CALLBRIDGE_SWIFT/FrameProtocol.swift" "$CALLBRIDGE_SWIFT/PairingStore.swift" \
  "$CALLBRIDGE_SWIFT/IncomingCallCoordinator.swift" "$CALLBRIDGE_TESTS/IncomingCallSelfTests.swift" \
  -o "$CALLBRIDGE_TEST_BUILD/incoming-tests"
xcrun --sdk macosx swiftc -D DEBUG "$CALLBRIDGE_SWIFT/FrameProtocol.swift" "$CALLBRIDGE_SWIFT/BridgeClient.swift" \
  "$CALLBRIDGE_TESTS/JoinClientSelfTests.swift" -o "$CALLBRIDGE_TEST_BUILD/join-client"
xcrun --sdk macosx swiftc -D DEBUG "$CALLBRIDGE_SWIFT/FrameProtocol.swift" "$CALLBRIDGE_SWIFT/BridgeClient.swift" \
  "$CALLBRIDGE_TESTS/CallerIdentityClientSelfTests.swift" -o "$CALLBRIDGE_TEST_BUILD/caller-identity-client"
xcrun --sdk macosx swiftc -D DEBUG "$CALLBRIDGE_SWIFT/FrameProtocol.swift" "$CALLBRIDGE_SWIFT/PairingStore.swift" \
  "$CALLBRIDGE_SWIFT/IncomingCallCoordinator.swift" "$CALLBRIDGE_SWIFT/BridgeClient.swift" \
  "$CALLBRIDGE_TESTS/PushJoinSelfTests.swift" -o "$CALLBRIDGE_TEST_BUILD/push-join-client"
xcrun --sdk macosx swiftc "$CALLBRIDGE_SWIFT/FrameProtocol.swift" "$CALLBRIDGE_ROOT/scripts/diagnostics/PrepareCallBridgePairing.swift" \
  -o "$CALLBRIDGE_TEST_BUILD/prepare-pairing"
if [ "${1:-}" = "--check" ]; then
  "$CALLBRIDGE_NODE" --check "$CALLBRIDGE_ROOT/callbridge_push/server.mjs"
  printf 'Portable entry compilation passed: %s\n' "$CALLBRIDGE_TEST_BUILD"
  exit 0
fi
"$JAVA_HOME/bin/java" -cp "$CALLBRIDGE_CP" com.doitio.diagnostics.TelephonyNetworkBridge self-test
"$CALLBRIDGE_TEST_BUILD/incoming-tests"
"$CALLBRIDGE_TEST_BUILD/caller-identity-client"
"$CALLBRIDGE_PYTHON" "$CALLBRIDGE_ROOT/scripts/diagnostics/tests/callbridge_local.py" \
  "$CALLBRIDGE_TEST_BUILD" "$CALLBRIDGE_CP" "$CALLBRIDGE_NODE"
"$CALLBRIDGE_PYTHON" "$CALLBRIDGE_ROOT/scripts/diagnostics/tests/callbridge_transport_regression.py" "$CALLBRIDGE_TEST_BUILD"
"$CALLBRIDGE_PYTHON" "$CALLBRIDGE_ROOT/scripts/diagnostics/tests/callbridge_helper_regression.py" "$CALLBRIDGE_TEST_BUILD"
"$CALLBRIDGE_PYTHON" "$CALLBRIDGE_ROOT/scripts/diagnostics/tests/callbridge_android_ingress_regression.py" "$CALLBRIDGE_TEST_BUILD"
"$CALLBRIDGE_PYTHON" "$CALLBRIDGE_ROOT/scripts/diagnostics/tests/callbridge_wait_regression.py" "$CALLBRIDGE_TEST_BUILD"
"$CALLBRIDGE_PYTHON" "$CALLBRIDGE_ROOT/scripts/diagnostics/tests/callbridge_swift_recovery.py" "$CALLBRIDGE_TEST_BUILD"
"$CALLBRIDGE_NODE" --test "$CALLBRIDGE_ROOT"/callbridge_push/tests/*.test.mjs
printf 'PASS local synthetic checks. Hardware, APNs delivery and locked-screen wakeup remain unverified. Artifacts: %s\n' "$CALLBRIDGE_TEST_BUILD"
