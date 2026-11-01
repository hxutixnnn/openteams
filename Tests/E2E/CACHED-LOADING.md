# Cached-conversation loading

This change moves initial cached-message conversion from MainActor to a private serial actor. It publishes the complete history in one MainActor transaction, after validating account generation and cancellation. A concurrent refresh that has already installed history wins; the prepared cold result cannot replace it. Changed participant metadata uses the existing synchronous render path. Warm history, online refresh, paging, edits, reactions, deletion and reconciliation retain their existing paths. The worker checks cancellation before each message and creates no per-message tasks. Cache files and account paths are unchanged.

## Supplemental core evidence

Run `python3 script/test_performance_e2e.py --scenario CachedConversationLoading` and `python3 script/test_performance_e2e.py --skip-build --scenario CachedLoadWorkflows`. These are application-core workflows, not native E2E. They use temporary on-disk account caches and fictional intercepted transport. The timing workload asserts complete rendered-value equality, preserved disk history/paging tokens, zero HTTP requests and warm-cache reuse for 200/2,000 plain/rich messages. The concurrency workload exercises cancellation/retry, account switching during conversion, two concurrent conversations, racing online refresh, same-ID deletion, append/prepend and persisted results with zero HTTP mutation requests.

The DEBUG callback reports cache-read/decode elapsed time, conversion execution time and synchronous MainActor publication time. Cache elapsed time includes the actor hop/queue, file I/O and JSON decoding. Conversion excludes worker queue time. Publication includes reconciliation and snapshot/array installation; it excludes SwiftUI layout/drawing. Total load time is measured through completion of the offline public load operation and includes all hops and queueing. MainActor conversion/publication spans measure those specific synchronous regions; they are not a whole-process trace, native frame metric or first-visible-frame measurement. No private content or account identifiers are logged by these spans. The callback and clocks are excluded from release builds.

## Paired debug measurements

Five alternating process pairs compared base `0a7a6fb` with only DEBUG timing hooks against this change, using identical workload source and disk fixtures. The initial exploratory run is excluded. Build/host: Swift 6.4.2, arm64, macOS 27.2 SDK, `-Onone`; host load was uncontrolled. Every process passed its assertions. These timings concern completed offline public store operations, not native rendering.

| History | Total load before → after (ms) | Conversion before → after (ms) | Cache read/decode before → after (ms) | Measured main spans before → after (ms) |
| --- | --- | --- | --- | --- |
| 200 plain | 3.038 → 2.808 | 0.356 → 0.405 | 2.362 → 2.194 | 0.544 → 0.063 |
| 2,000 plain | 21.628 → 20.583 | 3.240 → 3.201 | 17.346 → 17.342 | 4.489 → 0.011 |
| 200 rich | 84.093 → 83.837 | 81.659 → 81.429 | 2.261 → 2.313 | 81.800 → 0.018 |
| 2,000 rich | 782.972 → 768.400 | 761.817 → 748.260 | 20.149 → 20.219 | 763.046 → 0.019 |

Values are conventional medians of five samples. The [raw records, ranges, inputs and summaries](Results/cached-loading.json) retain all 40 records and ten exit codes. For 2,000 rich messages, total duration ranges were 774.188–794.539 ms before and 765.147–782.060 ms after. The change removes conversion from MainActor; the small overlapping total-time difference is not a claimed loading-speed improvement. Warm offline loads remained below 0.1 ms in this fixture. Baseline conversion ran on the main thread; candidate conversion reported a non-main thread for every sample. Measured main spans sum conversion (when main) and publication; uninstrumented MainActor setup, scheduling, layout and drawing are excluded. Index construction is included in baseline publication and candidate worker conversion. Publication includes any reconciliation work triggered by the particular fixture; these timing fixtures have no pending send.

To reproduce, build base `0a7a6fb` in an isolated checkout after applying [the instrumentation-only patch](Results/cached-loading-baseline.patch), then compile this checkout's `CachedConversationLoading.swift` against those debug TeamsCore/SwiftSoup products. Build and run the same workload against this head. Alternate baseline/candidate process order; do not time builds or run competing benchmarks. Do not apply the baseline patch to the candidate. No PR #2 row-action/composer benchmark was repeated.

## Native E2E preparation

Run `python3 script/prepare_app_e2e.py --cached-history-count 2000` in the exact candidate checkout. It builds and signs a separate temporary app without launching, installing, stopping or replacing any app. Keep `fixture.json` and the bundle at its printed root; the manifest records the final commit, all source hashes and binary hash. The default preparation without this argument still produces the PR #2 fixture. Use separate roots for this scenario and APP.md's context-only reaction journey: the large cached fixture intentionally includes message 50.

The large fixture seeds 2,000 fictional rich messages into each of two conversations in each fictional account, only if that saved history is empty. It keeps existing drafts and history across fixture restarts. Each cached body includes its account name. The ordinary intercepted recent refresh replaces messages 81–100 using the existing fixture transport; all other cached messages retain the rich seeded bodies. There is no network fallback; send remains rejected. This fixture is for isolation, responsiveness and timeline acceptance, not live Teams behavior.

## Native acceptance awaiting a permitted route

Use the mounted native tools and the exact manifested bundle. No shell-driven UI, foreground fallback or operation on the old fixture is allowed. Do not retry the previously focus-changing Delete confirmation without the person's foreground agreement. No native step below has been run by the implementation owner for this change.

1. Launch the prepared 2,000-message fixture. Verify Account A / Fictional project shows the cached history in ascending order, rich blocks, Unicode and message 2000 with `fixture-a` in its body. Confirm final saved history has 2,000 unique IDs, including both endpoints. Record native loading-to-content behavior separately from the core timings.
2. Type a rich draft in the production editor. Switch to Fictional planning and back. Verify the draft, message ordering, last-message bottom position and absence of an unexpected jump. Type during the first load of the second conversation; record whether input remains responsive, without inferring latency from eventual success.
3. Switch conversations quickly while cold loading; then switch Account B/A during loading. No A row or draft may appear in B, and no previous conversation's result may replace the selected conversation. Inspect cached message 2000's account suffix and each actual composer. Repeat warm switches; all rows/actions and drafts must remain correct.
4. Scroll upward, capture a visible row's position, load older history, and compare the same anchor. Scroll to the bottom, refresh, and verify bottom following and row actions retain their target. Check Reply and open/cancel Edit on a recent own message. Reaction/deletion acceptance remains the existing APP.md production UI journey in a fresh default fixture, with the required permitted route for modal handling.
5. Quit only this new fixture through its own Quit Fixture button, relaunch the same bundle and verify rich cached content, account isolation and actual editor drafts survive. Record process/window IDs, native snapshots and saved JSON. A refused or focus-changing action is blocked evidence, not a pass.

Independent QA must review the exact final head and approve it before merge. Native FPS/hitches, startup/time to usable content, actual input latency/IME, accessibility, release runtime performance and live services remain unmeasured. Reducing synchronous MainActor work is the scope of this PR; total conversion work has not been eliminated.
