# Native app E2E: performance regression journeys

These scenarios run the OpenTeams app and its production conversation views and rich editor. The standalone Swift programs beside this document are supplemental core workflows and benchmarks, not app-level E2E tests.

## Prepare and launch

Run `python3 script/prepare_app_e2e.py`. It builds the debug product directly, copies it into a new temporary bundle with a unique identifier, ad-hoc signs that copy and prints its absolute path and storage root. It does not launch, install, stop or replace any app, use the normal signing identity or package a credential helper. Keep the printed root for restart checks; running preparation again creates a different fixture.

Launch that exact bundle through the mounted native computer tools with background delivery. If the app launcher requires an installed app, ask the mounted launcher to open the exact bundle URL with Finder; do not install it or launch it through a shell. Inspect its window before interacting. The fixture skips explicit startup activation and notification registration, uses an accessory app policy and disables account settings. Initial app objects use no demo-drafts file or normal read-cache path. The displayed fixture uses only intercepted fictional HTTP and disables media clients. Its two conversations share the same IDs across fictional accounts to expose account-isolation failures. Its stored drafts and read cache live below the printed temporary root. Missing or invalid fixture metadata displays an error instead of the normal app.

Use the mounted native tools for every UI interaction, with current window/element handles and background delivery. A refused background operation is a verification gap; do not substitute shell-driven UI automation or foreground input. Preserve snapshots and exact step outcomes outside the repository. Do not infer FPS or input latency from successful interactions.

## E2E-1: rich draft, conversation switch and process recovery

1. Confirm the fixture header shows `fixture-a` and `Ready`, and `Fictional project` is selected.
2. In `Message composer`, enter `Fictional recovery Xin chào 👋`. Reveal formatting, toggle Bold, and append ` Bold tail`. Insert two new paragraphs containing `First item` and `Second item`, apply Bulleted list to the final paragraph, then insert Ada Example through the Mention menu. Record the rendered editor and exact text. The saved document must contain plain and bold runs, a paragraph, a bullet-list item and the mention identity.
3. Select `Fictional planning`. Its composer must be empty. Enter `Planning draft`. Return to `Fictional project`; verify the original rich text, formatting and mention. Read the JSON below `ReadCache/Compose` to confirm matching persisted blocks/runs/mention identity and mode 0600. No fixture control may set these drafts directly.
4. Click `Quit Fixture`. Verify this fixture process/window closed. Relaunch the same bundle, select `Fictional project`, and verify the native editor restores identical text, bold/list formatting and mention. Verify the planning draft also restores. Compare saved rich JSON before and after restart.
5. Click `Account B`; the same conversation IDs must have empty drafts. Type `Account B only` in its actual editor. Click `Account A`; the original A rich draft must return. Switch B/A again and verify separation, including after another fixture restart.

## E2E-2: row actions after refresh and paging

1. In Account A / Fictional project, confirm message 100 is visible. Use its production context menu: Reply must populate a reply preview; Cancel reply must remove it. Edit Message must open the production editor with that message; cancel without saving. Delete Message must be enabled for this own message.
2. Click `Append and refresh`. Message 101 must appear through the normal reader refresh path. Repeat Reply and open/cancel Edit Message on message 101. Confirm the composer draft survives the refresh and edit cancellation.
3. Scroll to `Load Older Messages` and press it. Messages 61–80 must prepend in order. Verify message 80 can Reply and open/cancel Edit Message. Record the visible anchor before/after paging; verify it is retained. Return to the bottom and verify actions on message 101 still target 101.
4. Delete message 101 using the production confirmation only when the screen route allows foreground modal behavior. Native confirmation can activate the fixture even when invoked through background accessibility actions; this was observed in the implementation owner's run. If activation occurs unexpectedly, stop the screen route immediately and record this step as blocked. When permitted, the fictional transport accepts the request and returns a deletion marker. Verify the deleted row no longer offers Reply/Edit/Delete actions. Confirm neighboring message 100 still has its own correct actions and the draft is retained.

## Evidence and limits

Record the commit and source hashes, bundle binary hash, temporary root, process/window IDs, actual editor text and persisted rich JSON, and per-step passed/failed/blocked status. Restart means terminating and relaunching this same fixture process, not constructing another store in a test executable. The supplied fixture deliberately rejects unsupported requests, including sending and reactions; this journey checks reply/edit/delete paths. Existing intercepted core workflows separately cover send uncertainty and recovery.

Manual app E2E outcomes are distinct from performance benchmarks. Native FPS/hitch tracing, startup timings, rapid typing/IME, selection, accessibility and live-service behavior require their own evidence. If a step cannot be completed with the approved background route, report the exact step as blocked and withhold any claim that the full journey passed. Independent QA must approve the final PR commit before merge.
