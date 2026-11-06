# Chat timeline scroll frame pacing

Measured on 6 November 2026 on this Mac (120 Hz display, uncontrolled host load, load average about 8). These are application-core fixture measurements of the main-thread frame budget while the chat timeline scrolls; they are not a claim about native frame presentation, GPU time or input-to-display latency.

## Method

`script/scroll_benchmark.py` prepares an isolated fixture bundle with `--cached-history-count 2000`, runs the real `TeamsReadContentView` against fictional messages, and scrolls the timeline's scroll view at 1400 pt/s for eight seconds after a two-second warm-up. A main-run loop timer at the display refresh rate drives the scroll and samples the interval between its own ticks; ticks that arrive late are frames the main thread could not service, so the interval distribution is the frame budget the scroll consumes.

The benchmark marks user scroll intent before recording, so the timeline does not fight the measurement with its automatic bottom follow. The app terminates itself and writes `scroll-benchmark.json` into the fixture root; the script prints that report.

Reported fields: frame cadence (`framesPerSecond`), interval percentiles, share of intervals above 1.5 refresh periods (`longFrameShare`), row body evaluations per second (`rowBodiesPerSecond`) and distinct row identities per second (`distinctRowIDsPerSecond`). When those last two match, each row renders once; a larger ratio is repeated work on rows that did not change.

```sh
swift build --jobs 4 --product OpenTeams
python3 script/scroll_benchmark.py --skip-build --mode bounds --label my-check
```

## Paired results

Both builds are worktrees of this branch, measured alternately in one session so that host load affects both. Baseline is `78431ba`; the change is `e365a50`. Three pairs, 2000 rich messages in the timeline.

| Variant | fps | p50 ms | p95 ms | p99 ms | max ms | long frames | row bodies/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline 1 | 79.7 | 8.5 | 30.8 | 31.7 | 46.1 | 33% | 377 |
| Baseline 2 | 79.9 | 8.4 | 31.6 | 32.8 | 42.0 | 34% | 377 |
| Baseline 3 | 79.7 | 8.4 | 31.1 | 32.5 | 43.6 | 34% | 378 |
| Stable rows 1 | 96.2 | 8.4 | 23.2 | 24.6 | 29.5 | 29% | 63 |
| Stable rows 2 | 99.4 | 8.5 | 22.6 | 24.4 | 31.5 | 25% | 63 |
| Stable rows 3 | 98.1 | 8.5 | 22.7 | 23.6 | 27.5 | 26% | 63 |

Medians: baseline 79.7 fps with p95 31.1 ms; stable rows 98.1 fps with p95 22.7 ms. Row body evaluations fall from 377/s to 63/s while about 22 distinct rows scroll into view per second, so the repeated work on unchanged rows is removed.

## What the profile showed

Sampling the fixture process while it scrolled showed the main thread spending about 89 percent of its time in SwiftUI layout, with `TeamsReadDetailView` in 36 percent of those samples and `TeamsMessageRow.body.getter` in 20 percent. Counting evaluations confirmed the cause: every visible row body ran about fifteen times while it stayed on screen, because the timeline handed each row new closures on every layout pass. Holding one actions object per message and comparing rows with `Equatable` collapses that to one evaluation per visible row.

## Remaining gaps

- A quarter to a third of frames still take 22-32 ms, so the p99 interval is above one 60 Hz period even though the median is 8.4 ms. Realizing several new rich rows at once, dominated by text layout, is the remaining cost.
- Host load was uncontrolled and the fixture has one conversation with uniform rich messages; other message shapes, images, windows sizes and scrolling speeds are unmeasured.
- Native frame presentation, GPU time, trackpad-specific scrolling behaviour, other display refresh rates and input latency are not measured here.
- The benchmark scrolls the timeline's scroll view directly rather than synthesising trackpad events, and it measures main-thread tick pacing rather than presented frames.
