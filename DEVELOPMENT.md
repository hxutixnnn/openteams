# Development and updates

See the [README](README.md) for installation, everyday use and contribution requirements. These notes describe the current build and isolated verification workflows.

## Building and testing

Build a single product without launching anything:

```sh
swift build --jobs 4 --product OpenTeams
```

The signing script produces `dist/OpenTeams.app`. Use `./script/build_and_run.sh --build-only` to sign without launching, `--debug` to launch under lldb, `--logs` to stream process logs, or `--telemetry` to stream local app logs. `TEAMSCHAT_SIGNING_IDENTITY` selects the existing signing identity. Run `./script/build_icon.sh` after changing the source icon to regenerate the bundled bitmap `.icns`; that bitmap does not supply adaptive Light/Dark appearances.

Run the isolated end-to-end workflows:

```sh
python3 script/test_performance_e2e.py --skip-build
python3 script/test_fixture_deletion_e2e.py --skip-build
python3 script/test_fixture_delivery_e2e.py --skip-build
./script/test_credential_prototype.sh
./script/test_credential_service.sh
./script/test_pinned_helper.sh
```

The app-core E2E workflows build fictional chat histories, account-scoped temporary storage, cross-process draft recovery, and intercepted send requests. They never launch the main GUI bundle against real account data, and they measure completed store operations — not native frame rates or input-to-display latency. See [Tests/E2E/PERFORMANCE.md](Tests/E2E/PERFORMANCE.md) for paired measurements and [Tests/E2E/APP.md](Tests/E2E/APP.md) for the native app journeys.

To prepare an isolated debug fixture bundle for manual UI testing:

```sh
python3 script/prepare_app_e2e.py --cached-history-count 2000
```

For the merged timeline optimization and its measured limits, see [scroll benchmark evidence](Tests/E2E/SCROLL-PERFORMANCE.md). The benchmark measures main-thread timer pacing, not displayed frames or input latency. It launches an isolated native fixture; coordinate GUI ownership before running it.

## Architecture

`Package.swift` builds one app, one core library, and a small credential stack.

| Target | Kind | Role |
| --- | --- | --- |
| `TeamsChat` | executable | SwiftUI app shell: window, sidebar, detail, inspector, composer, settings, notification routing, refresh coordination |
| `TeamsCore` | library | Models, fixture store, Teams web clients, reader store, read cache, rich drafts, presentation, refresh policy |
| `TeamsCredentialIPC` | library | XPC protocol shared by app and credential helper |
| `TeamsCredentialBridge` | library | Client side of the credential helper connection |
| `TeamsCredentialPersistence` | library | Keychain-backed session credential storage |
| `TeamsCredentialService` | executable | Pinned XPC credential helper bundled into the app |
| `TeamsCredentialPrototype`, `TeamsCredentialBridgeProof` | executables | Standalone tools that exercise and verify the credential path |

Source layout:

```
Sources/TeamsChat/         App/ · Services/ · Support/ · Views/
Sources/TeamsCore/         Models/ · Services/ · Fixtures/
Sources/TeamsCredential*/  IPC · bridge · persistence · helper
Tests/TeamsCoreTests/      store, cache, and presentation tests
Tests/TeamsChatTests/      reader, reaction, timeline, and deletion tests
Tests/E2E/                 app-core E2E workflows and performance evidence
script/                    build, sign, install, and E2E runners
assets/                    icon sources and screenshots
```

Only external dependency: [SwiftSoup](https://github.com/scinfu/SwiftSoup) `2.9.6` (pinned exactly), used for parsing Teams message HTML.

## In-app updates

Choose **OpenTeams → Check for Updates…**, or **Settings → Updates**, to check the latest merged `main` revision. **Install Update…** asks before building, installing and restarting. The signed app must be installed at `/Applications/OpenTeams.app`. Checks are manual; OpenTeams does not download or install updates automatically.

This updater is for locally signed installations. It requires macOS 27, the macOS 27 SDK and Swift 6.4 or later (from compatible Command Line Tools or Xcode), internet access, and the existing local signing identity and pinned credential helper. It fetches the exact selected commit from this repository into a private update directory, builds and signs it on this Mac, verifies it, and uses the same guarded installer as a manual update. It never changes the development checkout. The app remains open during the build; installation stops it and restarts the installed copy. The previous app is retained under `/Applications/.OpenTeams-install.*/previous.app`; a failed final signature verification restores it. Updates retain the existing sign-in, helper and local chat data. An unsuccessful build leaves the installed app in place.

The update window shows progress and failures and can reveal the log. Job state and source/build logs are retained in `~/Library/Application Support/TeamsChat/Updates`. Closing the update window or quitting the app does not cancel a running update. Only one update can install at a time. A failed or interrupted update can be retried with a new check. The build revision is embedded in `OpenTeamsSourceRevision`; this is the comparison used by the updater rather than the unchanged marketing version.

Updater verification:

```sh
python3 script/test_updater_e2e.py
swiftc -parse-as-library -swift-version 6 Sources/TeamsChat/Support/TeamsAppUpdater.swift Tests/E2E/AppUpdateCheck.swift -o /tmp/openteams-update-check
/tmp/openteams-update-check
```

The process E2E uses temporary local Git repositories and signed miniature bundles with the existing helper. It exercises download, build, revision/signature rejection, installation/backup, failed-install rollback, concurrency and invalid-input status. Its installer destination and process-stop hook are isolated, and it does not replace or stop the installed app. The second workflow checks GitHub over the network for both an older revision and a current revision without installing. Native menu/window interactions and the real restart are separate acceptance checks.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `A stable signing identity is required` | Run `python3 script/setup_local_signing.py`, then retry the build. |
| `The pinned credential helper is missing or invalid` | Do not regenerate it blindly. Re-run `./script/pin_credential_helper.sh` only on a fresh installation; otherwise migrate credentials deliberately. |
| Sign-in window closes or the connection is refused | Your organization may block third-party clients. Verify the same account works in a browser on this machine. |
| Messages fail after a network drop | Reconnect and refresh with `⌘ R`. The app does not retry an ambiguous send automatically. |
