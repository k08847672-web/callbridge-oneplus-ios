#!/bin/bash
# Synthetic fixtures only; no APNs, phones, credentials, signing or deployment.
set -eu
CALLBRIDGE_SMS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLBRIDGE_SMS_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/callbridge-sms-ios.XXXXXX")"
trap 'rm -rf "$CALLBRIDGE_SMS_BUILD"' EXIT
CALLBRIDGE_SMS_SOURCE="$CALLBRIDGE_SMS_ROOT/ios/CallBridge/CallBridge"
xcrun --sdk macosx swiftc -swift-version 5 \
  "$CALLBRIDGE_SMS_SOURCE/FrameProtocol.swift" \
  "$CALLBRIDGE_SMS_SOURCE/IncomingCallCoordinator.swift" \
  "$CALLBRIDGE_SMS_SOURCE/PairingStore.swift" \
  "$CALLBRIDGE_SMS_SOURCE/VerificationSMS.swift" \
  "$CALLBRIDGE_SMS_ROOT/ios/CallBridge/Tests/VerificationSMSSelfTests.swift" \
  -o "$CALLBRIDGE_SMS_BUILD/verification-sms-tests"
"$CALLBRIDGE_SMS_BUILD/verification-sms-tests"
