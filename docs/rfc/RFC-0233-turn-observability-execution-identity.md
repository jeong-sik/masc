---
rfc: "0233"
title: "Typed turn observability: TurnRecord prompt-block provenance + canonical tool execution identity"
status: Draft
created: 2026-06-12
updated: 2026-06-12
author: vincent
supersedes: []
superseded_by: null
related: ["0225", "0230", "0231"]
implementation_prs: []
---

# RFC-0233: TurnRecord + canonical execution identity

Status: Draft · One tool execution must have one identity across every
store and every view · A turn's assembled prompt must be recorded as
typed blocks so consecutive turns are diffable.
Drafted by: Claude (Fable 5), from the 2026-06-12 keeper pipeline
diagnosis session (issues #20907–#20910).

> Anchors marked **(verified)** were read against `origin/main`
> (`589f8b560`) or live runtime stores on 2026-06-12.

---

## §1 Problem

### §1.1 One execution, three stores, three id vocabularies

A single `keeper_memory_search` call by keeper `sangsu` produced, in the
same second:

| Store | Record shape | Identity carried |
|---|---|---|
| `trajectories/<keeper>/<trace>.jsonl` | `{"turn":0,"round":4,"tool_name":...,"args":...}` **(verified)** | turn-relative `turn`/`round` |
| `tool_calls/<YYYY-MM>/<DD>.jsonl` | full input/output + `runtime_contract.keeper_turn_id:718`, `trace_id`, `session_id` **(verified)** | absolute keeper turn + session |
| `logs/system_log_<date>.jsonl` | `oas:tool_called` / `oas:tool_completed` pair, `correlation_id`, `run_id`, `turn:null` **(verified)** | OAS correlation ids |

No field is shared across all three. The dashboard session-trace
interleaves at least two of these sources and renders the same physical
execution as two activity rows — `T${event.turn}R${event.round}`
(`dashboard/src/components/session-trace/session-trace-entry.ts:776`
**(verified)**) next to an absolute-turn row carrying the session id.
Operators read this as double execution (issue #20910).

Any view-side dedup (matching on tool name + args + timestamp) would be
read-side repair — the workaround class this repo rejects
(CLAUDE.md §워크어라운드, RFC-0042 precedent). The root is that no
identity is minted at the execution boundary.

### §1.2 The assembled prompt is not recorded anywhere

`keeper_run_tools_hooks.ml` assembles `extra_system_context` as an
append chain — dynamic context, temporal summary, claimed-task nudge,
retry nudge, memory-os recall **(verified)** — and
`build_keeper_system_prompt` renders persona fields per turn. None of
this is persisted per turn. Execution receipts carry only
`extra_system_context_digest` and sizes
(`lib/keeper/keeper_agent_run_receipt.ml:121-123` **(verified)**) — a
digest can prove *change* but cannot show *what changed*.

Consequences observed in the diagnosis session:

- Operators cannot answer "which instruction blocks entered or left this
  turn's context" (issue trail: persona tone drift, post-idle amnesia —
  the mechanism was only reconstructable by reading source).
- Sampling options (model profile, temperature, thinking budget) are
  scattered: `runtime_profile` lives in `runtime_contract` per tool
  call, not per turn; temperature is not recorded at all.
- `keeper_context_status` computes ratio/tokens correctly but its
  output is blob-wrapped above the inline threshold and the dashboard
  shows a ~200-byte preview **(verified)** — there is no turn-level
  surface to read these values from instead.

## §2 Design

### §2.1 Canonical execution identity

Mint `execution_id` exactly once, at the masc dispatch boundary where a
keeper tool call enters execution (the same site that today stamps
`runtime_contract` / writes `tool_calls`). Type, not string-passing
convention:

```ocaml
module Execution_id : sig
  type t
  val mint : unit -> t            (* uuid-v7; sortable *)
  val to_string : t -> string
  val of_string : string -> t option
end
```

Propagation:

- `tool_calls` store: new `execution_id` field.
- trajectory writer: same field; `turn`/`round` stay as display
  attributes.
- OAS event bridge: masc already owns the consumer that turns OAS
  stream events into `oas:tool_called`/`oas:tool_completed` log rows;
  that consumer joins on the in-flight execution (it is masc-side, so
  no OAS API change — OAS stays masc-agnostic per the boundary rule).
- dashboard: one row per `execution_id`; turn-relative and absolute
  labels become attributes of that row, not separate rows.

### §2.2 TurnRecord — typed prompt-block provenance

One record per keeper turn, written at the same point that already
writes the execution receipt:

```ocaml
type prompt_block =
  { block : Prompt_block_id.t   (* closed variant — see below *)
  ; bytes : int
  ; digest : string             (* sha256 of block text *)
  }

type turn_record =
  { execution_ids : Execution_id.t list   (* tool calls in this turn *)
  ; keeper : string
  ; trace_id : string
  ; absolute_turn : int
  ; blocks : prompt_block list            (* assembly order *)
  ; runtime_profile : string
  ; sampling : { temperature : float option
               ; thinking_budget : int option
               ; enable_thinking : bool option }
  ; usage : { input_tokens : int option; output_tokens : int option }
  ; ts : float
  }
```

`Prompt_block_id.t` is a closed sum mirroring today's real assembly
chain in `keeper_run_tools_hooks.ml` and `keeper_prompt.ml`
**(verified)**: `Persona | Continuity | Dynamic_context |
Temporal_summary | Claimed_task_nudge | Retry_nudge | Memory_os_recall
| Connected_surface | Other of string` — adding a new injection site
without extending the variant is a compile-time error at the record
site, which is exactly the leverage that keeps the record honest.

Diffing two consecutive TurnRecords by `(block, digest)` answers the
operator question directly: which blocks appeared, disappeared, or
changed size between turns. Block *text* is not duplicated into the
record; digests join against the existing prompt/receipt stores.

### §2.3 Views derive; no view-side repair

- Dashboard turn inspector reads TurnRecord (blocks, sampling, usage)
  and renders block-diff between turns.
- OTel: per-turn span gets `masc.turn.blocks`, `masc.turn.profile`,
  `masc.execution_id` attributes from the same record.
- `keeper_context_status` gains nothing new to compute — but its
  blob-preview display problem disappears for operators because the
  turn inspector becomes the primary surface for ratio/usage. The blob
  resolve endpoint fix in the dashboard remains a separate small PR
  under #20910.

## §3 Non-goals

- No new telemetry pipeline or transport — TurnRecord is one JSONL
  store next to the existing receipt store; views read it.
- No OAS API change. The execution-id join happens in masc's own event
  consumer. OAS continues to know nothing about MASC.
- No backfill of historical stores; old rows render as today.
- No prompt-text duplication into TurnRecord (digests only).

## §4 Migration

1. PR-1: `Execution_id` + stamp at dispatch + `tool_calls` and
   trajectory fields (additive, old readers unaffected).
2. PR-2: OAS event consumer join + dashboard single-row render keyed by
   `execution_id` (closes the #20910 double-row symptom at the root).
3. PR-3: `Prompt_block_id` + TurnRecord writer at receipt site.
4. PR-4: dashboard turn inspector (block diff) + OTel span attributes.

Each PR lands with its harness (below); none is operable as a silent
cap/dedup — if the id is missing, writers fail loudly in dev builds.

## §5 Verification harness

- Unit: minting uniqueness/sortability; `Prompt_block_id` round-trip;
  TurnRecord codec.
- Behavioral: drive one fake tool execution through dispatch → assert
  exactly one `execution_id` appears in tool_calls + trajectory + the
  oas-event rows for that call (no orphan, no dup).
- Dashboard: session-trace fixture with all three sources for one
  execution → exactly one rendered row.
- Block-diff: two synthetic TurnRecords → diff yields the exact
  added/removed block set (the "what entered/left context" question as
  a test).

## §6 Evidence trail

Diagnosis session 2026-06-12 (issues #20907 #20908 #20909 #20910):
duplicate rows and id vocabularies verified against live stores under
the runtime base path (`tool_calls/2026-06/12.jsonl`,
`trajectories/sangsu/trace-1780648779957-00000.jsonl`,
`logs/system_log_2026-06-12.jsonl`); dashboard render site
`session-trace-entry.ts:776`; receipt digest fields
`keeper_agent_run_receipt.ml:121-123`; context assembly chain
`keeper_run_tools_hooks.ml` (dynamic/temporal/nudge/retry/recall).

Ledger note: this RFC advances `.next-number` 0231→0234 in one commit —
0231 and 0232 were de-facto allocated by the Memory OS series
(implementation merged via #20876/#20881/#20883/#20897) and the typed
lane event model (doc PR #20877, implementation merged via #20896)
without ledger advancement; skipping past both heals the drift without
renumbering shipped references.
