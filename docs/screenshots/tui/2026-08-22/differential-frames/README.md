# TUI differential-frame runtime evidence

This bundle measures PR #29336 through a real `ttyd` WebSocket and headless
Chromium. It compares the source parent with the exact candidate, then forces a
same-geometry full redraw in the candidate as a control.

## Provenance

- Capture started: `2026-08-22T13:36:18.340Z`
- Capture finished: `2026-08-22T13:43:01.359Z`
- Baseline source: `aa7bde9e3959f8c8de48d58b663bda957ef59ffe`
- Candidate source: `faa46e798e01c8bc14070376cbd680282d100917`
- Clean capture-driver head: `c985c39caf0efb443c1a3ced13ee601bef3cfc59`
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
| Baseline | `173736262ec12a28e603c096eb0ed70d8ce0fcb7a27c5bc27d06a761d8083b80` | `dbdee5f9b3c56ef37d018b300c44e8d06d28d70906579965414d76c78adc4706` | 39,805,792 | 197,162.010 ms |
| Candidate | `37f6f18eaaf4d146b19b30822d24c40797f6c405e89021fae7e208babf731834` | `25bb396ab7b9f6c9cd6afec464c96c7ef00b4fe8ae421ea6bae0ffe3d2c1f299` | 39,814,272 | 180,074.719 ms |

Reproduction command:

```sh
python3 scripts/capture-tui-differential-frames.py \
  --expected-head c985c39caf0efb443c1a3ced13ee601bef3cfc59 \
  --baseline-commit aa7bde9e3959f8c8de48d58b663bda957ef59ffe \
  --candidate-commit faa46e798e01c8bc14070376cbd680282d100917 \
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
- Median first server message: baseline `4.330` ms; candidate `4.165` ms
- Median last server message: baseline `4.541` ms; candidate `4.165` ms
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
arrived at `16.923` ms and `17.350` ms after the signal.

No HTTP request occurred during either measurement window set. The fixture saw
zero chat POSTs, zero operation GETs, and zero errors; its eight records were
the initial static loads outside the measured windows.

## Screenshot parity

- [Baseline after `ABABA`](01-baseline-ababa.png)
- [Candidate after `ABABA`](02-candidate-ababa.png)
- [Candidate after same-geometry forced redraw](03-candidate-sigwinch-full-redraw.png)

All three screenshots are `834x480`, show the same visible text, input row, and
cursor at zero-based `(11, 24)`, and share these DOM hashes:

- Visible text SHA-256: `c44797044928b9c2ffab75a1f090365d27861de878351342664f2c7c8db8c70c`
- Input row SHA-256: `abeb3f3a3c91004288d2c62f3cfa46cc4d7ebfebd516469a3cf8dd5498a27095`

The candidate incremental and forced-redraw PNGs are byte-for-byte identical.
Across the separate baseline and candidate Chromium contexts, 1.460082% of
pixels differ by at most one 8-bit channel value; the mean absolute channel
delta is `0.013874734`. This is the recorded antialiasing-level raster
difference, while the terminal DOM, text, input row, geometry, and cursor are
exactly equal.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `01-baseline-ababa.png` | 14,683 | `a18b577e27735626f361c85045804ef1e5e3967c74b66f5e450b7d04a3e4957e` |
| `02-candidate-ababa.png` | 14,751 | `2fe0b601ff81c3505874eb941089f796b3ca5524b552f184fe85a76a127f781c` |
| `03-candidate-sigwinch-full-redraw.png` | 14,751 | `2fe0b601ff81c3505874eb941089f796b3ca5524b552f184fe85a76a127f781c` |

## Raw evidence

[The raw JSON](evidence.json) preserves every measured binary WebSocket
application message as base64 plus its byte count, SHA-256, direction, and
relative timestamp. It also contains build logs and hashes, fixture records,
terminal states, screenshot records, comparison calculations, and all
fail-closed verification flags.

- `evidence.json` SHA-256: `22f8df86b12fa8c45a04ac6f0712494ba4d7406e1817ab696fef79a0c8fface8`
- Status: `passed`
- Verification flags: all `true`
