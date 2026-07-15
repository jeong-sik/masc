---
rfc: "0291"
title: "Closed SSE event-type sum + typed broadcast — RFC-0004 Phase A0 Wave 2 increment"
status: Draft
created: 2026-06-23
updated: 2026-06-24
author: vincent
supersedes: []
superseded_by: null
related: ["0004", "0042"]
implementation_prs: []
---

# RFC-0291: Closed SSE event-type sum + typed broadcast

Status: Draft · The SSE wire `type` discriminator is stringly-typed across ~34
backend emit sites. The frontend parity gate only inventories exact-match
routes, so slice-bridged events require separate hand-written drift guards.
This RFC closes the discriminator into an OCaml
sum with a typed broadcast builder and a raw-string ban-lint, so the compiler —
not a parallel test — enforces that every emitted event-type is declared and FE
and BE stay in lockstep. This is the **RFC-0004 Phase A0 Wave 2** increment: it
completes the emit-site migration that A0.1 began on `runtime_event_bridge` only.

Drafted by: Claude Opus 4.8 (with owner, 2026-06-23) after a 5-lens grounding of
the SSE event-type surface (task-1479 keystone).

> Anchors are read against `origin/main` (`ad4b654f48`) on 2026-06-23.

---

## §1 Problem — the SSE `type` discriminator is stringly-typed

The dashboard live-update bus routes on a single string field. The backend sets
it per call site as a raw literal, and the frontend matches it as a raw literal;
nothing binds the two.

- **Backend**: the public broadcast API (`lib/sse.mli:101-104`) carries **no**
  event-type argument —

  ```ocaml
  val broadcast : Yojson.Safe.t -> unit               (* lib/sse.mli:101 *)
  val broadcast_to : broadcast_target -> Yojson.Safe.t -> unit
  ```

  The routing discriminator lives inside the JSON payload as a `"type"` string
  the caller assembles by hand — e.g. `keeper_chat_broadcast.ml:58`
  `("type", \`String "keeper_chat_appended")`. The consumer routes on that field
  at `server_mcp_transport_ws.ml:713`, then maps it to a dashboard slice. There
  are ~34 such emit sites, each with its own raw literal.
