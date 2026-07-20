# RFC-0347 — Typed EffectIntent + capability floor at the Keeper Gate

- Status: Draft
- Author: vincent
- Related: RFC-0000 §3.4 (Effect Permission Boundary card, DESIGN), RFC-0000 LAW 4 (hard cut) and KILL list (`docs/rfc/RFC-0000-MASTER-ROADMAP.md:67,111,251-259,485-489`), RFC-0320 (`continuation_channel`), RFC-0321 (Withdrawn), RFC-0329 (Rejected), RFC-0331 (Withdrawn), RFC-typed-egress-resource-capability (Withdrawn), `lib/keeper/keeper_gate.ml`, `lib/keeper_contract/keeper_approval_queue_rules_types.mli`, `/Users/dancer/me/reports/masc-nondeterministic-lane-analysis-2026-07-17.html`

## 0. Summary

The Keeper Gate already enforces exact-effect semantics at runtime: an approval is consumed only when (keeper, tool, canonical input) match exactly, one-shot, off-lane. What does not exist is the type that makes the boundary structural. `EffectIntent`, `ContinuationRef`, and a capability floor are all absent from `lib/` (grep 0, verified 2026-07-20 on `b39c1027f6`), and the master roadmap lists them as `[DESIGN, 미구현 타입]` (`RFC-0000-MASTER-ROADMAP.md:254`). As a result the §3.4 invariant "LLM Judge는 structural floor를 낮출 수 없다" (`:255`) is prose, not code: there is no floor value anywhere in the request → queue → judge → resolution → consume path, so in `Auto_judge` mode a single judge `Approve` settles any effect whatsoever.

This RFC promotes the existing ad-hoc `operation`/`input`/`input_hash` triple into a sealed `EffectIntent` type — canonical-input `args_hash`, closed-sum capability floor (`Workspace_write|External_message|Money|Destructive|Credential|Unknown`), `ContinuationRef` binding approval → wake → resume, expiry, single-use — and makes settler eligibility a typed witness so that lowering a floor is unrepresentable rather than forbidden. The decide-then-wake lane, the owner-per-keeper Auto Judge lane, and the durable approval queue SSOT are unchanged. Migration follows LAW 4: each step is a hard cut with legacy deleted in the same PR; no dual-read, no compatibility parser.

## 1. Problem (evidence)

All line references are `b39c1027f6` (origin/main, 2026-07-20).

**The exact-effect semantics are real and landed:**

- `Keeper_gate.request` (`lib/keeper/keeper_gate.ml:6-15`) carries `operation : string`, `input : Yojson.Safe.t`, `continuation_channel : Keeper_continuation_channel.t option`.
- `pending_approval` (`lib/keeper_contract/keeper_approval_queue_rules_types.mli:29-45`) stores `input_hash : string`, computed as `request_fingerprint` = SHA256 over field-order-canonical JSON (`lib/keeper/keeper_approval_queue_rules.ml:89-92`), re-validated on load (`lib/keeper/keeper_approval_queue.ml:364-370`) and matched at consume (`:1183`, `:1704-1788`).
- Consume-time exact match: `take_matching_cycle_grant` (`keeper_gate.ml:81-114`) calls `consume_approved_resolution ~keeper_name ~tool_name ~input`; outcomes are typed (`Consumption_committed | Consumption_already_committed | Consumption_not_matching`, `keeper_approval_queue.mli:35-38`). One-shot is enforced by the atomic cycle-grant state machine (`keeper_gate.ml:57-65`).
- Decide-then-wake: `decide` (`keeper_gate.ml:887-922`) → mode dispatch (`decide_from_selected_mode`, `:832-843`) → `defer` (`:778-807`) durably commits via `submit` (`:203-215` → `submit_pending`) and releases the lane; a resolution enqueues the typed `Hitl_resolved` stimulus (`enqueue_hitl_resolution_durable_result`, `lib/keeper/keeper_registry_event_queue.ml:293-311`, `Immediate`, durable dedup by `hitl_resolution_post_id`).
- Auto Judge: single active per `(audit_base_path, keeper_name)` owner (`keeper_gate.ml:282-325`, owner key at `:294-296`); three decision sources `Always_allowed | Auto_judge | Human_operator` (`keeper_approval_queue_rules_types.mli:58-61`).

