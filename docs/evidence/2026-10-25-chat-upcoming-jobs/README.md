# Keeper chat upcoming Jobs

Prepared from main `66bb461692dbb788d64fb935b8b401f1e0df5ede`.

The chat's F9 control folds or expands upcoming Jobs for its exact Keeper.
The default is one next-Job row. Scheduled/Due rows are ordered by parsed epoch;
Running and terminal occurrences are excluded. Unknown status/time, failed reads,
retained observations and capped pages remain distinguishable. Proximity colors
are display-only and have matching text. The existing per-Keeper Automation
request ledger, workspace admission and async loader are reused. A pending read
is shared, including while reading older chat messages.

## Checks executed

- Direct standalone compilation of the production CSI module interface
  and implementation with the current `test_tui_csi.ml`: **19 tests PASS**, including
  F9 legacy/Kitty/modifier decoding. Alcotest reported 0.005 seconds. This is a
  protocol test, not a native TUI interaction or a screen-layout test.
- The actual `chat_schedule_entries` and `chat_schedule_proximity` functions were
  compiled/executed with production `Time_codec`/Ptime and explicit minimal
  row/status ports. Exact target precedence, numeric time ordering across RFC3339
  offsets, terminal/running exclusion, unknown preservation and the five proximity
  bands passed. The test did not execute the complete decoder or TUI state module.
- OCaml 5.5.1 parse-only: eight changed ML/MLI files PASS; whitespace check PASS.
- The read-response fixture adds chat A while the roster selects B, and refuses
  B's off-target error. It was read and parsed, **not executed**.
- Independent adversarial source review found and repaired missing explicit key
  interface exports and a small-terminal input-admission regression. Re-review
  found no remaining P0-P2 in the bounded feature delta.

The standalone protocol suite can be repeated without a Dune build:

```sh
work=$(mktemp -d)
cp bin/masc_tui_csi.ml bin/masc_tui_csi.mli test/test_tui_csi.ml "$work/"
(cd "$work" && ocamlfind ocamlc -package alcotest -linkpkg \
  masc_tui_csi.mli masc_tui_csi.ml test_tui_csi.ml -o check && ./check)
rm -rf "$work"
```

## Unverified

No project-wide typecheck, Dune/native TUI build, CI, installation, merged-source
runtime, visible terminal interaction or screenshot was produced. The installed
TUI is not claimed to contain this feature. A source/component result is not
execution or visual evidence of the new screen. No TUI wording/layout/PTY
assertion was added; the new assertions concern protocol inputs and read ownership.
