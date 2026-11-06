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

Three builds from this branch, measured alternately in one session so host load affects all of them, 2000 rich messages in the timeline:

- `base` at `78431ba`, before the row work
- `opt` at `e365a50`, stable rows only
- `final` at `ee120fe`, stable rows plus the deletion-status fix

Run 1:

| Variant | fps | p50 ms | p95 ms | p99 ms | max ms | long frames | row bodies/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| base | 116.9 | 8.4 | 14.8 | 15.8 | 28.5 | 17.5% | 336 |
| opt | 119.6 | 8.4 | 11.9 | 14.1 | 22.1 | 2.8% | 21 |
| final | 119.6 | 8.4 | 11.4 | 12.6 | 23.2 | 1.3% | 21 |

Run 2:

| Variant | fps | p50 ms | p95 ms | p99 ms | max ms | long frames | row bodies/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| base | 117.5 | 8.4 | 14.8 | 15.7 | 27.0 | 17.8% | 336 |
| opt | 119.2 | 8.4 | 10.7 | 14.6 | 17.0 | 2.8% | 21 |
| final | 118.9 | 8.4 | 12.1 | 14.4 | 22.3 | 4.2% | 21 |

Both scroll rates sit at the 120 Hz display's presentation rate, so fps cannot separate the variants; the frame budget can. Against the baseline, the final build cuts p95 from 14.8 ms to about 11.8 ms and the share of frames over 1.5 refresh periods from about 17.7 percent to about 2.8 percent, and its p99 stays inside a single 60 Hz period (16.7 ms). About 21 distinct rows scroll into view per second and each renders exactly once.

An earlier session ran the same three-way comparison under heavier host load and gave the baseline 79.7-79.9 fps with p95 30.8-31.6 ms and 33-34 percent long frames, while stable rows gave 96.2-99.4 fps with p95 22.6-23.2 ms and 25-29 percent long frames. Absolute values move with host load; the ordering did not.

Row body evaluations for the baseline are about 336/s against roughly 22 distinct row identities per second, so each visible row body ran about fifteen times. The final build runs each row body once.

## What the profile showed

Sampling the fixture process while it scrolled showed the main thread spending about 89 percent of its time in SwiftUI layout, with `TeamsReadDetailView` in 36 percent of those samples and `TeamsMessageRow.body.getter` in 20 percent. Sampling the final build put `TeamsReadDetailView` at about 6 percent and `TeamsMessageRow.body.getter` at about 1 percent of main-thread samples. Counting evaluations confirmed the cause: every visible row body ran about fifteen times while it stayed on screen, because the timeline handed each row new closures on every layout pass. Holding one actions object per message and comparing rows with `Equatable` collapses that to one evaluation per visible row.

## Remaining gaps

- The remaining long frames are single events of 17-28 ms, typically when several new rich rows are realized at once; text layout dominates what is left.
- Host load was uncontrolled and the fixture has one conversation with uniform rich messages; other message shapes, images, windows sizes and scrolling speeds are unmeasured.
- Native frame presentation, GPU time, trackpad-specific scrolling behaviour, other display refresh rates and input latency are not measured here.
- The benchmark scrolls the timeline's scroll view directly rather than synthesising trackpad events, and it measures main-thread tick pacing rather than presented frames.
