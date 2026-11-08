# Native delivery guard checks

Prepare an isolated fictional fixture after building the current source:

```sh
python3 script/prepare_app_e2e.py --skip-build --name 'OpenTeams Delivery Guards' --cached-history-count 200 --allow-fictional-send --hold-reply --hold-send
```

The returned manifest names the unique bundle, root, revision and hashes. Launch that bundle with the native app driver. Do not use the installed production account for these checks.

1. Select Fictional project, enter a fictional draft, and choose Prepare fixture reply. This targets uncached message 50.
2. Send once. Preparing reply must retain the draft and disable Send. `send-observation.json` must show `replyRequests: 1`, `attempts: 0`.
3. With the editor focused, press Command-Return again. `send-input.json` must gain an entry with `eligible: false, preparing: true`; this proves the input reached the production send action. Counts must stay unchanged.
4. Release reply. Sending must retain the draft and disable Send. Counts must be `attempts: 1, accepted: 0` while held.
5. Press Command-Return repeatedly in the editor. Each delivered input must append an ineligible `sending: true` entry. Independently read the transport observation: attempts must remain one. A successful input tool response alone is insufficient.
6. Release send. The accepted message must appear once, and the original draft/reply must clear. Counts must become `attempts: 1, accepted: 1`.
7. Enter a new fictional draft and choose Disconnect fixture. Command-Return must append an ineligible `connected: false` entry, retain the draft, and leave counts unchanged. Send must be disabled with a reconnect explanation.
8. Repeat with a fresh fixture adding `--closed-chat`. The selected project must explain that sending is closed and disable Send. Command-Return must append an ineligible `closed: true` entry; the initialized observation must remain `attempts: 0, accepted: 0`, and the draft must remain.

Run `python3 script/test_fixture_delivery_e2e.py --skip-build` for the production store/transport/cache workflow, including held reply/send duplicates, disconnected/closed guards and all three uncertain-delivery outcomes. This script is not native input or visual proof.

Copy manifests, observations and screenshots to the report directory before cleanup. Quit every fixture, verify its process/window is gone, then remove only the bundles and temporary roots created for this run. End the native driver session. Keep report evidence; do not retain disposable apps for a later run.
