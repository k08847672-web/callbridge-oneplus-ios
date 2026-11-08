#!/bin/bash
# Build an unsigned helper by default. Optional signing uses an explicitly supplied keystore.
set -eu
BRIDGE_HELPER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_HELPER_JDK="${JAVA_HOME:-}"
if [ -z "$BRIDGE_HELPER_JDK" ] && [ -x /usr/libexec/java_home ]; then BRIDGE_HELPER_JDK="$(/usr/libexec/java_home -v 17)"; fi
: "${BRIDGE_HELPER_JDK:?Set JAVA_HOME to JDK 17 or later}"
export JAVA_HOME="$BRIDGE_HELPER_JDK"
BRIDGE_HELPER_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
: "${BRIDGE_HELPER_SDK:?Set ANDROID_SDK_ROOT or ANDROID_HOME}"
BRIDGE_HELPER_PLATFORM="${CALLBRIDGE_ANDROID_PLATFORM:-android-36}"
BRIDGE_HELPER_TOOLS="$BRIDGE_HELPER_SDK/build-tools/${CALLBRIDGE_BUILD_TOOLS:-36.0.0}"
BRIDGE_HELPER_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pjz-callbridge-helper.XXXXXX")"
mkdir -p "$BRIDGE_HELPER_BUILD/classes" "$BRIDGE_HELPER_BUILD/dex"
"$BRIDGE_HELPER_JDK/bin/javac" --release 8 -cp "$BRIDGE_HELPER_SDK/platforms/$BRIDGE_HELPER_PLATFORM/android.jar" \
  -d "$BRIDGE_HELPER_BUILD/classes" \
  "$BRIDGE_HELPER_ROOT/android/callbridgehelper/src/main/java/com/doitio/callbridgehelper/BridgeInCallService.java" \
  "$BRIDGE_HELPER_ROOT/android/callbridgehelper/src/main/java/com/doitio/callbridgehelper/BridgeControlProvider.java" \
  "$BRIDGE_HELPER_ROOT/android/callbridgehelper/src/main/java/com/doitio/callbridgehelper/CallBridgeControl.java"
BRIDGE_HELPER_CLASSES=("$BRIDGE_HELPER_BUILD"/classes/com/doitio/callbridgehelper/*.class)
"$BRIDGE_HELPER_TOOLS/d8" --min-api 31 --lib "$BRIDGE_HELPER_SDK/platforms/$BRIDGE_HELPER_PLATFORM/android.jar" \
  --output "$BRIDGE_HELPER_BUILD/dex" "${BRIDGE_HELPER_CLASSES[@]}"
"$BRIDGE_HELPER_TOOLS/aapt2" link -I "$BRIDGE_HELPER_SDK/platforms/$BRIDGE_HELPER_PLATFORM/android.jar" \
  --manifest "$BRIDGE_HELPER_ROOT/android/callbridgehelper/src/main/AndroidManifest.xml" -o "$BRIDGE_HELPER_BUILD/unsigned.apk"
zip -j "$BRIDGE_HELPER_BUILD/unsigned.apk" "$BRIDGE_HELPER_BUILD/dex/classes.dex" >/dev/null
"$BRIDGE_HELPER_TOOLS/zipalign" -f 4 "$BRIDGE_HELPER_BUILD/unsigned.apk" "$BRIDGE_HELPER_BUILD/callbridge-helper-unsigned.apk"
if [ -n "${CALLBRIDGE_KEYSTORE:-}" ]; then
  : "${CALLBRIDGE_KEY_ALIAS:?Set CALLBRIDGE_KEY_ALIAS}"
  : "${CALLBRIDGE_KS_PASSWORD:?Set CALLBRIDGE_KS_PASSWORD privately in the environment}"
  : "${CALLBRIDGE_KEY_PASSWORD:?Set CALLBRIDGE_KEY_PASSWORD privately in the environment}"
  "$BRIDGE_HELPER_TOOLS/apksigner" sign --ks "$CALLBRIDGE_KEYSTORE" --ks-key-alias "$CALLBRIDGE_KEY_ALIAS" \
    --ks-pass env:CALLBRIDGE_KS_PASSWORD --key-pass env:CALLBRIDGE_KEY_PASSWORD \
    --out "$BRIDGE_HELPER_BUILD/callbridge-helper.apk" "$BRIDGE_HELPER_BUILD/callbridge-helper-unsigned.apk"
  "$BRIDGE_HELPER_TOOLS/apksigner" verify --verbose "$BRIDGE_HELPER_BUILD/callbridge-helper.apk"
  shasum -a 256 "$BRIDGE_HELPER_BUILD/callbridge-helper.apk"
else
  shasum -a 256 "$BRIDGE_HELPER_BUILD/callbridge-helper-unsigned.apk"
fi
printf 'Build directory: %s\n' "$BRIDGE_HELPER_BUILD"
