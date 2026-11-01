#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/TeamsChat"
PIN="$SUPPORT/CredentialHelper/v2"
IDENTITY_FILE="$SUPPORT/signing-identity"
IFS= read -r IDENTITY < "$IDENTITY_FILE"
[[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]]
SERVICE="$PIN/TeamsCredentialService.xpc"
MANIFEST="$PIN/manifest"
[[ -r "$MANIFEST" && -d "$SERVICE" ]]
EXPECTED_EXEC="$(sed -n 's/^executable_sha256=//p' "$MANIFEST")"
EXPECTED_PLIST="$(sed -n 's/^plist_sha256=//p' "$MANIFEST")"
EXPECTED_SEAL="$(sed -n 's/^seal_sha256=//p' "$MANIFEST")"
EXPECTED_CDHASH="$(sed -n 's/^cdhash=//p' "$MANIFEST")"
[[ "$(sed -n 's/^identity=//p' "$MANIFEST")" == "$IDENTITY" ]]
[[ "$(shasum -a 256 "$SERVICE/Contents/MacOS/TeamsCredentialService" | awk '{print $1}')" == "$EXPECTED_EXEC" ]]
[[ "$(shasum -a 256 "$SERVICE/Contents/Info.plist" | awk '{print $1}')" == "$EXPECTED_PLIST" ]]
[[ "$(shasum -a 256 "$SERVICE/Contents/_CodeSignature/CodeResources" | awk '{print $1}')" == "$EXPECTED_SEAL" ]]
[[ "$(codesign -dvvv "$SERVICE" 2>&1 | sed -n 's/^CDHash=//p')" == "$EXPECTED_CDHASH" ]]
codesign --verify --strict "$SERVICE"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :TeamsCredentialStoreService' "$SERVICE/Contents/Info.plist")" == "dev.native.teamschat.helper.session.v2" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :XPCService:JoinExistingSession' "$SERVICE/Contents/Info.plist")" == "true" ]]
cd "$ROOT_DIR"
swift build --product TeamsCredentialBridgeProof
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p .codex/validation
STAGE="$(mktemp -d "$ROOT_DIR/.codex/validation/pinned-proof.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Proof.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/XPCServices"
cp -R "$SERVICE" "$APP/Contents/XPCServices/"
cp "$BIN_DIR/TeamsCredentialBridgeProof" "$APP/Contents/MacOS/Proof"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.native.teamschat</string><key>CFBundleExecutable</key><string>Proof</string>
<key>CFBundlePackageType</key><string>APPL</string><key>TeamsSigningCertificate</key><string>$IDENTITY</string>
</dict></plist>
PLIST
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
[[ "$(shasum -a 256 "$APP/Contents/XPCServices/TeamsCredentialService.xpc/Contents/MacOS/TeamsCredentialService" | awk '{print $1}')" == "$EXPECTED_EXEC" ]]
"$APP/Contents/MacOS/Proof" --adapter
"$APP/Contents/MacOS/Proof" --adapter
