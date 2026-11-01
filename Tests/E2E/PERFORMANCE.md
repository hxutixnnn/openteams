# Interaction and draft persistence performance

Measured on 1 November 2026 against `4f52a74f90dad5e2af0ef63c4fa8545e30c829c4`, with Swift 6.4.2 on arm64 macOS, debug (`-Onone`). These are the implementation owner's application-core fixture measurements; independent QA approval of the final PR commit remains required. Host load was uncontrolled.

Message row actions reuse the existing rendering snapshot's ID positions, with validation and the original search fallback. Delete availability reads the existing deletion metadata predicate without parsing message HTML, files or reactions. Rich-draft persistence caches unchanged encoded documents and suppresses identical successful snapshots. Saves remain synchronous and atomic; changed saves still write the complete JSON file. JSON fields, the 2 MB cap, owner-only permissions and pending-send persistence before HTTP remain unchanged.

## Row-action measurements

Five alternating process pairs, each with two discarded warmups and ten samples per action workload. Each sample checks delete/edit/reaction availability for the last 30 rows of a cached history. Baseline includes the same composer patch on both sides to isolate the reader changes. Values are medians of five process medians; brackets show their range. Each process also checks full rendered equality, persisted raw message order, offline restore, cold/warm history open, same-ID deletion, append, pagination, deletion rejection, restart and account switching. No real network requests are forwarded.

| Workload | Baseline ms | Candidate ms |
| --- | ---: | ---: |
| 200 plain messages, 30 rows | 4.616 [4.477–4.767] | 0.113 [0.108–0.118] |
| 2000 plain messages, 30 rows | 47.867 [47.094–48.547] | 0.109 [0.108–0.114] |
| 200 rich messages, 30 rows | 16.036 [15.627–18.056] | 0.108 [0.108–0.115] |
| 2000 rich messages, 30 rows | 62.218 [61.260–65.704] | 0.109 [0.109–0.110] |

Process medians use the average of the two middle samples for even sample counts. These results were recalculated from the original raw samples after QA identified that the original reporters selected the upper middle sample. Raw logs remain unchanged; `interaction-results.json` and the per-process values in `composer-results.json` contain the corrected statistics. Pooled draft medians below are unchanged.

Cold store loading shows no clear improvement. For 2,000 plain messages it was 20.620 [20.085–22.234] → 22.091 [21.026–24.236] ms; for 2,000 rich messages, 783.315 [778.153–864.172] → 785.090 [760.679–820.845] ms. Cached-list restore and warm conversation calls also show no clear improvement. Fixtures have one chat and a warm filesystem cache: these are cold store loads, not cold disk or app startup. The index adds one ID-to-offset entry per loaded message. Rich-history parsing remains synchronous.

## Draft measurements

Five alternating baseline/candidate processes, 20 measured publications per workload per process after three warmups. Each call immediately reads and decodes its saved file outside the timing interval, checks exact content and permissions, and counts atomic replacements by inode. The setter returns after persistence completes. No deferred queue or debounce is introduced. Values are medians of all 100 measured calls; brackets show the full call range. Rich documents contain eight list items, a mention with fixed identity, links, a quote, formatting and Unicode. Plain text is 50 UTF-8 bytes per fixture; rich text is 1,028 bytes. Saved rich-state sizes are 6,222 / 121,896 / 609,096 bytes for 1 / 20 / 100 drafts.

| Workload | Baseline ms | Candidate ms | Replacements per 100 calls |
| --- | ---: | ---: | ---: |
| 1 plain drafts, edit | 0.389 [0.302–0.990] | 0.391 [0.308–0.545] | 100 → 100 |
| 20 plain drafts, edit | 0.395 [0.308–0.619] | 0.408 [0.314–0.645] | 100 → 100 |
| 100 plain drafts, edit | 0.540 [0.377–0.925] | 0.544 [0.438–0.802] | 100 → 100 |
| 100 plain drafts, identical | 0.534 [0.411–0.815] | 0.012 [0.011–0.025] | 100 → 0 |
| 1 rich drafts, edit | 0.639 [0.487–0.972] | 0.629 [0.484–0.941] | 100 → 100 |
| 20 rich drafts, edit | 3.082 [2.790–3.928] | 0.829 [0.676–1.406] | 100 → 100 |
| 100 rich drafts, edit | 13.691 [12.984–14.684] | 1.567 [1.281–2.493] | 100 → 100 |
| 100 rich drafts, identical | 13.738 [12.991–15.480] | 0.068 [0.054–0.183] | 100 → 0 |

Changed plain-text saves show no material improvement, with a small median increase. Changed rich saves retain the same total bytes written; savings come from eliminating repeated encoding. Identical publications eliminate both encoding and disk writes after a successful save. Snapshot caches reset on account changes and persistence failures; identical publications still update revisions and cancel preparation. The caches retain encoded rich members plus the last successful value snapshot.

## Reproduction and validation

Run `python3 script/test_performance_e2e.py` from the repository root for supplemental core workflows and benchmarks. Despite its historical filename, this runner does not provide app-level E2E coverage. It directly builds OpenTeams, compiles the standalone fixtures against TeamsCore and SwiftSoup, and runs them sequentially. It never invokes the app packaging/launch script or Swift unit tests. `--skip-build` uses an existing debug build. Use `--scenario LoadingInteractions` or `--scenario ComposerWorkload` to collect an individual workload on each comparison revision. Alternate process order across five pairs and keep build and profiling work outside timed runs. The fixture executables and their temporary account storage are removed on normal completion. See [APP.md](APP.md) for native app E2E preparation and regression journeys.

- `ComposerPersistence.swift`: eight cross-component workflows covering duplicate saves, preparation cancellation, format-only changes, JSON escaping/schema, rich-to-plain removal, account A/B/A, exact 2 MB boundary, failed-write retry, pre-HTTP pending-state durability, uncertainty/reconciliation, in-flight edits and account switches. Seven child-process recoveries verify saved content through the public restore API. All HTTP is intercepted by a fictional transport.
- `ComposerWorkload.swift`: twelve plain/rich × 1/20/100 draft × edit/identical workloads, immediate disk readback, replacement counts, restricted permissions and fresh-store recovery.
- `LoadingInteractions.swift`: four 200/2,000 plain/rich history workflows plus 56 deletion-marker combinations, cache recovery, append/prepend, pending-deletion stages and account reset. It emits separate cached-list, cold/warm load and row-action samples.

The historical composer unit tests ran before the E2E-only rule was introduced. They are not part of this PR and were not run after that rule. The standalone process-level core workflows do not replace native app E2E verification.

## Limits and QA gate

No native first-content, frame duration, p95/p99 frame time, FPS, scrolling, scroll-anchor/bottom-follow, keyboard/selection/IME, accessibility, release-build or live-service performance result is claimed. A separate debug-only performance fixture now avoids normal demo drafts, cache, account credentials and activation; native functional outcomes must be recorded separately against its exact build. The earlier non-isolated GUI fixtures were not launched. The selected Command Line Tools cannot locate xctrace. Native performance verification needs an authorized screen/instrumentation route.

Independent QA must verify the final PR head, build and E2E outcomes, repeat paired comparisons without concurrent builds, inspect JSON compatibility/error/send behavior and determine whether these limits allow approval. A changed head requires renewed QA approval. Merging is reserved for MausBot after explicit QA approval of that exact commit.
