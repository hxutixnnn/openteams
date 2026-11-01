#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY_FILE="$HOME/Library/Application Support/TeamsChat/signing-identity"
IFS= read -r IDENTITY < "$IDENTITY_FILE"
[[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]]
cd "$ROOT_DIR"
swift build --product TeamsCredentialPrototype
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p .codex/validation
STAGE="$(mktemp -d "$ROOT_DIR/.codex/validation/xpc-proof.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Proof.app"
SERVICE="$APP/Contents/XPCServices/TeamsCredentialPrototype.xpc"
mkdir -p "$APP/Contents/MacOS" "$SERVICE/Contents/MacOS"
cp "$BIN_DIR/TeamsCredentialPrototype" "$SERVICE/Contents/MacOS/TeamsCredentialPrototype"
swiftc -swift-version 5 Tests/TeamsCredentialPrototype/Client.swift -o "$APP/Contents/MacOS/Proof"
cat > "$SERVICE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.native.teamschat.credential-prototype</string>
<key>CFBundleExecutable</key><string>TeamsCredentialPrototype</string><key>CFBundlePackageType</key><string>XPC!</string>
<key>TeamsSigningCertificate</key><string>$IDENTITY</string><key>TeamsPrototypeStore</key><string>dev.native.teamschat.prototype.$(basename "$STAGE")</string><key>TeamsPrototypeKeychain</key><string>$STAGE/dummy.keychain-db</string><key>XPCService</key><dict><key>ServiceType</key><string>Application</string><key>JoinExistingSession</key><true/></dict>
</dict></plist>
PLIST
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.native.teamschat</string><key>CFBundleExecutable</key><string>Proof</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/><key>TeamsSigningCertificate</key><string>$IDENTITY</string>
</dict></plist>
PLIST
codesign --force --sign "$IDENTITY" "$SERVICE"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/Proof"
"$APP/Contents/MacOS/Proof" --clear-during-save
"$APP/Contents/MacOS/Proof" --replay
"$APP/Contents/MacOS/Proof" --wrong-scope
"$APP/Contents/MacOS/Proof" --diagnose-login
GUI_OUTPUT="$STAGE/gui-diagnostic.txt"
open -n "$APP" --args --diagnose-login --diagnostic-output "$GUI_OUTPUT"
for attempt in {1..20}; do
  [[ -s "$GUI_OUTPUT" ]] && break
  sleep 0.5
done
[[ -s "$GUI_OUTPUT" ]]
printf 'GUI-launched login diagnostic: '
cat "$GUI_OUTPUT"
printf '\n'
"$APP/Contents/MacOS/Proof" --interrupt
"$APP/Contents/MacOS/Proof" --expect-empty
SAVE_OUTPUT="$("$APP/Contents/MacOS/Proof" --save-only)"
printf 'save before helper restart: %s\n' "$SAVE_OUTPUT"
sleep 1
STALE_VERSION="${SAVE_OUTPUT##*version=}"
STALE_OUTPUT="$("$APP/Contents/MacOS/Proof" --stale-version "$STALE_VERSION")"
printf 'stale helper version: %s\n' "$STALE_OUTPUT"
[[ "$STALE_OUTPUT" == *"success=true callbacks=0"* ]]
HELPER_BEFORE="$(shasum -a 256 "$SERVICE/Contents/MacOS/TeamsCredentialPrototype" | awk '{print $1}')"
APP_BEFORE="$(shasum -a 256 "$APP/Contents/MacOS/Proof" | awk '{print $1}')"
swiftc -swift-version 5 -D BUILD_TWO Tests/TeamsCredentialPrototype/Client.swift -o "$APP/Contents/MacOS/Proof"
codesign --force --sign "$IDENTITY" "$APP"
APP_AFTER="$(shasum -a 256 "$APP/Contents/MacOS/Proof" | awk '{print $1}')"
HELPER_AFTER="$(shasum -a 256 "$SERVICE/Contents/MacOS/TeamsCredentialPrototype" | awk '{print $1}')"
[[ "$APP_BEFORE" != "$APP_AFTER" && "$HELPER_BEFORE" == "$HELPER_AFTER" ]]
printf 'outer binary changed; helper digest retained\n'
LOAD_OUTPUT="$("$APP/Contents/MacOS/Proof" --load-only)"
printf 'load after helper restart: %s\n' "$LOAD_OUTPUT"
SAVE_PID="${SAVE_OUTPUT##*helperPID=}"
SAVE_PID="${SAVE_PID%% *}"
LOAD_PID="${LOAD_OUTPUT##*helperPID=}"
LOAD_PID="${LOAD_PID%% *}"
[[ "$SAVE_PID" != "$LOAD_PID" ]]
codesign --force --sign "$IDENTITY" --identifier dev.native.wrong "$APP"
set +e
WRONG_ID_OUTPUT="$("$APP/Contents/MacOS/Proof")"
WRONG_ID_STATUS=$?
set -e
printf 'wrong identifier: %s\n' "$WRONG_ID_OUTPUT"
[[ "$WRONG_ID_STATUS" -ne 0 && "$WRONG_ID_OUTPUT" == *"callbacks=0"* ]]
codesign --force --sign - --identifier dev.native.teamschat "$APP"
set +e
WRONG_CERT_OUTPUT="$("$APP/Contents/MacOS/Proof")"
WRONG_CERT_STATUS=$?
set -e
printf 'wrong certificate: %s\n' "$WRONG_CERT_OUTPUT"
[[ "$WRONG_CERT_STATUS" -ne 0 && "$WRONG_CERT_OUTPUT" == *"callbacks=0"* ]]
codesign --force --sign - --identifier dev.native.teamschat.credential-prototype "$SERVICE"
codesign --force --sign "$IDENTITY" --identifier dev.native.teamschat "$APP"
set +e
WRONG_SERVICE_OUTPUT="$("$APP/Contents/MacOS/Proof")"
WRONG_SERVICE_STATUS=$?
set -e
printf 'wrong helper certificate: %s\n' "$WRONG_SERVICE_OUTPUT"
[[ "$WRONG_SERVICE_STATUS" -ne 0 && "$WRONG_SERVICE_OUTPUT" == *"callbacks=0"* ]]
codesign --force --sign "$IDENTITY" --identifier dev.native.wrong-helper "$SERVICE"
codesign --force --sign "$IDENTITY" --identifier dev.native.teamschat "$APP"
set +e
WRONG_HELPER_ID_OUTPUT="$("$APP/Contents/MacOS/Proof")"
WRONG_HELPER_ID_STATUS=$?
set -e
printf 'wrong helper identifier: %s\n' "$WRONG_HELPER_ID_OUTPUT"
[[ "$WRONG_HELPER_ID_STATUS" -ne 0 && "$WRONG_HELPER_ID_OUTPUT" == *"callbacks=0"* ]]
