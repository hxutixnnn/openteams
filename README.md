<p align="center">
  <img src="assets/icon/OpenTeams-source.png" width="112" height="112" alt="OpenTeams O and people icon">
</p>

# OpenTeams

An open-source, native macOS client for Microsoft Teams chat. Built with Swift and SwiftUI, with macOS 27 navigation and controls, a rich-text composer, and local conversation history.

[Getting started](#getting-started) · [Contributing](#contributing) · [Issues](https://github.com/hxutixnnn/OpenTeams/issues) · [MIT license](LICENSE)

**Early preview.** OpenTeams is an independent project, unaffiliated with Microsoft. It uses private Teams web services, which may change without notice. Organization policies may prevent sign-in or use. It is not a replacement for every Microsoft Teams feature.

## What you can do

- Read chats, browse folders and unread conversations, and search downloaded messages or explicitly search Teams.
- Compose formatted messages with mentions, links, lists and replies. Save drafts locally per account and conversation.
- React to messages and edit or delete supported messages, with recovery controls for uncertain server outcomes.
- Inspect participants and shared files/links; preview supported images and PDFs.
- Read previously downloaded conversations while disconnected.
- Explore a fictional **Sample Workspace** without a Microsoft account.

Calls, meetings, file uploads, Office document previews and closed-app push notifications are not implemented. Account, tenant and service compatibility varies. Full visual/accessibility acceptance is still in progress; a successful build is not a claim of complete coverage. Fresh-account/MFA sign-in, tenant policies, guest/consumer accounts and long-running session recovery are not fully verified. Rich sending/editing and SharePoint previews have local verification only.

| Sample Workspace — Light | Sample Workspace — Dark |
| --- | --- |
| ![Fictional conversations in Light appearance](assets/screenshots/mock-workspace.png) | ![Fictional conversations in Dark appearance](assets/screenshots/mock-workspace-dark.png) |

These screenshots contain fictional data and illustrate the sample workspace; they may lag the current UI.

## Requirements

- macOS **27 or later**.
- Swift **6.4 or later** and the **macOS 27 SDK**, provided by compatible Xcode or Command Line Tools.
- Git and internet access to fetch source and dependencies.
- A Microsoft Teams work or school account for live conversations. No account is needed for the sample workspace.

This project currently documents building locally. Local builds use your own signing identity and are not notarized distribution binaries.

## Getting started

Clone the public repository over HTTPS:

```sh
git clone https://github.com/hxutixnnn/OpenTeams.git
cd OpenTeams
python3 script/check_build_environment.py
```

For a **fresh installation**, create a local signing identity and pin the credential helper once:

```sh
python3 script/setup_local_signing.py
./script/pin_credential_helper.sh
```

If you already use OpenTeams, keep the existing signing identity and pinned helper. Replacing them can break access to saved credentials; do not repeat setup as a troubleshooting shortcut.

Build, sign and install:

```sh
./script/build_and_run.sh --build-only
./script/install.sh
```

The installer verifies signatures and the pinned helper, installs `/Applications/OpenTeams.app`, and launches it. A previous matching installation is retained for recovery. Your sign-in and local data are retained.

Open **Settings → Sample Workspace** to try fictional conversations. For live chat, choose **Connect to Teams** and sign in through the Microsoft-owned sign-in page. OpenTeams does not require an app registration or copying tokens from browser developer tools.

## Everyday use

| Shortcut | Action |
| --- | --- |
| ⌘F | Find in the current conversation |
| ⌘L | Focus the composer |
| ⌘Return | Send |
| ⌥⌘I | Toggle conversation details |
| ⌘R | Refresh |
| ⌘, | Settings |

Return-to-send preferences for Teams and the sample workspace are separate. When a send, edit or creation has an uncertain outcome, use its status/reconciliation action before attempting it again; automatic retries could create duplicates.

**Updates:** choose **OpenTeams → Check for Updates…**. Installation requires confirmation and builds the selected merged revision locally using the same toolchain and signing identity. Update checks and installation are manual. See [development and update details](DEVELOPMENT.md#in-app-updates).

## Privacy and account data

Saved credentials are held in macOS Keychain behind a signed XPC helper. Downloaded chats and drafts are stored locally under `~/Library/Application Support/TeamsChat/`, separated by account. File permissions are restricted, but the local cache is **not encrypted**.

Live chat traffic goes to Microsoft services. Update checks contact GitHub; builds fetch source and dependencies. There is no analytics or crash-reporting service. Never put tokens, sign-in captures, real message content or tenant identifiers in issues or screenshots.

The legacy bundle identifier and `TeamsChat` storage directory are intentionally retained for existing installations. Report security issues privately through GitHub security advisories; exclude credentials and private message content.

## Contributing

Bug reports, documentation improvements and focused pull requests are welcome. Start with an issue for larger changes so the intended behavior can be agreed before implementation.

For a useful bug report, include:

1. macOS version, installed source revision (shown in Updates), and whether the issue occurs in the sample workspace.
2. The smallest reproduction, expected result and actual result.
3. A redacted screenshot or log, and relevant window size/appearance for UI defects.

Read [AGENTS.md](AGENTS.md) and the [development guide](DEVELOPMENT.md). Keep changes focused, preserve account isolation and uncertain-operation safeguards, and use fictional data for tests. Changes go through pull requests; do not bypass protected `main`.

Build and run the isolated E2E workflows:

```sh
swift build --jobs 4 --product OpenTeams
python3 script/test_performance_e2e.py --skip-build
python3 script/test_fixture_deletion_e2e.py --skip-build
python3 script/test_fixture_delivery_e2e.py --skip-build
```

These workflows verify core behavior. Native rendering, scrolling, keyboard/IME, focus and accessibility require separate app-level checks; see [native E2E journeys](Tests/E2E/APP.md). Report unrun checks explicitly. Do not send real messages or delete user data to reproduce a test case.

## Project layout

- `Sources/TeamsChat` — SwiftUI views, AppKit editor integration, application lifecycle and updater.
- `Sources/TeamsCore` — service clients, state, message rendering models, cache and drafts.
- `Sources/TeamsCredential*` — credential helper and IPC boundary.
- `Tests/E2E` — isolated workflows and native acceptance journeys.
- `script` — environment checks, signing, build, installation and fixture preparation.
- `assets` — app icon and fictional screenshots.

## License

OpenTeams is available under the [MIT License](LICENSE), including the permissions to use, modify and redistribute the software subject to its notice requirements. Copyright notices are retained in `LICENSE`. Third-party dependencies retain their own licenses.

Microsoft and Microsoft Teams are trademarks of Microsoft Corporation. The OpenTeams icon is project artwork, not a Microsoft logo. The software is provided without warranty; see the license for the full terms.