**The gap (a): the floor invariant has no carrier.**

- `EffectIntent`, `ContinuationRef`, `capability_floor`: `rg` across `lib/` = 0 matches. `pending_approval` has no floor field; `Decision.t = Approve | Reject of string | Edit of Yojson.Safe.t` (`keeper_approval_queue_rules_types.mli:49-54`) has no floor slot.
- Judge settlement applies the advisory judgment directly: `resolve_judgment` (`keeper_gate.ml:246-271`) maps `summary.judgment = Approve` → `Decision.Approve` → `resolve_with_policy ~source:Auto_judge`. No structural value is consulted because none exists.
- `Auto_judge` is the default gate mode (`lib/keeper/keeper_gate_mode.ml:14`, `let default = Auto_judge`). So on a default deployment, one model-emitted `Approve` settles any effect class — including credential- or money-class effects the roadmap explicitly places above a judge's reach (`RFC-0000-MASTER-ROADMAP.md:254-255`). "The Judge cannot lower the floor" holds today only as reviewer convention; nothing in the type system stops a future refactor from adding a judge-side override, because there is nothing to override.
- Three `Keeper_gate.decide` call sites pass raw `~operation`/`~input` pairs: `lib/keeper/keeper_tool_execute_runtime.ml:299`, `lib/keeper/keeper_tool_in_process_runtime.ml:41`, `lib/keeper/keeper_tool_filesystem_runtime.ml:938`. The boundary value that should be sealed at construction is currently re-assembled from strings at every hop.

The nondeterministic-lane analysis (`reports/masc-nondeterministic-lane-analysis-2026-07-17.html`) judged this HITL lane the only correctly bounded lane in the fleet. The defect is therefore not the lane mechanics — it is that the request value crossing the lane is untyped at exactly the point where the roadmap demands a sealed one.

## 2. Non-goals

- No governance/risk hierarchy, no static tool block, no reason-code resurrection (RFC-0321 constraint). The floor never rejects an effect; it constrains *who may settle*.
- No executor command taxonomy or typed exemption import (RFC-0329 constraint). `operation` stays an opaque string; the Gate learns no tool-name ranking.
- No per-tool registration flag as authorization rank (RFC-0331 constraint). `Tool_capability.kind` (`tool_surface/tool_capability.mli:11`) is dispatch metadata and is not reused as the floor.
- No vendor/host/path egress classification (RFC-typed-egress-resource-capability constraint). Vendor-aware floor assignment lives in the submitting connector/tool adapter.
- No lane-topology change: owner-per-keeper Auto Judge, durable queue SSOT, decide-then-wake, cycle-grant consume — KEEP.
- No OAS change. No durable-journal wire-format change (`"input_hash"` field name and digest algorithm are stable).
- This RFC does not decide the NEEDS_DECISION values in §5.

## 3. Design

### 3.1 `EffectIntent` — sealed request value

New module `lib/keeper_contract/keeper_effect_intent.mli`:

```ocaml
type capability_floor =
  | Workspace_write
  | External_message
  | Money
  | Destructive
  | Credential
  | Unknown

type args_hash         (* private: only [v] can produce one *)
type continuation_ref  (* private: only the approval queue can mint one *)

type t = private
  { intent_id : string
  ; keeper_name : string
  ; operation : string              (* opaque; no taxonomy *)
  ; canonical_input : Yojson.Safe.t (* stored for consume-time re-check *)
  ; args_hash : args_hash
  ; floor : capability_floor
  ; continuation : continuation_ref
  ; expires_at : float option
  ; single_use : bool               (* [true] for every effect intent *)
  }

val v : keeper_name:string -> operation:string -> input:Yojson.Safe.t
      -> floor:capability_floor -> expires_at:float option -> t
val args_hash_string : args_hash -> string  (* serialization only *)
```

