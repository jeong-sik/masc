# RFC-0036: oas Cognitive Mapping (companion to RFC-0035)

- **Status**: Active
- **Author**: Agent-LLM-A (autonomous, /loop iteration 5)
- **Created**: 2026-05-07
- **Activated**: 2026-05-14 (cite-able foundation for downstream OAS-touching RFCs; manifest table at §"Problem" is the working contract)
- **Implementation state**: manifest accepted as the working host ↔ oas pairing; PR-A1 / PR-A2 / PR-B (Extensions A and B) **not yet implemented** — those proposals retain their `not started` status in §"Implementation plan (this RFC stack)" and ship under separate PRs when scheduled. Activation here does **not** imply Extensions are merged.
- **Companion to**: RFC-0035 (Cognitive IDE Master Plan Integration)
- **Repos affected**: `jeong-sik/oas` (agent_sdk) and the masc ↔ oas
  contract surface
- **Out of scope**: changing `agent_sdk`'s public-API contract, breaking
  semver promises, anything that requires consumers to re-pin

## Problem

RFC-0035 covers the masc side of the Master Report's 11 cognitive
dimensions. It deliberately marked `agent_sdk` (oas) as "out of scope"
on the assumption that the cognitive layer lives entirely in the host.

That assumption was wrong. A re-read of `oas/lib/` shows that the SDK
already carries the *SDK-side* primitives that pair with the host-side
cognitive layer:

| Master Report dim / item | Host (masc) surface | oas surface |
|---|---|---|
| Dim01 #5 Semantic Gravity | `lib/cognitive_gravity.ml` (PR-1, #13797) | — (genuinely host-only) |
| Dim01 #6 Intentional Projection | `lib/intentional_projection.ml` (PR-2, #13821) | **`lib/context_intent.{ml,mli}`** (`intent` enum + heuristic + model-assisted classify) |
| Dim06 FSM-based Tools / Structured Execute | `lib/agent_tool_execute_*`, `lib/tool_*` | **`lib/agent_tool.mli` (agent-as-tool)**, **`lib/typed_tool.{ml,mli}` (strong-typed tools)** |
| Dim09 Objective-driven design — execution gate | MASC Task/Keeper lane | **`lib/autonomy_exec.ml` (orchestration-agnostic exec primitive)** |
| Dim03 Code-Plan Alignment — diff guard | (none yet) | **`lib/autonomy_diff_guard.ml` (banned-pattern + path filter on unified-diff)** |
| Dim01 #1~#4 (cognitive UI flow) | dashboard PRs | — (UI is genuinely host-only) |
| Dim02 Chronicle / Librarian | `lib/chronicle_event.ml` (TBD), dashboard read model | — (event source is host-side) |

The oas surfaces in the right column are *not* recent additions — they
predate the Master Report. Treating oas as a passive transport in
RFC-0035 misses that the SDK has been quietly carrying a coherent
SDK-side cognitive layer.

This RFC corrects the omission by:

1. recording the host ↔ oas mapping above as the working manifest;
2. proposing two small, additive oas extensions that close the
   remaining gaps without breaking the SDK's public API;
3. listing what we are *not* changing on the oas side (most things).

## Why this matters now

Without an explicit mapping, future cognitive PRs will:

- Re-implement on the host what oas already has (e.g. a host-side intent
  taxonomy that conflicts with `oas/lib/context_intent.ml`'s 5-variant
  enum). Wasteful and a source of drift.
- Touch oas opportunistically without a manifest, which is dangerous
  because oas is a pinned hot dependency: every push triggers a
  downstream re-pin in masc's `chore(oas) bump agent sdk pin`
  workflow (#13785, #13625, #13554, #13494, #13458 — five within a
  week prior to 2026-05-07).
- Leave Dim03 / Dim09 work in the host-only column even though
  `autonomy_diff_guard` already enforces the same family of constraints
  one layer down.

## Goals

- Make the host-side / oas-side pairing explicit. Future PRs cite this
  table in their bodies.
- Identify the *minimum* oas surface additions needed to close cognitive
  gaps. The bias is toward additive type-only or doc-only changes.
- Define the boundary: what stays on the host, what stays on oas, and
  what is genuinely shared.

## Non-goals

- Reproducing RFC-0035 or the Master Report.
- Changing existing oas public API. The two proposed extensions below
  add new types / new module — no rename, no signature change.
- Touching the runtime / provider / hooks layers (those already have
  their own RFCs in masc space).
- Centralising version policy. oas already has
  `scripts/sync-version-truth.sh` (3-surface sync) and
  `scripts/check-tag-drift.sh` (CHANGELOG ↔ tag); both work and do not
  need re-design.

## Boundary discipline

A PR that touches both the host cognitive layer and oas:

- **must** cite this RFC and the matching RFC-0035 row.
- **must** split if the change is more than additive (dual PRs, masc
  side first, oas side second, oas pin bump third).
