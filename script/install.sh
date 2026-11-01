#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/dist/OpenTeams.app"
DEST="/Applications/OpenTeams.app"
HELPER="Contents/XPCServices/TeamsCredentialService.xpc"
PLIST="Contents/Info.plist"
BUNDLE_ID="dev.native.teamschat"
identity_file="$HOME/Library/Application Support/TeamsChat/CredentialHelper/v2/manifest"
[[ -d "$SOURCE" && ! -L "$SOURCE" ]] || { echo "Build dist/OpenTeams.app first with ./script/build_and_run.sh --build-only." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/$PLIST")" == "$BUNDLE_ID" ]]
identity="$(sed -n 's/^identity=//p' "$identity_file")"
[[ "$identity" =~ ^[A-Fa-f0-9]{40}$ ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :TeamsSigningCertificate' "$SOURCE/$PLIST")" == "$identity" ]]
expected="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$(printf '%s' "$identity" | tr '[:upper:]' '[:lower:]')\""
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
move_exclusive() {
  /usr/bin/python3 - "$1" "$2" <<'PYCODE'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
libc.renamex_np.restype = ctypes.c_int
if libc.renamex_np(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), 4) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), sys.argv[2])
PYCODE
}
validate() {
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/$PLIST")" == "$BUNDLE_ID" ]] || return 1
  [[ "$(requirement "$1")" == "$expected" ]] || return 1
  codesign --verify --strict "$1" || return 1
  "$ROOT_DIR/script/verify_credential_helper.sh" "$1/$HELPER" || return 1
}
validate "$SOURCE"
if [[ -e "$DEST" || -L "$DEST" ]]; then
  [[ -d "$DEST" && ! -L "$DEST" ]] || { echo "Refusing to replace a non-app or symlink at $DEST." >&2; exit 1; }
  validate "$DEST" || { echo "Refusing to replace an app with a different identity or helper." >&2; exit 1; }
fi
STAGE="$(mktemp -d /Applications/.OpenTeams-install.XXXXXX)"
cleanup() { if [[ ! -e "$STAGE/previous.app" ]]; then rm -rf "$STAGE"; fi; }
trap cleanup EXIT
/usr/bin/ditto "$SOURCE" "$STAGE/OpenTeams.app"
validate "$STAGE/OpenTeams.app"
python3 "$ROOT_DIR/script/app_processes.py" stop
if [[ -e "$DEST" || -L "$DEST" ]]; then
  [[ -d "$DEST" && ! -L "$DEST" ]] && validate "$DEST" || { echo "Destination changed during installation; stopped." >&2; exit 1; }
  move_exclusive "$DEST" "$STAGE/previous.app"
fi
if ! move_exclusive "$STAGE/OpenTeams.app" "$DEST"; then
  if [[ -e "$STAGE/previous.app" ]]; then move_exclusive "$STAGE/previous.app" "$DEST" || echo "Previous app remains at $STAGE/previous.app" >&2; fi
  exit 1
fi
validate "$DEST"
if [[ -e "$STAGE/previous.app" ]]; then echo "Previous app retained at $STAGE/previous.app"; fi
/usr/bin/open -n "$DEST"
printf 'Installed and launched %s\n' "$DEST"
