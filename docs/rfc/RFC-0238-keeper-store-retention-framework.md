---
rfc: "0238"
title: "Keeper-store retention framework (typed policy over Dated_jsonl, decisions.jsonl first)"
status: Draft
created: 2026-06-15
updated: 2026-06-15
author: vincent
supersedes: []
related: ["RFC-0231"]
---

# RFC-0238 — Keeper-store retention framework

## §1 Problem (evidence-grounded)

Per-keeper durable stores under `keepers_dir` are append-only with no
retention. Measured on the live store (`/Users/dancer/me/.masc`, 2026-06-15):
`<keeper>.decisions.jsonl` reaches 9–10 MB per keeper, **1.4 GB total** across
the fleet. It is written one line per tool execution by
`append_tool_exec_decision_log`
(`lib/keeper/keeper_tools_oas_handler_telemetry.ml:102`) via the flat-file
appender `Keeper_types_support.append_jsonl_line`
(`lib/keeper/keeper_types_support.ml:160`) — no rotation, no partitioning.

The 2026-06-13 merge audit named "Memory OS / external-attention" as the
unbounded-growth surface (F942/F943). Measurement refutes that target: the
Memory OS facts/events stores (`keepers/<id>.facts.jsonl`,
`keepers/<id>.events.jsonl`) and the external-attention store
(`attention/<keeper>.jsonl`) have **zero bytes** on the live host — RFC-0231 is
abandoned (PR #20829 CLOSED) and Discord inbound is not being recorded. The
real grower is `decisions.jsonl`. (Full measurement:
`.tmp/rfc-0238-caller-context.md`.)

Readers of `decisions.jsonl` are already tail-bounded —
`Keeper_accountability.tail_decision_log_lines_or_empty`
(`lib/keeper/keeper_accountability.ml:43`) reads the last 500 KB / 128 lines,
dashboard feeds read bounded slices — so old head entries are safe to drop. What
is missing is a write-side retention mechanism, and there is no common place to
add one: each store would otherwise grow its own ad-hoc rotation (the
`cap/cooldown/dedup/repair` workaround shape CLAUDE.md warns against).

There is a reusable substrate: `Dated_jsonl` (`lib/dated_jsonl/dated_jsonl.mli:75`)
already provides date-partitioned append plus a partition-drop primitive and
bounded readers (`read_recent`, `load_tail_lines`, `read_range`) with a
per-store mutex:

```ocaml
(* lib/dated_jsonl/dated_jsonl.mli — the retention primitive to build on *)
val append : t -> Yojson.Safe.t -> unit   (* :28 date-partitioned append *)
val prune  : t -> days:int -> int         (* :75 drop partitions older than N days *)
```

Retention should be built on this, not reinvented per store.

## §2 Goals / non-goals

Goals:
- One typed retention policy type and one periodic sweep, registered per store.
- Bound `decisions.jsonl` (the live grower) without data-loss for current
  readers.
- Define — without yet wiring — policies for the Memory OS and attention stores
  so they are bounded the day they go live.

Non-goals:
- Reviving RFC-0231's Memory OS integration (those stores stay empty until a
  separate product decision).
- Changing what a decision-log entry contains.
- A distributed/GC'd store; this is local per-keeper JSONL.

## §3 Design

### 3.1 Typed policy

A closed sum type makes each store's retention explicit and exhaustively
matched — no `~force`-style escape hatch, no "unknown store ⇒ keep forever"
default.

```ocaml
type policy =
  | Dated_prune of { keep_days : int }
      (* time-series append logs: decisions, tool-results.
         Stored as Dated_jsonl partitions; prune drops partitions
         older than keep_days. *)
  | Capped_by_score of { max_items : int; half_life_days : float }
      (* semantic memory: Memory OS facts/episodes. Keep the top
         max_items by a recency-decayed score (RFC-0231 forgetting
         curve). Defined-only until the store is live. *)
  | Compact_event_log of { keep_after_days : float }
      (* event-sourced logs: external attention. Fold record/claim/
         resolve/ignore to current state, drop events for items
         terminally resolved/ignored older than keep_after_days.
         Defined-only until the store is live. *)

type store = {
  id : string;                                   (* stable key, e.g. "decisions" *)
  policy : policy;
  base_relative : keeper:string -> string;       (* path under keepers_dir *)
}
```

### 3.2 Engine