- `args_hash` is sealed: it exists only as the SHA256 of the field-order-canonical input, computed inside `v` — the same algorithm as today's `request_fingerprint` (`keeper_approval_queue_rules.ml:89-92`). Identical input yields an identical digest, so existing durable pending entries and exact Always Allowed rules remain valid with no backfill and no dual-read.
- `floor` is assigned by the **submitting adapter** at construction, from objective facts of the concrete invocation (filesystem adapter → `Workspace_write`, connector post adapter → `External_message`, …). `Unknown` is the explicit fail-closed value when no objective classification exists — the same discipline as `Unrouted` in RFC-0320. The Gate never derives a floor from `operation`/`input`; no classifier is introduced.
- `continuation_ref` binds approval → wake → resume: it wraps `(base_path, keeper_name, approval_id, args_hash)` and is minted only by the approval queue at `submit`. The `Hitl_resolved` stimulus and the cycle grant carry it, so resume consumes exactly the grant minted for this intent — today's implicit approval_id thread-through becomes a named typed value.
- Expiry / single-use: `expires_at` is optional (today's `pending_approval` has only `requested_at`; whether expiry becomes mandatory is ND-3). Single-use is enforced through the consume result — a second consume is `Consumption_already_committed`, never an authorization; the type makes re-authorization unrepresentable.

### 3.2 Floor invariant — settler eligibility as a typed witness

- Decision records stay floor-free: `Decision.t` is unchanged. There is no parameter slot through which any decision — judge or human — could transmit a lowered floor.
- The floor travels with the request: `pending_approval` gains an immutable `floor` field, carried queue → judge → resolution → consume.
- Settlement requires a typed witness: `resolve_with_policy` takes a settler capability `Human_settlement | Judge_settlement of judge_ceiling | Rule_settlement`. The Auto Judge path (`resolve_judgment`, `keeper_gate.ml:246-271`) routes through `judge_settle : t -> advisory_judgment -> (resolution, settle_error) result`, which returns `Error Floor_above_judge_ceiling` when the intent's floor exceeds the ceiling; the entry stays pending (same posture as `Require_human` today). The judge ceiling is operator configuration, never model-inferred (exact set: ND-2).
- No function of type `capability_floor -> capability_floor` exists in the resolution path, and the private record has no setter — grep witnesses in §4. The only way to obtain a lower floor is to construct a **new** intent, which yields a new `args_hash`; any prior approval then fails the consume match (`Consumption_not_matching`). Floor-lowering-by-edit is a fresh request requiring a fresh decision, not a mutation — this is exactly the §3.4 contract "edited args는 approval 무효화(새 EffectIntent)" (`RFC-0000-MASTER-ROADMAP.md:255`), now enforced by construction.
- `Decision.Edit of Yojson.Safe.t` therefore cannot authorize a mutated input; its resume flow is ND-5.

### 3.3 Relationship to existing types — promotion (승격), not replacement

- `Keeper_gate.request` (`keeper_gate.ml:6-15`): `operation`, `input`, `continuation_channel` are subsumed by `intent : EffectIntent.t`; the record keeps `base_path`, `causal_context`, `task_id`, `goal_ids`. One field swap at the boundary — no parallel representation.
- `pending_approval.input_hash : string` → `args_hash : Keeper_effect_intent.args_hash`. The serialized journal field name stays `"input_hash"` (wire-stable); only in-memory constructibility changes.
- `approval_rule.request_fingerprint` adopts the same sealed hash type; rule matching is unchanged.
- `continuation_channel` (RFC-0320, `keeper_runtime/keeper_continuation_channel.mli:17-32`) is unchanged; `continuation_ref` references it rather than duplicating routing data.
- This RFC is the type foundation for roadmap Goal 9 (`RFC-0000-MASTER-ROADMAP.md:485-489`): exact EffectIntent permission, non-blocking one-shot judgment, adversarially verified.

### 3.4 Migration order — LAW 4 hard cuts, no dual-read

LAW 4 (`RFC-0000-MASTER-ROADMAP.md:111`): verify the new boundary, then delete legacy immediately in the same PR — no compatibility parser, no dual-write, no hidden fallback. The KILL list (`:67`) also bans landing a type with no producer/consumer, so no types-only PR.

- **PR-1 — sealed intent at the Gate boundary.** Land `Keeper_effect_intent` and cut the three `decide` call sites (`keeper_tool_execute_runtime.ml:299`, `keeper_tool_in_process_runtime.ml:41`, `keeper_tool_filesystem_runtime.ml:938`) to construct intents in their adapters. `Keeper_gate.request` carries `intent`; `pending_approval` stores the sealed `args_hash` (same digest, wire-stable). Legacy `operation`/`input`/`input_hash : string` fields are deleted in the same PR. Verified by the existing gate/approval-queue suites plus hash golden vectors (T1).
- **PR-2 — floor + settler witness.** Add `pending_approval.floor`, the settler capability, and `judge_settle`; route `resolve_judgment` through it; delete the witness-less resolve path in the same PR. Pre-floor durable entries: one-shot upgrade per ND-4 (explicit total mapping to `Unknown` at install, or drain-at-deploy) — either is a single cut, never a long-lived dual-read.
- **PR-3 — continuation_ref threading.** `Hitl_resolved` payload and the cycle grant carry the ref; resume matches on ref equality instead of bare approval_id; the id-only match is deleted in the same PR. The enqueue site (`keeper_registry_event_queue.ml:293-311`) and lane semantics are unchanged — same durable dedup, same `Immediate` wake.

No commit may leave raw-pair and intent paths simultaneously live at the Gate boundary; a dual path is a dual-read variant and violates LAW 4.

### 3.5 Lane structure — KEEP

- Decide-then-wake is untouched: approval request = durable commit + immediate lane release (lane-held time = 0); resolution enqueues typed `Hitl_resolved`. Intent construction is pure CPU work before the Gate decision and adds no lane-held waiting — the property the lane analysis credited.
- Owner-per-keeper Auto Judge (`keeper_gate.ml:282-325`) is untouched: claim/release, one active per owner, failure isolation. The floor gates only *settlement* of the judged entry.
- The cycle-grant one-shot consume (`keeper_gate.ml:57-114`) keeps its mechanism; the grant binds a `continuation_ref` instead of a bare approval_id string.

## 4. Acceptance (machine-checkable)

Grep witnesses (run at the PR that lands each step):

- G1: `rg "type t = private" lib/keeper_contract/keeper_effect_intent.mli` → 1 match; `rg "EffectIntent|capability_floor|continuation_ref" lib/ | wc -l` → > 0 (baseline today: 0).
- G2: `rg "input_hash : string" lib/keeper_contract/keeper_approval_queue_rules_types.mli` → 0 matches (promoted to sealed `args_hash`); `rg "\"input_hash\"" lib/keeper/keeper_approval_queue.ml` → still matches (journal field name stable).
- G3: `rg "~operation:" lib/keeper/keeper_gate.ml` → 0 matches at the decide boundary (raw pair eliminated); each of the three call sites in §3.4 PR-1 matches `Keeper_effect_intent.v` within the constructing function.
- G4 (no lowering path): `rg "\.floor <-" lib/` → 0; `rg "capability_floor -> capability_floor" lib/` → 0; `rg "_\s*->" lib/keeper_contract/keeper_effect_intent.ml` → 0 (exhaustive matches only).

Tests:

- T1 `test_effect_intent_hash_matches_request_fingerprint` — golden vectors: `args_hash_string` of a constructed intent equals `request_fingerprint` of the same input.
- T2 `test_gate_judge_cannot_settle_above_ceiling` — Auto Judge `Approve` on a `Credential`-floor intent → `Error Floor_above_judge_ceiling`; entry stays pending; decision record shows no `Allow`.
- T3 `test_gate_edited_args_invalidate_prior_approval` — resume with modified input after approval → `Consumption_not_matching`; no authorization.
- T4 `test_gate_intent_single_use_second_consume` — second consume of the same ref → `Consumption_already_committed`, never `Allow`.
- T5 `test_hitl_resolved_carries_continuation_ref` — the enqueued `Hitl_resolved` payload round-trips the ref; resume consumes the grant bound to that exact ref.
- T6 Existing keeper gate / approval-queue tests pass with only the promoted field types changed (behavior-preserving promotion).
- W1 (type witness): `resolve_with_policy`'s `.mli` signature requires a settler capability; there is no exported overload that accepts `~source:Auto_judge` without one (compile-time witness: the unwitnessed call in today's `keeper_gate.ml:258-266` fails to typecheck).

