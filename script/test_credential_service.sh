#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY_FILE="$HOME/Library/Application Support/TeamsChat/signing-identity"
IFS= read -r IDENTITY < "$IDENTITY_FILE"
[[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]]
cd "$ROOT_DIR"
swift build --product TeamsCredentialService
swift build --product TeamsCredentialBridgeProof
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p .codex/validation
STAGE="$(mktemp -d "$ROOT_DIR/.codex/validation/service-proof.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Proof.app"
SERVICE="$APP/Contents/XPCServices/TeamsCredentialService.xpc"
mkdir -p "$APP/Contents/MacOS" "$SERVICE/Contents/MacOS"
cp "$BIN_DIR/TeamsCredentialService" "$SERVICE/Contents/MacOS/TeamsCredentialService"
cp "$BIN_DIR/TeamsCredentialBridgeProof" "$APP/Contents/MacOS/Proof"
cat > "$SERVICE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.native.teamschat.credential-service</string>
<key>CFBundleExecutable</key><string>TeamsCredentialService</string><key>CFBundlePackageType</key><string>XPC!</string>
<key>TeamsSigningCertificate</key><string>$IDENTITY</string><key>TeamsTestDelaySaveReply</key><true/><key>TeamsCredentialStoreService</key><string>dev.native.teamschat.helper.test.$(uuidgen)</string><key>XPCService</key><dict><key>ServiceType</key><string>Application</string><key>JoinExistingSession</key><true/></dict>
</dict></plist>
PLIST
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.native.teamschat</string><key>CFBundleExecutable</key><string>Proof</string>
<key>CFBundlePackageType</key><string>APPL</string><key>TeamsSigningCertificate</key><string>$IDENTITY</string>
</dict></plist>
PLIST
codesign --force --sign "$IDENTITY" "$SERVICE"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/Proof" --adapter-restart
SUITE="TeamsAdapterProof.$(uuidgen)"
"$APP/Contents/MacOS/Proof" --adapter-process-save "$SUITE"
"$APP/Contents/MacOS/Proof" --adapter-process-load "$SUITE"
"$APP/Contents/MacOS/Proof" --transient-recovery
"$APP/Contents/MacOS/Proof" --clear-failure
"$APP/Contents/MacOS/Proof" --cancel-pull
"$APP/Contents/MacOS/Proof" --lost-reply
SAVE_OUTPUT="$("$APP/Contents/MacOS/Proof")"
printf '%s\n' "$SAVE_OUTPUT"
SAVED_VERSION="${SAVE_OUTPUT##*version=}"
"$APP/Contents/MacOS/Proof" --check-only
"$APP/Contents/MacOS/Proof" --check-only
"$APP/Contents/MacOS/Proof" --stale-version "$SAVED_VERSION"
HELPER_CDHASH_BEFORE="$(codesign -dvvv "$SERVICE" 2>&1 | sed -n 's/^CDHash=//p')"
HELPER_BEFORE="$(shasum -a 256 "$SERVICE/Contents/MacOS/TeamsCredentialService" | awk '{print $1}')"
APP_BEFORE="$(shasum -a 256 "$APP/Contents/MacOS/Proof" | awk '{print $1}')"
swift build --product TeamsCredentialBridgeProof -Xswiftc -DBUILD_TWO
cp "$(swift build --show-bin-path)/TeamsCredentialBridgeProof" "$APP/Contents/MacOS/Proof"
codesign --force --sign "$IDENTITY" "$APP"
APP_AFTER="$(shasum -a 256 "$APP/Contents/MacOS/Proof" | awk '{print $1}')"
HELPER_AFTER="$(shasum -a 256 "$SERVICE/Contents/MacOS/TeamsCredentialService" | awk '{print $1}')"
HELPER_CDHASH_AFTER="$(codesign -dvvv "$SERVICE" 2>&1 | sed -n 's/^CDHash=//p')"
[[ "$APP_BEFORE" != "$APP_AFTER" && "$HELPER_BEFORE" == "$HELPER_AFTER" && "$HELPER_CDHASH_BEFORE" == "$HELPER_CDHASH_AFTER" ]]
printf 'outer binary changed; helper digest and CDHash retained\n'
"$APP/Contents/MacOS/Proof" --load-only
codesign --force --sign "$IDENTITY" --identifier dev.native.wrong "$APP"
if "$APP/Contents/MacOS/Proof"; then echo "wrong client identifier unexpectedly accepted" >&2; exit 1; else echo "wrong client identifier rejected"; fi
codesign --force --sign - --identifier dev.native.teamschat "$APP"
if "$APP/Contents/MacOS/Proof"; then echo "ad-hoc client unexpectedly accepted" >&2; exit 1; else echo "ad-hoc client rejected"; fi
codesign --force --sign - --identifier dev.native.teamschat.credential-service "$SERVICE"
codesign --force --sign "$IDENTITY" --identifier dev.native.teamschat "$APP"
if "$APP/Contents/MacOS/Proof"; then echo "ad-hoc helper unexpectedly accepted" >&2; exit 1; else echo "ad-hoc helper rejected"; fi
codesign --force --sign "$IDENTITY" --identifier dev.native.wrong-helper "$SERVICE"
codesign --force --sign "$IDENTITY" --identifier dev.native.teamschat "$APP"
if "$APP/Contents/MacOS/Proof"; then echo "wrong helper identifier unexpectedly accepted" >&2; exit 1; else echo "wrong helper identifier rejected"; fi
mv "$SERVICE" "$STAGE/missing-service.xpc"
codesign --force --sign "$IDENTITY" --identifier dev.native.teamschat "$APP"
if "$APP/Contents/MacOS/Proof"; then echo "missing helper unexpectedly accepted" >&2; exit 1; else echo "missing helper rejected"; fi
mv "$STAGE/missing-service.xpc" "$SERVICE"
codesign --force --sign "$IDENTITY" --identifier dev.native.teamschat.credential-service "$SERVICE"
printf '\000' >> "$SERVICE/Contents/MacOS/TeamsCredentialService"
if codesign --verify --strict "$SERVICE" >/dev/null 2>&1; then echo "corrupt helper unexpectedly verified" >&2; exit 1; else echo "corrupt helper rejected by signature verification"; fi
