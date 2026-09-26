# Render agenda errors only when the panel displays them

## Observed path

The verified native artifact `10909422480` at
`c7bdc04f78e3b6c09abae94e28852b37f8274da7` was sampled for five seconds
while acknowledging 24,006 synthetic inputs with 250 retained Channels bindings.
The sample contains `agenda -> escape_invisible` / `sanitize_terminal_text`
under `agenda_chrome_rows` from `finish_surface`, `surface_body_rows`, and
Keeper detail rendering. `sample-excerpts.txt` retains original sample line
numbers; `source-observation.json` verifies the matching source against this
PR's main base. The agenda implementation/interface and frame primitives are
byte-identical as whole files; the agenda/body-budget and sanitizer regions
match exactly within the two larger files that differ elsewhere.

The [full diagnostic receipts](https://github.com/jeong-sik/masc/tree/c7d67a745f40d1669413e6a5c50349bc2e61f5d4/docs/evidence/tui-footer-parse-once-2026-09-27)
include artifact identity, the full native sample, runner, scenario, 24,006
observations, stdout/stderr, frame timing, redaction map and file hashes.
This directory reuses that sample; it does not claim a new profiling run.
Its earlier README describes the separate footer optimization. Both paths are
visible in the same baseline sample.

Sampling perturbs execution. This is evidence that the path ran, not its
per-frame cost, dominance, allocation volume, or a before/after speedup.
The profiling wrapper's child CPU includes the sampler, ps and pgrep;
the inherited raw resource scope is not a TUI-only CPU measurement.

## Change and contract

State projection carries failed-read reasons unchanged. The agenda overlay
sanitizes each failure immediately before measuring and fitting its row.
Ordinary surface-height and strip queries no longer sanitize error text that
only the overlay can display. The existing row-presence predicate, schedule
filtering/order, approval visibility and scroll/body-height owner are unchanged.
There is no shared cache or invalidation state.

Both state transport failures and a failed schedule-store snapshot use this
boundary. Focused regressions cover all three failed sections, Korean text,
ESC/newline, invalid UTF-8, an invisible Unicode scalar, literal escape text,
narrow widths, unchanged body budget, snapshot-error precedence, and the
missing-reason fallback. Existing agenda tests retain strip/row agreement.

## Verification limits

The changed OCaml files pass syntax parsing and the diff whitespace check.
Compiled tests remain subject to CI. The candidate PTY comparison is recorded
below. No local OCaml build was run. No general latency gain, live-runtime
deployment, physical-display measurement, or 0.1ms completion is claimed.

## First comparison attempt

[Comparison 36256591061](failed-comparison-36256591061/README.md) failed at
baseline repetition 3 startup, before that session measured any input. Four
completed sessions are retained without a full aggregate. A single retry
36257181447 uses the same artifacts and observer; its data remains separate.

## Completed comparison retry

[Retry 36257181447](comparison-retry-36257181447/README.md) completed all three
pairs: 600 acknowledged frames and six draft-preservation checks. Overall
median/p95 were 0.4552295/1.047834 ms for baseline and 0.432229/0.838542 ms for
candidate. Info median and maxima were higher; every candidate observation
still exceeded 0.1 ms. The full receipts, source scope and mixed results are
retained separately from the failed attempt.
