#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
DEVELOPER_ROOT="$(xcode-select -p)"
SWIFT_BINARY="$(xcrun --find swiftc)"
TESTING_PLUGIN="$(dirname "$SWIFT_BINARY")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ "$DEVELOPER_ROOT" == */CommandLineTools && -f "$TESTING_PLUGIN" ]]; then
  exec swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN" "$@"
fi
exec swift test --disable-xctest "$@"
