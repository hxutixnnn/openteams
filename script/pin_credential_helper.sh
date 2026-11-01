#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/TeamsChat"
IDENTITY_FILE="$SUPPORT/signing-identity"
IFS= read -r IDENTITY < "$IDENTITY_FILE"
[[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]]
DEST="$SUPPORT/CredentialHelper/v2"
if [[ -e "$DEST" ]]; then echo "Helper version already exists; refusing to replace it." >&2; exit 1; fi
cd "$ROOT_DIR"
swift build --product TeamsCredentialService
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p "$SUPPORT/CredentialHelper"
chmod 700 "$SUPPORT/CredentialHelper"
STAGE="$(mktemp -d "$SUPPORT/CredentialHelper/.v2-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
SERVICE="$STAGE/TeamsCredentialService.xpc"
mkdir -p "$SERVICE/Contents/MacOS"
cp "$BIN_DIR/TeamsCredentialService" "$SERVICE/Contents/MacOS/TeamsCredentialService"
cat > "$SERVICE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.native.teamschat.credential-service</string>
<key>CFBundleExecutable</key><string>TeamsCredentialService</string><key>CFBundlePackageType</key><string>XPC!</string>
<key>TeamsSigningCertificate</key><string>$IDENTITY</string>
<key>TeamsCredentialStoreService</key><string>dev.native.teamschat.helper.session.v2</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string><key>JoinExistingSession</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign "$IDENTITY" "$SERVICE"
codesign --verify --strict "$SERVICE"
EXPECTED_REQUIREMENT="identifier \"dev.native.teamschat.credential-service\" and certificate leaf = H\"$(printf '%s' "$IDENTITY" | tr '[:upper:]' '[:lower:]')\""
ACTUAL_REQUIREMENT="$(codesign -d -r- "$SERVICE" 2>&1 | sed -n 's/^designated => //p')"
[[ "$ACTUAL_REQUIREMENT" == "$EXPECTED_REQUIREMENT" ]]
EXEC_HASH="$(shasum -a 256 "$SERVICE/Contents/MacOS/TeamsCredentialService" | awk '{print $1}')"
PLIST_HASH="$(shasum -a 256 "$SERVICE/Contents/Info.plist" | awk '{print $1}')"
SEAL_HASH="$(shasum -a 256 "$SERVICE/Contents/_CodeSignature/CodeResources" | awk '{print $1}')"
CDHASH="$(codesign -dvvv "$SERVICE" 2>&1 | sed -n 's/^CDHash=//p')"
cat > "$STAGE/manifest" <<MANIFEST
format=1
identity=$IDENTITY
executable_sha256=$EXEC_HASH
plist_sha256=$PLIST_HASH
seal_sha256=$SEAL_HASH
cdhash=$CDHASH
MANIFEST
chmod 600 "$STAGE/manifest"
mv "$STAGE" "$DEST"
trap - EXIT
printf 'Pinned credential helper v2; CDHash %s\n' "$CDHASH"