## 5. NEEDS_DECISION

Open questions — values deliberately not chosen in this RFC:

- **ND-1 — `Unknown` floor semantics.** (a) Auto Judge ineligible, human-only settlement (entry stays pending until a human resolves); vs (b) fail-closed at intent construction (no intent is minted, the adapter gap surfaces at the call site). (a) keeps the request visible and auditable in the queue; (b) fails faster but couples construction to deployment posture.
- **ND-2 — Auto Judge ceiling set.** Exactly which floors a configured LLM judge may settle (candidates: none; `Workspace_write` only; up to `External_message`). Must be explicit operator configuration; the roadmap's non-goal list forbids re-deriving it from a model or a risk heuristic.
- **ND-3 — Expiry posture.** Whether `expires_at` becomes mandatory for new intents, and if so who sets the default (the no-inferred-defaults principle applies, cf. RFC-0345 §3.1).
- **ND-4 — Pre-floor journal upgrade.** Map legacy entries to `Unknown` at install (one explicit total codec mapping) vs drain-at-deploy (refuse to load pre-floor entries). Either must be a one-shot cut per LAW 4, not a persistent dual-format reader.
- **ND-5 — `Decision.Edit` resume flow.** Whether an edited input causes the adapter to mint a new intent automatically at resume, or the resolution returns to the keeper to issue a fresh request.

