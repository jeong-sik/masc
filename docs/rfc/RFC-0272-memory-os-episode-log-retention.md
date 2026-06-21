# RFC-0272: Memory OS — Episode Log Retention (bounded append for events.jsonl / episodes)

**Status**: Draft
**Date**: 2026-06-21
**Verified against base main**: `357d89114b`
**Builds on**: [RFC-0247](./RFC-0247-memory-os-associative-graph-forgetting-brain.md) (forgetting charter — "a fact's value is the librarian's judgment, not a number"; this RFC extends the forgetting boundary to the episode log, which RFC-0247's facts-only scope leaves unbounded), [RFC-0259](./RFC-0259-memory-os-volatile-claim-grounding-retraction-decay.md) §6 (which routed defect D here), [RFC-0228](./RFC-0228-paged-lane-pull-fact-retention-harness.md) (the recall@depth harness that gates the bound)
**Tracker**: Issue #21789 (Memory OS adversarial audit, defect **D**: events/episodes unbounded append)

## 1. Summary

Every librarian extraction persists to two append-only artifacts:
`<keeper_id>.events.jsonl` (one JSON line per extraction, `keeper_memory_os_io.ml`
— `append_event`) and `episodes/<trace>-gNNNN-tNNNN.json` (one pretty-printed
file per extraction, `append_episode`). **Neither has a retention bound** — only
the fact store is capped (`fact_store_max = 384`). Recall reads both
tail-bounded (`Keeper_memory_os_recall.episode_tail_scan = 32`,
`default_max_episodes = 2`), so the growth is disk-only, but it is unbounded:
`issue_king.events.jsonl` measured ~4× its fact store, and
`read_episode_files_tail` re-reads *every* episode file on each call, an
O(files) recall-time cost that grows without limit.

This RFC adds a typed, hysteresis-bounded retention for the episode log: a
**line-tail cap** on `events.jsonl` and a **file-count cap** on `episodes/`,
each with a high/low watermark mirroring the facts cap and chosen to **exceed
the recall scan window** so recall never starves. This is the RFC-0247
forgetting boundary applied to the episode artifact that RFC-0247 (facts-only)
and RFC-0259 §6 explicitly left unbounded.

## 2. Problem (first-hand evidence)

Verified against base main `357d89114b`:

- `append_event ~keeper_id episode` (`keeper_memory_os_io.ml`) → `append_json`
  → `append_line`: a raw `open_out_gen [Open_append; Open_creat]` with no length
  or count check. One line appended per librarian extraction, forever.
- `append_episode ~keeper_id episode`: `write_file_atomically` to a unique path
  under `episodes/`. One file per extraction, forever. No file-count cap.
- Facts, by contrast, are bounded: `cap_facts` / `merge_and_cap_facts` enforce
  `fact_store_max = 384` with `fact_recall_window = 256` hysteresis.
- Recall is already bounded: `read_episodes_tail` prefers `events.jsonl`
  (`read_events_tail`), falling back to a full `episodes/` scan
  (`read_episode_files_tail`) only when the log is empty; both cap at
  `episode_tail_scan = 32`, injecting `default_max_episodes = 2`.

Net: the disk artifact grows without limit and the per-file fallback scan cost
grows with it, while recall reads a fixed 32-row window. There is no
prompt-correctness impact — this is a disk-hygiene + scan-cost determinism gap,
the episode-log analogue of the facts cap.

## 3. Design

A typed bounded-append primitive mirroring the facts-cap hysteresis, applied to
both artifacts. Constants live beside `fact_recall_window` / `fact_store_max` so
the recall-window coupling is auditable in one place.

- **Watermarks (mirror the facts band):** low-water `keep = 256`, high-water
  `trigger = 256 + 256/2 = 384`. The `/2` hysteresis band keeps the trim off the
  per-turn hot path — a rewrite/unlink fires at most once per
  `(trigger - keep)` appends. `keep = 256` is **8× the recall scan window**
  (`episode_tail_scan = 32`), so even after trimming, recall always finds its 32
  current episodes. This coupling is asserted by a test, not left implicit.
- **events.jsonl — line-tail cap (`cap_events`):** read all lines; if
  `count > trigger`, keep the last `keep` **raw lines** and atomically rewrite.
  Raw-line trim (not parse-filter-reserialize) preserves byte fidelity and the
  malformed-line tolerance `read_lines_tail` already has — a row
  `episode_of_json` cannot parse is not silently dropped, it is tail-trimmed like
  any other. Returns the number dropped (diagnostic, not the mechanism).
- **episodes/ — file-count cap (`cap_episode_files`):** if the `episodes/` file
  count exceeds `trigger`, keep the `keep` most-recent files by
  `compare_episode_recency` (the same order recall uses) and unlink the rest.
  Unlink is best-effort / `ENOENT`-tolerant — a concurrent reader holding a file
  is fine; no new lock is taken around the unlink that could deadlock with
  `with_episode_bundle_lock`.
- **Hysteresis is mandatory**, not optional: without `trigger > keep` the cap
  rewrites on every append (the per-turn hot path), the exact thrash the facts
  cap comment calls out.
- **Wiring:** in the librarian write path (`keeper_librarian_runtime.ml`),
  immediately after `append_episode` / `append_event`, inside the existing
  `with_episode_bundle_lock` so the cap is serialized with writes — the same
  discipline the facts cap uses under the facts lock.

## 4. Verification / harness

- Pure `trim_target ~count ~keep ~trigger` helper → `None` (no-op) below trigger,
  `Some keep` above — the hysteresis decision is unit-testable without IO.
- `cap_events`: append `> trigger` events → trims to `keep`, newest preserved
  (assert the surviving tail's trace_id/generation); append `< trigger` → no-op,
  byte-unchanged; a malformed line is tolerated (raw-line trim does not raise).
- **Recall-non-starvation invariant (load-bearing):** after `cap_events` trims to
  `keep`, `read_episodes_tail ~n:episode_tail_scan` still returns 32 current
  episodes. This test fails if a future edit sets `keep` below the recall window.
- `cap_episode_files`: write `> trigger` files → keep the `keep` recency-newest,
  unlink the rest; idempotent re-run drops 0.
- Gated by the RFC-0228 recall@depth harness: the bound must exceed what
  recall@depth pulls, which the non-starvation test encodes.

## 5. Tradeoffs & alternatives

- **Hysteresis vs hard cap:** a hard cap rewrites/unlinks on every append
  (hot-path thrash). Cost of hysteresis: up to `(trigger - keep) = 128` excess
  lines/files between trims. Accepted — identical to the facts cap.
- **Line-tail vs parse-filter:** a parse-filter-reserialize would silently drop
  rows `episode_of_json` cannot parse (the data-loss class `read_lines_tail`
  avoids). Raw-line tail keeps byte fidelity.
- **Count cap vs TTL:** events/episodes have no per-row `valid_until` (unlike
  facts — the facts `valid_until` path is RFC-0259 P5). A count bound is the
  structural retention decision for an event log; a TTL would be inventing a
  per-row horizon the artifact does not carry.
- **Rejected — bare cap with no RFC:** that is the `cap-as-fix` workaround the
  CLAUDE.md bar rejects. The hysteresis rationale + the recall@depth harness gate
  + the named recall-window coupling are what make this a retention bound, not a
  symptom suppressor.
- **Rejected — telemetry-only:** a "dropped events" counter that does not
  actually trim is `telemetry-as-fix`. The cap rewrites/unlinks; the returned
  count is diagnostic.

## 6. Scope boundaries (what this RFC does NOT do)

- Does **not** change recall (already bounded by `episode_tail_scan`). No
  read-side cap.
- Does **not** add per-claim TTL to events/episodes — they are an event log, not
  claims. The facts `valid_until` path is RFC-0259 P5, separate.
- Does **not** touch the GC module (`keeper_memory_os_gc.ml`, facts-only) —
  conflating two artifact classes in one boundary is rejected.
- Does **not** summarize or derive (no digest / derived store), consistent with
  RFC-0228's "no summarizer process". Pure retention bound.

## 7. Phasing

- **P1 (implementation of this RFC):** `trim_target` + `cap_events` +
  `cap_episode_files` + the constants, wired in the librarian write path, with
  the harness in §4. Single PR, citing this RFC. No env gate — the facts cap is
  an always-on hot-path bound with hysteresis, and this mirrors it.