- **Frontend**: `sse-store.ts` routes on the payload `"type"` field, partly by
  exact match (`event.type === 'X'`) and partly by a slice-bridge switch
  (`hydrateDashboardSlice`'s `case 'X'`).
- **The only guard today** is `sse-event-type-parity.test.ts`, whose regex
  (`:62-63`) matches **only** exact-match routes. Slice-bridged events are
  invisible to it and therefore require hand-written drift guards as a
  **stopgap**. That gate's own header (`sse-event-type-parity.test.ts:21-25`)
  already names the fix — "closed event-type sum + typed broadcast API +
  raw-string ban" — and files it as a **RFC-0004 increment**.

Consequence: renaming one of the three literals for any slice-bridged event
silently breaks live updates while every test stays green. The drift-guard
approach does not scale — each new slice-bridged event needs its own hand-written
guard. This is a typed-boundary gap, the same class RFC-0042 closed for
keeper classifiers.

## §2 Boundary — what is already typed, and what is not

- **Already typed**: the *targeting* axis. `broadcast_target`
  (`lib/sse.ml:46-50`: `All | Observers | Agent_streams | Presence_only`) and
  `session_kind` (`Observer | Agent_stream | Presence`) are closed sums. Only the
  *event-type* axis is stringly-typed.
- **The wire `event:` line is NOT the routing key.** `broadcast_impl`'s
  `?(event_type = "message")` (`lib/sse.ml:812-813`) sets the SSE `event:` line,
  which every durable broadcast leaves at `"message"` (only `broadcast_presence`
  overrides to `"presence"`). Consumers route on the payload `"type"` field, not
  the wire line (`server_mcp_transport_ws.ml:713-724` reads
  `List.assoc_opt "type" fields` then `dashboard_slice_for_sse_type`).

**Therefore the migration does not change the broadcast signature.** It threads a
closed `Sse_event_type.t` into the payload `"type"` field at construction. The
broadcast functions stay `Yojson.Safe.t -> unit`.

## §3 Grounded surface — ~50 event-types, three shapes

A full inventory of the ~34 broadcast sites (5-lens grounding, 2026-06-23) finds
**~50 distinct event-types in three wire shapes**:

### §3.1 Fixed-literal `type`-keyed events (closeable) — ~30
Plain literals set at a single (or few) site(s). Examples: `project_snapshot`,
`namespace_truth_snapshot`, `operator_snapshot`, `operator_digest`,
`execution_snapshot`, `transport_health_snapshot`,
`keeper_chat_appended`, `keeper_composite_changed`, `keeper_phase_changed`,
`keeper_heartbeat`, `keeper_compaction`, `keeper_handoff`, `keeper_tool_skipped`,
`keeper_turn_complete`, `keeper_tool_call`, `approval:pending`,
`approval:resolved`, `fusion_run_status`, `gate_configuration_changed`,
`dashboard_yjs_update`. These close into fixed variants directly.

Some literals are emitted from **multiple sites** (`keeper_heartbeat` ×2,
`keeper_tool_call` ×2, `gate_configuration_changed` ×2, and the
`project_snapshot`/`namespace_truth_snapshot` alias pair). A typed constructor
centralizes them; §8 requires confirming payload-shape compatibility before
collapsing co-emitters to one variant.

### §3.2 The OAS bridge `oas:*` family (open-world) — ~16 fixed + dynamic
`keeper_event_bridge.ml` prepends `"oas:"` (`:153`) to a native OAS event suffix.
**16 variants are fixed** (`oas:agent_started`, `oas:tool_called`,
`oas:turn_completed`, `oas:context_compacted`, … `keeper_event_bridge.ml:202-385`)
and close 1:1 with `Agent_sdk.Event_bus` payload variants. But **two arms build
the type dynamically**:
- `Custom (name, payload)` (`:386-406`) — `"oas:" ^ name` with `dot→colon`
  rewrite, e.g. `masc.keeper.snapshot → "oas:masc:keeper:snapshot"`. The name is
  an arbitrary upstream OAS string.
- the `match[@warning "-11"]` catch-all (`:430-477`) — `"oas:" ^ payload_kind`,
  a deliberate open-world escape kept to survive OAS pin-bumps (#10490/#10574/#10584).

These two arms **cannot** be a fixed sum. They are the single biggest design
tension (§4.2).

### §3.3 JSON-RPC `method`-keyed notifications (different wire shape) — 3
`notifications/board` (`server_bootstrap_loops.ml:451`),
`notifications/tools/list_changed` (`mcp_server_eio_protocol.ml:88`),
`notifications/progress` (`progress.ml:63`) use a `"method"` field, not `"type"`.
They are a different discriminant and are **out of scope** (§10) — the sum is over
`"type"`-keyed events only.

### §3.4 Indirect emits (a naïve `Sse.broadcast` grep misses these) — 2
`oas:masc:harness:verdict_recorded` (`tool_task_payloads.ml:153` via
`Task.Handlers.sse_broadcast_fn`, wired at `mcp_server.ml:532`) and
`masc/task_claimed` (`tool_task_handlers.ml:471` via
`push_event_to_sessions_fn`, wired at `mcp_server.ml:533`) reach the bus through
`Atomic` callbacks, not a direct `Sse.broadcast` call. The typed builder and the
ban-lint must key on the **payload construction**, not only on textual
`Sse.broadcast` call sites, or these slip through (§4.3).

## §4 Design

### §4.1 A closed `Sse_event_type.t` sum with a typed builder
Introduce `lib/sse_event_type/sse_event_type.{ml,mli}`:

- `type t` — a closed sum over the §3.1 fixed events plus a nested OAS type
  (§4.2). No catch-all on the native arm.
- `val to_string : t -> string` — the single source of every wire literal.
- `val of_string : string -> t option` — REJECT-unknown inverse (mirrors
  `keeper_reaction_ledger.stimulus_kind_of_string`, `lifecycle_events.event_of_string`).
- A **typed payload builder** every emit site uses to set `"type"`:
  `val event_payload : event_type:t -> (string * Yojson.Safe.t) list -> Yojson.Safe.t`
  (or a thin `with_type : t -> Yojson.Safe.t -> Yojson.Safe.t`). The broadcast
  call then becomes `Sse.broadcast (Sse_event_type.event_payload ~event_type:Keeper_chat_appended [...])`.

The targeting axis (`broadcast_target`) stays as-is; this RFC types only the
`"type"` axis.

### §4.2 The OAS family — closed native variants + one `Unknown_oas` escape
Model the bridge as a nested type:
```
type oas_event =
  | Oas_agent_started | Oas_tool_called | … (* 16 fixed, 1:1 with Event_bus *)
  | Unknown_oas of string   (* Custom(name,_) and the pin-bump catch-all *)
type t = … | Oas of oas_event | …
```
- `to_string (Oas (Unknown_oas s)) = "oas:" ^ s` preserves the upstream string —
  the TOTAL-with-escape policy of `keeper_reaction_ledger.reaction_kind`
  (`Unknown_reaction of string`).
- The 16 native arms become a no-catch-all exhaustive match, so a new
  `Event_bus` variant forces a compile error at the bridge (the mechanism
  `lifecycle_display`'s `display_of_custom_event` already uses).
- `Unknown_oas` is the **only** sanctioned dynamic construction. The ban-lint
  (§5) exempts exactly that site and forbids raw literals elsewhere. This
  reconciles compile-time closure with OAS-pin-bump churn: pin-bumps land in
  `Unknown_oas`, not as a `-warn-error +8` break.

### §4.3 Channel scope — broadcast bus, session-push, presence
Three delivery channels carry event-types: the Observers/All broadcast bus, the
`push_event_to_sessions` session-push (`masc/task_claimed`), and
`broadcast_presence` (presence-class `keeper_heartbeat`/`keeper_composite_changed`).
This RFC types the **payload `"type"` axis shared by all three** — the builder is
channel-agnostic, so the two indirect emits (§3.4) and presence emits use the
same `Sse_event_type.t`. The ban-lint keys on `("type", \`String …)`
construction — literal, label-argument, or variable-binding — regardless of
which channel function consumes it.

## §5 Raw-string ban-lint
Add `scripts/ci/check-sse-event-type-safety.sh`, modeled on the existing
**diff-aware** `scripts/ci/check-enum-string-safety.sh` (meta-issue #9521):

- Scans `base...head` + staged + worktree diffs (`--base`/`--head` modes).
- Fails on **new** raw event-type string construction in any of the following
  shapes, unless the value is produced via `Sse_event_type.to_string` / the typed
  builder:
  1. **Literal pair construction** in OCaml: `("type", \`String "literal")`
     (or the equivalent `"type":"literal"` in TypeScript).
  2. **Label-argument literal** in OCaml: `~event_type:"operator_snapshot"`,
     `~event_type:"operator_digest"`, `~event_type:"execution_snapshot"`,
     `~event_type:"transport_health_snapshot"`, and any other label that feeds
     a payload `"type"` field (e.g. `server_dashboard_http_execution_surfaces.ml`
     helper signatures).
  3. **Variable-binding pair construction** in OCaml:
     `("type", \`String event_type)` or
     `("type", \`String raw_event_type)` — i.e. the right-hand
     side is an identifier rather than a constructor, even when the identifier
     itself is bound from a typed value. These are permitted only when the
     identifier's type is `Sse_event_type.t` (or the expression is the typed
     builder's output), not when it is an unvalidated `string`.
- Honors an inline escape comment for the one sanctioned dynamic site
  (`Unknown_oas`), following the established `STR-OK | STRING-BOUNDARY-OK`
  convention (`check-enum-string-safety.sh:66-74`).
- Existing debt is warning-only (baseline ledger like
  `stringly-boundary-baseline.json`); only NEW drift fails. Wired under
  `.github/workflows/ci.yml` next to the other boundary ratchets.

## §6 Frontend lockstep — retire the stopgaps
The backend sum is the SSOT. Export its `to_string` vocabulary (generated JSON or
an atd-derived list, consistent with RFC-0004 §A0.5 round-trip gate) and have the
FE parity test assert that **both** exact-match routes and slice-bridge `case`
labels are a subset of the backend vocabulary. This:
- covers every slice-bridged event,
- lets per-event drift guards and the parity gate's hand-maintained
  `BACKEND_EMITTED` map be **retired** rather than left as parallel substitutes,
- realizes RFC-0004 §A0.5/A3's drift gate as a derived (not hand-kept) artifact.

## §7 Phasing
- **Phase 1 (sum, no migration)** — add `sse_event_type.{ml,mli}` with `t` /
  `to_string` / `of_string` / builder + a round-trip drift-guard test (every
  variant `of_string(to_string v) = Some v`, and `of_string "unknown" = None`;
  `Unknown_oas` round-trips by transcription). No call site changes yet. Green in
  isolation.
- **Phase 2 (migrate emit sites, by subsystem batch)** — convert the ~34 sites to
  the typed builder in batches: dashboard surfaces → keeper → approval/fusion →
  OAS bridge (the `Unknown_oas` arm last). Each batch is one PR; co-emitter
  payload-shape compatibility (§3.1) confirmed before collapsing.
- **Phase 3 (enforce + retire)** — add the ban-lint (§5), wire the FE lockstep
  (§6), and delete per-event drift guards plus the parity gate's hand map. Only
  after Phase 2 reaches zero raw literals (RFC-0004 §"기대 효용": emit-site → 0).

## §8 Verification
- Phase 1: round-trip drift guard per variant; `of_string` rejects unknown;
  `Unknown_oas` transcribes losslessly. A value-pinned test (not just
  `Option.is_some`) asserts each variant's exact wire string, since a `to_string`
  typo is value-drift the round-trip alone would not catch.
- Phase 2: each batch keeps `dune build @check` green; the exhaustive bridge
  match (no catch-all) means a missed `Event_bus` variant fails compilation.
- Phase 3: the ban-lint fails a synthetic PR that adds a raw `("type", \`String
  "new_event")`; the FE lockstep test fails a synthetic FE `case 'x'` with no
  backend variant. Both prove the guard is live, not vacuous.

## §9 Alternatives considered
- **Keep extending drift-guard tests per event** (status quo): O(events)
  hand-written guards, each able to rot; never covers the next slice-bridged
  event by default. Rejected — does not scale and is the very pattern this RFC
  retires.
- **Fully-closed sum, no escape** (reject `Custom`/catch-all): would re-introduce
  the `-warn-error +8` break the bridge's `[@warning "-11"]` catch-all
  (`keeper_event_bridge.ml:430`) exists to prevent on OAS pin-bumps. Rejected in
  favor of the §4.2 `Unknown_oas` escape (TOTAL-with-escape, RFC-0042 precedent).
- **Type the broadcast wire signature** (`broadcast : event_type -> payload -> unit`):
  larger blast radius; the wire `event:` line is not the routing key (§2), so it
  buys nothing the payload-`"type"` builder doesn't. Rejected as over-reach.
- **Include the 3 JSON-RPC `method` notifications**: different discriminant
  (`"method"` vs `"type"`); folding them into one sum conflates two wire shapes.
  Rejected — explicit exclusion (§10).

## §10 Out of scope
- The 3 JSON-RPC `method`-keyed notifications (§3.3) — separate wire shape;
  typed separately or left as-is.
- The gRPC-web contract (RFC-0004 Track B) — proto-based, already closed.
- Payload *body* schemas beyond the `"type"` discriminator — RFC-0004 Track A
  A0.1 already typed 16 payloads; extending payload typing to the remaining
  events is a follow-on, not this RFC.