## 6. Blast radius

- In-memory type change at the Gate boundary and approval-queue record; three call sites; durable journal wire format stable (field name + digest algorithm unchanged), so no operator migration for PR-1.
- Behavioral change in PR-2: a judge `Approve` on an above-ceiling floor no longer settles — this is the intended invariant gain and must be called out in CHANGELOG. Default deployments (gate mode `Auto_judge`) gain pending entries that require human settlement; ND-1/ND-2 determine exactly which.
- No OAS change, no scheduler/lane change, no connector wire change.

## 7. Workaround-rejection self-check (CLAUDE.md)

- Not telemetry-as-fix: the ceiling blocks settlement in the type of the resolve path (T2, W1), not in a log line.
- Not a string/substring classifier, not N-of-M: the floor is a closed sum assigned by the submitting adapter from objective facts; the Gate never parses `operation`/`input` to rank requests (RFC-0331 / egress-withdrawal constraints hold).
- Not a static block: the floor selects *who may settle*, never *whether* an effect is categorically denied — no RFC-0321-style rejection path is recreated.
- `Unknown` is an explicit variant with exhaustive matches (G4), not a catch-all bucket with a hidden default; its semantics are an open decision (ND-1), not an implicit fallback.

## 8. Implementation note (post-approval)

Sequenced as PR-1 → PR-2 → PR-3 per §3.4, each a self-contained hard cut with the §4 witnesses for its step. This RFC is docs-only; no code lands with it. After PR-2, the §3.4 card's "[DESIGN, 미구현 타입]" annotation in `RFC-0000-MASTER-ROADMAP.md:254` is updated to cite the landed modules.
