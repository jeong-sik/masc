# Correct uncovered Build wall time for nested stage timers

The native 2/30/300-owner captures contain nested timers such as
`overview.rows` inside `surface.content`. Adding both durations and subtracting
that sum from Build counts their overlap twice. The old residual can therefore
understate work outside the recorded windows, even when it remains positive.

`Stage_samples.build_residuals` now groups immutable recorded windows by Build,
validates their containment, sorts endpoints and subtracts their interval union
using int64 nanoseconds. The report formatter uses this numeric result. A Build
without exact timing, with aggregate-only or invalid stage windows, or affected
by a stage omission has no residual. Absence means unknown, never zero.
Notes and outside-Build stages do not contribute. Per-stage totals retain their
inclusive meaning and must not be added as an exclusive CPU decomposition.

This computation happens when constructing the exit report. It adds no mutable
UI field, persistent index, per-frame cache or disabled-timing work. It repairs
measurement correctness; **it does not make a frame faster**.

## Verification and measured discrepancy

The exact copied product module/interface compiled with OCaml 5.5.1 and strict
warnings, without Dune or a whole-project build. Final v3 ran the existing focused
opt-in suite (16 tests including the new numeric coverage cases), plus the
existing default-off suite (one test), all successfully. Numeric checks include
nested/crossing/duplicate/touching/zero-length windows, signed-clock bounds,
invalid/aggregate-only windows and cap omissions. The independent cell-occupancy
oracle covers all 8,281 ordered pairs of integer intervals on a 12-cell Build.
No new TUI screen-text, layout, row-order or PTY assertion tests were added.

`replay.ml` feeds the actual retained native frame/stage records into the copied
product module. `compare.py` independently partitions all interval endpoints and
checks each segment's membership, rather than repeating the product merge loop.
All 287 Build results match that oracle exactly:

| Keeper owners | Builds checked | Old sum model underreported | Largest discrepancy |
| ---: | ---: | ---: | ---: |
| 2 | 85 | 50 | 87,625 ns |
| 30 | 93 | 51 | 73,332 ns |
| 300 | 109 | 61 | 57,416 ns |

These 162 discrepancies compare exact reconstructed old sum/clamp arithmetic
with exact union arithmetic, before report text rounding. They do not compare
the old floating-point implementation or its rounded output strings. They are corrections
to earlier captures, **not 162 faster frames or a new runtime execution**. Build
wall and stage wall remain inclusive elapsed measurements, including observation,
scheduling/GC and uninstrumented work; they do not establish exclusive CPU.
The [native-owner bundle](../native-tui-owners/README.md) retains the inputs and
their physical-display, input-state, scripted-provider and cross-clock limits.
[Mtime's clock interface](https://erratique.ch/software/mtime/doc/Mtime_clock/index.html)
defines elapsed time relative to the process; no Python clock origin is inferred.

The first v1 standalone invocation mistakenly omitted the test stanza's required
`MASC_TUI_FRAME_TIMING`: 15 tests passed and the existing callback-path test failed
because timing was disabled. That capture and its helper remain unchanged. V2
matched the stanza and passed all 16; v3 added the requested same-frame/later-frame
cap check and repeated the exact module run, replay and default-off verification.
This is a runner correction, not a product-code workaround. No CI, installed
binary, full regression, native GUI paint or 100 us target claim follows.

## Reproduction

Historical helpers and receipts preserve their original addresses. With OCaml
5.5.1 and `yojson`, `mtime.clock.os`, `unix`, `alcotest` installed, copy the current
module pair and two test files into a new ignored output directory, then run
there (absolute source paths locate this checkout):

```sh
ocamlfind ocamlopt -w +4+32+69 -warn-error +a \
  -package yojson,mtime.clock.os,unix,alcotest -linkpkg \
  masc_tui_frame_timing.mli masc_tui_frame_timing.ml test_tui_frame_timing.ml -o test.exe
MASC_TUI_FRAME_TIMING=test-tui-frame-timing.report ./test.exe --color=never
ocamlfind ocamlopt -w +4+32+69 -warn-error +a \
  -package yojson,mtime.clock.os,unix,alcotest -linkpkg \
  masc_tui_frame_timing.cmx test_tui_frame_timing_default_off.ml -o default-off.exe
MASC_TUI_FRAME_TIMING= ./default-off.exe --color=never
```

Copy the retained `frame-union-v3/replay.ml` into that new directory to compile
against the same module. Pass a retained `owners-*/tui-observer/frame-timing.txt`
to the replay executable. Python 3.11+ is required for the historical comparison
helper. Use fresh outputs; retained capture hashes do not certify edited source.
The next performance investigation remains fleet-wide reading/model joins,
server release-tail latency and actual input/scroll application, within the full
TUI/DAW/Draw, I/O, peer/broadcast and Add-on objective.