- **must not** change oas public API in the same week as a host-side
  cognitive PR that depends on it (let the pin lifecycle absorb one
  change at a time).

A PR that touches only oas cognitive surfaces (`context_intent`,
`agent_tool`, `typed_tool`, `autonomy_*`):

- should still cite this RFC for traceability.
- can ship without a host-side companion if the change is a strict
  internal refactor / docstring strengthening / test coverage.

## Proposed extensions (oas)

The following two extensions are the minimum to close the remaining
gaps. Both are **additive** — no public-API break.

### Extension A: `Context_intent.intent` adds a `Cognitive_op` variant

**Status**: proposed, **not** yet implemented.

`Context_intent.intent` currently has 5 variants:
`Conversational | Task_command | Status_check | Knowledge_query | Workspace`.

The host-side cognitive layer fires queries that don't fit any of these
cleanly — e.g. "rank these candidates by gravity", "predict next action".
A new variant `Cognitive_op` would let the host route those through
`context_intent` without misclassifying them as `Task_command` (which
triggers `Full` retrieval depth — wasteful for a pure ranking call).

This is a non-trivial change because `intent` is `[@@deriving yojson, show]`
and consumers may pattern-match it without a wildcard. Concrete steps:

1. Add the variant in `lib/context_intent.ml(.mli)`.
2. Update `intent_of_string` / `depth_for_intent` (default to `Skip`).
3. Update structured-output schema in `Context_intent.schema`.
4. Add 2 unit tests: round-trip, depth mapping.
5. Bump `0.190.x → 0.190.y` (minor — additive variant).

Risks: any downstream pattern-match without a wildcard breaks at the
type level. Search masc first for `Context_intent.intent` patterns
before opening this PR.

### Extension B: `Cognitive_event` SDK-side type

**Status**: proposed, **not** yet implemented.

The host-side `chronicle_event` (RFC-0035 PR-4) needs a transport-stable
event type. Today the host invents its own JSON; tomorrow if the SDK
itself wants to emit cognitive events (gravity rank, intent prediction,
mode transition), it has nowhere to put them.

Adding `lib/cognitive_event.{ml,mli}` to oas as a small typed module
gives both sides a shared schema:

```ocaml
(* sketch only — final shape per Extension B's PR *)
type cognitive_event =
  | Gravity_ranked of { ranked_count : int; query_terms : int }
  | Intent_predicted of { intent : Context_intent.intent; confidence : float }
  | Mode_transitioned of { from_ : string; to_ : string }
  | Disclosure_level of { level : int }
  [@@deriving yojson, show]
```

The host writes it, the SDK can later consume it via Hooks. No
behavioural change in this PR — purely a type definition and JSON
codec.

### Extensions explicitly NOT proposed

- Changing `Provider.config` to carry cognitive metadata. Out of scope;
  the cognitive surface should not leak into provider routing.
- Adding a `Cognitive_hook` to `Hooks`. Use the existing `Hooks` event
  shape; if expressivity is missing, a separate RFC covers it.
- Centralising version SSOT into one file. Both
  `scripts/sync-version-truth.sh` and `scripts/check-tag-drift.sh`
  already cover this; adding a third surface dilutes responsibility.

## Risks

1. **Hot-dep churn.** oas has been re-pinned ~5×/week through 2026-04
   into 2026-05. Every oas PR triggers a downstream chore(oas) bump.
   Both proposed extensions are additive precisely to keep the pin
   bump trivial.
2. **Master Report's confidence ladder is the author's.** This RFC
   adopts the routing manifest, not the prescription. Each oas PR
   stands on its own evidence gate, the same as RFC-0035.
3. **Extension A risks pattern-match drift on the host.** Mitigation:
   open a separate masc PR first that adds `| _ -> ...` wildcards
   in any host-side `Context_intent.intent` matches that don't already
   have one. Land that PR before Extension A's oas PR.

## Implementation plan (this RFC stack)

| PR | Repo | Topic | Status |
|----|------|-------|--------|
| RFC-0036 (this PR) | masc | docs only — record the manifest | this PR |
| RFC-0036 PR-A1 | masc | wildcard guard on `Context_intent.intent` matches (defensive prep for Extension A) | not started |
| RFC-0036 PR-A2 | oas | Extension A — `Cognitive_op` variant + tests + bump | not started |
| RFC-0036 PR-B | oas | Extension B — `Cognitive_event` type + JSON codec + bump | not started, can run independently |

PR-A1 must merge before PR-A2 lands in oas.
PR-B has no host-side dependency.

## Verification gates

This RFC is mergeable on docs-only criteria:

- The mapping table reflects what is actually in the listed files
  (verified by `bash scripts/verify_audit_claim.sh 1 'context_intent' .`
  and similar for the other modules — exactly one module surface per
  named file).
- No code change. No build change. No CI change.
- Self-review against `~/me/agents/best-programmer/AGENT.md` posted
  in the PR body.

Future PRs (PR-A1 / PR-A2 / PR-B) carry their own verification gates.
