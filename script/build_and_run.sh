#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="OpenTeams"
BUNDLE_ID="dev.native.teamschat"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--build-only) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
SIGNING_IDENTITY="${TEAMSCHAT_SIGNING_IDENTITY:-}"
IDENTITY_FILE="$HOME/Library/Application Support/TeamsChat/signing-identity"
if [[ -z "$SIGNING_IDENTITY" && -r "$IDENTITY_FILE" ]]; then
  IFS= read -r SIGNING_IDENTITY < "$IDENTITY_FILE"
fi
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
  echo "A stable signing identity is required. Run python3 script/setup_local_signing.py." >&2
  exit 1
fi
HELPER_PIN="$HOME/Library/Application Support/TeamsChat/CredentialHelper/v2"
if [[ "$(sed -n 's/^identity=//p' "$HELPER_PIN/manifest" 2>/dev/null)" != "$SIGNING_IDENTITY" ]] || ! "$ROOT_DIR/script/verify_credential_helper.sh"; then
  echo "The pinned credential helper is missing or invalid; do not regenerate it automatically." >&2
  exit 1
fi
swift build --product "$APP_NAME"
BUILD_DIR="$(swift build --show-bin-path)"
mkdir -p "$ROOT_DIR/dist"
STAGE_DIR="$(mktemp -d "$ROOT_DIR/dist/.openteams-stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGED_APP="$STAGE_DIR/$APP_NAME.app"
APP_CONTENTS="$STAGED_APP/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Frameworks" "$APP_CONTENTS/Resources" "$APP_CONTENTS/XPCServices"
cp -R "$HELPER_PIN/TeamsCredentialService.xpc" "$APP_CONTENTS/XPCServices/"
"$ROOT_DIR/script/verify_credential_helper.sh" "$APP_CONTENTS/XPCServices/TeamsCredentialService.xpc"
cp "$ROOT_DIR/assets/icon/OpenTeams.icns" "$APP_CONTENTS/Resources/OpenTeams.icns"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
chmod +x "$APP_BINARY"
rm -rf "$APP_CONTENTS/Frameworks/MSAL.framework"
rm -f "$APP_CONTENTS/Resources/Graph.json"

cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>TeamsSigningCertificate</key><string>$SIGNING_IDENTITY</string>
  <key>CFBundleIconFile</key><string>OpenTeams.icns</string>
  <key>CFBundleName</key><string>OpenTeams</string>
  <key>CFBundleDisplayName</key><string>OpenTeams</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"
"$ROOT_DIR/script/verify_credential_helper.sh" "$APP_CONTENTS/XPCServices/TeamsCredentialService.xpc"
python3 "$ROOT_DIR/script/app_processes.py" stop
if [[ -e "$APP_BUNDLE" ]]; then mv "$APP_BUNDLE" "$STAGE_DIR/previous.app"; fi
if ! mv "$STAGED_APP" "$APP_BUNDLE"; then
  if [[ -e "$STAGE_DIR/previous.app" ]]; then mv "$STAGE_DIR/previous.app" "$APP_BUNDLE"; fi
  exit 1
fi
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
case "$MODE" in
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    python3 "$ROOT_DIR/script/app_processes.py" verify-staged
    echo "Built and launched $APP_BUNDLE"
    ;;
  --build-only) echo "Built $APP_BUNDLE" ;;
esac
