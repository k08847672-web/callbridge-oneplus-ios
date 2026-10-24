#!/bin/bash
# Build only: no ADB, device access, audio or pairing-file reads.
set -eu
BRIDGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_JDK_DIR="${JAVA_HOME:-}"
if [ -z "$BRIDGE_JDK_DIR" ] && [ -x /usr/libexec/java_home ]; then BRIDGE_JDK_DIR="$(/usr/libexec/java_home -v 17)"; fi
: "${BRIDGE_JDK_DIR:?Set JAVA_HOME to JDK 17 or later}"
export JAVA_HOME="$BRIDGE_JDK_DIR"
BRIDGE_SDK_DIR="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
: "${BRIDGE_SDK_DIR:?Set ANDROID_SDK_ROOT or ANDROID_HOME}"
BRIDGE_PLATFORM="${CALLBRIDGE_ANDROID_PLATFORM:-android-36}"
BRIDGE_TOOLS="${CALLBRIDGE_BUILD_TOOLS:-36.0.0}"
BRIDGE_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pjz-call-bridge.XXXXXX")"
mkdir -p "$BRIDGE_BUILD_DIR/classes"
"$BRIDGE_JDK_DIR/bin/javac" --release 8 -classpath "$BRIDGE_SDK_DIR/platforms/$BRIDGE_PLATFORM/android.jar" \
  -d "$BRIDGE_BUILD_DIR/classes" "$BRIDGE_ROOT/scripts/diagnostics/TelephonyNetworkBridge.java"
BRIDGE_CLASSES=("$BRIDGE_BUILD_DIR"/classes/com/doitio/diagnostics/*.class)
"$BRIDGE_SDK_DIR/build-tools/$BRIDGE_TOOLS/d8" --min-api 31 \
  --lib "$BRIDGE_SDK_DIR/platforms/$BRIDGE_PLATFORM/android.jar" \
  --output "$BRIDGE_BUILD_DIR/bridge.jar" "${BRIDGE_CLASSES[@]}"
shasum -a 256 "$BRIDGE_ROOT/scripts/diagnostics/TelephonyNetworkBridge.java" "$BRIDGE_BUILD_DIR/bridge.jar"
printf 'Build directory: %s\n' "$BRIDGE_BUILD_DIR"