```ocaml
val register : store -> unit
val registered : unit -> store list
val run_for_keeper : base_path:string -> keeper:string -> report list
val run_all : base_path:string -> report list
(* report records store id, bytes/entries before & after, partitions/items
   dropped, and any error — never raises; a failing store is logged and
   skipped so one store cannot block the sweep. *)
```

`run_*` dispatches on `policy` with an exhaustive match. `Dated_prune` calls
`Dated_jsonl.prune`. The other two arms are implemented when their store is
wired (§3.4); until then they are `Defined_not_wired` and `run_*` returns a
report saying so rather than silently doing nothing.

### 3.3 Trigger

The sweep runs:
- once at keeper bootstrap (cheap; partitions rarely need pruning), and
- on a daily cadence from the existing keeper heartbeat loop (not a new timer),
  guarded so only one sweep runs per day per keeper.

No on-every-write trigger: pruning is O(partitions), not O(append), so it must
not sit on the hot tool-exec path.

### 3.4 Phase 1 — wire `decisions.jsonl`

1. Migrate the writer: `append_tool_exec_decision_log` appends through a
   `Dated_jsonl.t` rooted at `keepers/<keeper>/decisions/` instead of the flat
   `<keeper>.decisions.jsonl`. One partition per UTC day.
2. Migrate readers: `Keeper_accountability.tail_decision_log_lines_or_empty`
   and the dashboard feeds read via `Dated_jsonl.load_tail_lines` /
   `read_recent` (same bounded semantics they have today).
3. Register `{ id = "decisions"; policy = Dated_prune { keep_days }; … }` with
   `keep_days` from a config knob (`MASC_KEEPER_DECISIONS_KEEP_DAYS`, default
   chosen so a 9 MB/keeper file maps to a small bounded window — see §6).
4. One-time migration of the existing flat file: on first boot, if a legacy
   `<keeper>.decisions.jsonl` exists, fold it into dated partitions (or archive
   it under `_archive/` and start fresh). Behaviour selected by a flag; the
   archive path is the conservative default (no in-place rewrite of 1.4 GB).

Memory OS (`Capped_by_score`) and attention (`Compact_event_log`) are
**registered as defined-not-wired** in Phase 1 — the policy is declared, the
store is not yet emitting data, and `run_*` reports them as inactive.

## §4 Boundary

In scope: the retention policy type, the engine, the decisions.jsonl
writer/reader migration, and the trigger wiring. Out of scope: the content of
decision entries, the Memory OS/attention store implementations, and any change
to `Dated_jsonl` itself (used as-is).

## §5 Validation

- Unit: a temp `Dated_jsonl` seeded with partitions spanning > keep_days, then
  `run_for_keeper`, asserting old partitions are dropped and recent ones kept;
  the report's dropped-count matches. Mutation: setting `keep_days` to a huge
  value must drop nothing (guards an off-by-one that would over-prune).
- Reader-parity: a test that the migrated tail reader returns the same last-N
  lines as the pre-migration flat reader for an equivalent corpus.
- Exhaustiveness: `run_*` matches all three policy arms; adding a fourth policy
  without an arm must fail to compile (closed sum, no catch-all).
- `dune build --root . @check` / `dune build --root .` exit 0.

## §6 Open questions (for review)

- `keep_days` default. A keeper at ~9 MB over its lifetime, partitioned daily,
  suggests retaining ~14–30 days bounds each keeper to low-MB while keeping
  accountability history. Proposed default: 30 days; needs ratification.
- Legacy 1.4 GB: archive-and-start-fresh (default) vs fold-into-partitions. Fold
  preserves full history at the cost of rewriting 1.4 GB once; archive is O(1)
  and keeps the old file readable under `_archive/`.

## §7 Alternatives considered

- **Per-store ad-hoc rotation** (size cap + `.1` rename on each store).
  Rejected: this is the `cap` workaround multiplied across stores; no shared
  trigger, no typed policy, each store reinvents atomic rewrite. The `.jsonl.1`
  artifacts already on disk are exactly this drift.
- **Size-cap the flat file in place** (truncate head when > N MB). Rejected:
  in-place head-truncation of an append-only file is not crash-safe and fights
  the bounded readers; date partitioning + partition-drop is atomic by
  construction.
- **Revive RFC-0231 first.** Rejected: it targets stores with zero live data;
  retention for the real grower should not wait on an abandoned integration.
