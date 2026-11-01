#!/usr/bin/env bash
set -euo pipefail
SUPPORT="$HOME/Library/Application Support/TeamsChat"
PIN="$SUPPORT/CredentialHelper/v2"
SERVICE="${1:-$PIN/TeamsCredentialService.xpc}"
MANIFEST="$PIN/manifest"
[[ -r "$MANIFEST" && -d "$SERVICE" ]]
IDENTITY="$(sed -n 's/^identity=//p' "$MANIFEST")"
EXPECTED_EXEC="$(sed -n 's/^executable_sha256=//p' "$MANIFEST")"
EXPECTED_PLIST="$(sed -n 's/^plist_sha256=//p' "$MANIFEST")"
EXPECTED_SEAL="$(sed -n 's/^seal_sha256=//p' "$MANIFEST")"
EXPECTED_CDHASH="$(sed -n 's/^cdhash=//p' "$MANIFEST")"
[[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ && "$EXPECTED_EXEC" =~ ^[a-f0-9]{64}$ && "$EXPECTED_PLIST" =~ ^[a-f0-9]{64}$ && "$EXPECTED_SEAL" =~ ^[a-f0-9]{64}$ && "$EXPECTED_CDHASH" =~ ^[a-f0-9]{40}$ ]]
[[ "$(shasum -a 256 "$SERVICE/Contents/MacOS/TeamsCredentialService" | awk '{print $1}')" == "$EXPECTED_EXEC" ]]
[[ "$(shasum -a 256 "$SERVICE/Contents/Info.plist" | awk '{print $1}')" == "$EXPECTED_PLIST" ]]
[[ "$(shasum -a 256 "$SERVICE/Contents/_CodeSignature/CodeResources" | awk '{print $1}')" == "$EXPECTED_SEAL" ]]
[[ "$(codesign -dvvv "$SERVICE" 2>&1 | sed -n 's/^CDHash=//p')" == "$EXPECTED_CDHASH" ]]
EXPECTED_REQUIREMENT="identifier \"dev.native.teamschat.credential-service\" and certificate leaf = H\"$(printf '%s' "$IDENTITY" | tr '[:upper:]' '[:lower:]')\""
[[ "$(codesign -d -r- "$SERVICE" 2>&1 | sed -n 's/^designated => //p')" == "$EXPECTED_REQUIREMENT" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :TeamsCredentialStoreService' "$SERVICE/Contents/Info.plist")" == "dev.native.teamschat.helper.session.v2" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :XPCService:JoinExistingSession' "$SERVICE/Contents/Info.plist")" == "true" ]]
if /usr/libexec/PlistBuddy -c 'Print :TeamsTestDelaySaveReply' "$SERVICE/Contents/Info.plist" >/dev/null 2>&1; then exit 1; fi
codesign --verify --strict "$SERVICE"
