# TUI differential-frame runtime evidence

This bundle measures PR #29336 through a real `ttyd` WebSocket and headless
Chromium. It compares the source parent with the exact candidate, then forces a
same-geometry full redraw in the candidate as a control.

## Provenance

- Capture started: `2026-08-22T13:54:02.587Z`
- Capture finished: `2026-08-22T14:05:17.125Z`
- Baseline source: `b340647df5977a8333851cc05ad757caf2b3f391`
- Candidate source: `0af1b4263d55ca135c7c8e4f02cba3b10eec49eb`
- Clean capture-driver head: `8d91b44b0bf7fde496380fb343c0a979c52a983c`
- Driver script SHA-256: `da79de5cd8c2f103c3fc314221e532792fa91fc0fc3e27d97c5791d69836e299`
- Shared support script SHA-256: `2fbaa2c8c70c5f1328140ad5e399f108cf85ecaa32e9a3358a8e3f6f61fd2451`
- `ttyd`: `1.7.7-unknown`
- Playwright: `1.59.0`
- Chromium: `147.0.7727.15`
- Pillow: `12.1.1`

Both executables were built sequentially in fresh external build directories
from immutable `git archive` snapshots. The driver, support script, and both
executables were rehashed after capture.

| Build | Archive SHA-256 | Executable SHA-256 | Bytes | Duration |
| --- | --- | --- | ---: | ---: |
| Baseline | `a5bc09b388ffbacf334f39226419896e2a3d0609632b8fb60e3d5d930f2e114f` | `33a9fef31922fa557432e9dc43aa133aeeed0676ed48396189a8d3d8b3d59f00` | 39,805,456 | 286,355.172 ms |
| Candidate | `727b9ff359caff80b572078fe58d1bd7a65ce07726b20091a71cd285095ab77d` | `8c72f90fd1079580d4372286efaac82fe83ea48bb220e6a15191a975764613dc` | 39,813,952 | 349,037.842 ms |

Reproduction command:

```sh
python3 scripts/capture-tui-differential-frames.py \
  --expected-head 8d91b44b0bf7fde496380fb343c0a979c52a983c \
  --baseline-commit b340647df5977a8333851cc05ad757caf2b3f391 \
  --candidate-commit 0af1b4263d55ca135c7c8e4f02cba3b10eec49eb \
  --target-pr 29336
```

## Measurement boundary

The byte counts are Playwright-observed WebSocket application-message payload
bytes. Each server message includes the one-byte `ttyd` message type (`0` for
terminal output). The counts exclude WebSocket framing, compression effects,
TLS, TCP, IP, and link-layer overhead. A WebSocket application message is not
claimed to be one PTY write or one network frame.

Both binaries used the same fixture server and port, terminal geometry
(`99x30`), DOM renderer, font settings, and final input. After the terminal was
quiet, the harness typed `A`, `B`, `A`, `B`, `A` as five separately measured
windows. It then sent `SIGWINCH` directly to the candidate's exact TUI child
process without changing geometry, exercising the presenter's forced-full-frame
path.

## Measured result

| Key window | Baseline messages / bytes | Candidate messages / bytes |
| --- | ---: | ---: |
| `A` | 5 / 4,102 | 1 / 173 |
| `AB` | 5 / 4,102 | 1 / 173 |
| `ABA` | 5 / 4,103 | 1 / 174 |
| `ABAB` | 5 / 4,103 | 1 / 174 |
| `ABABA` | 5 / 4,103 | 1 / 174 |
| **Five-window total** | **20,513** | **868** |

- Aggregate baseline/candidate ratio: **23.632x**
- Candidate application-payload reduction: **95.769%**
- Median application payload: baseline `4,103` bytes; candidate `174` bytes
- Median first server message: baseline `8.496` ms; candidate `9.702` ms
- Median last server message: baseline `9.387` ms; candidate `9.702` ms
- Every baseline key window contained `CSI 2J`; no candidate incremental window
  contained it.
- Every candidate incremental window addressed only row 25.
- Each input produced exactly one binary browser-to-server `ttyd` input message
  with the expected payload.

The local timing values describe this capture only; the primary deterministic
performance result is the application-payload byte reduction.

The same-geometry candidate control produced 5 server messages and `4,611`
application-payload bytes (`4,606` terminal bytes after removing the five
`ttyd` type bytes). It contained `CSI 2J`, addressed all rows 1 through 30, and
settled without any browser input message. Its first and last server messages
arrived at `29.967` ms and `30.713` ms after the signal.

No HTTP request occurred during either measurement window set. The fixture saw
zero chat POSTs, zero operation GETs, and zero errors; its eight records were
the initial static loads outside the measured windows.

## Screenshot parity

- [Baseline after `ABABA`](01-baseline-ababa.png)
- [Candidate after `ABABA`](02-candidate-ababa.png)
- [Candidate after same-geometry forced redraw](03-candidate-sigwinch-full-redraw.png)

All three screenshots are `834x480`, show the same visible text, input row, and
cursor at zero-based `(11, 24)`, and share these DOM hashes:

- Visible text SHA-256: `536e45d756db70a13188418878cef3d00eca8db0a2a4f6c59aa495a015917ebe`
- Input row SHA-256: `abeb3f3a3c91004288d2c62f3cfa46cc4d7ebfebd516469a3cf8dd5498a27095`

The candidate incremental and forced-redraw PNGs are byte-for-byte identical.
Across the separate baseline and candidate Chromium contexts, 1.459333% of
pixels differ by at most one 8-bit channel value; the mean absolute channel
delta is `0.01386724`. This is the recorded antialiasing-level raster
difference, while the terminal DOM, text, input row, geometry, and cursor are
exactly equal.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `01-baseline-ababa.png` | 14,576 | `62fa805476dd6780684ca1ea10f3d7b4bcf079fe6a1be299c312c4963918b4f8` |
| `02-candidate-ababa.png` | 14,623 | `27f2ef0f6284db88b027ddab0e252368bd32674e8d89ad321e01c05a09e96220` |
| `03-candidate-sigwinch-full-redraw.png` | 14,623 | `27f2ef0f6284db88b027ddab0e252368bd32674e8d89ad321e01c05a09e96220` |

## Raw evidence

[The raw JSON](evidence.json) preserves every measured binary WebSocket
application message as base64 plus its byte count, SHA-256, direction, and
relative timestamp. It also contains build logs and hashes, fixture records,
terminal states, screenshot records, comparison calculations, and all
fail-closed verification flags.

- `evidence.json` SHA-256: `da5637e43a10da1c49ae06c1bfda373639e0362c04b375ff2123095e3be25f70`
- Status: `passed`
- Verification flags: all `true`
