# RFC-0273: Dashboard-driven keeper config & runtime persistence

> **Status**: Draft
> **Authors**: vincent (with Claude Opus 4.8)
> **Created**: 2026-06-21
> **Related RFCs**: RFC-0038-phase-2-keeper-identity-canonical (persona/instructions = canonical keeper identity), RFC-0038-runtime-routing-intent-preservation (model/runtime resolved from runtime.toml assignment, not free meta fields), RFC-0233-turn-observability-execution-identity (execution identity), RFC-0254-shell-ir-approval-autonomous-policy + RFC-0199-evidence-driven-auto-approval (operator-auth gating precedent), RFC-0019-keeper-credential-unification (identity/credential boundary)
> **Anchor commit**: `4e52542f29` (#21898 — gate approvals through dashboard operator auth: the auth precedent for dashboard write paths)

## 1. Problem

The v2 dashboard ships keeper-config and Settings panels whose **Save is a no-op**. Grounded inventory against `main` (2026-06-21):

| Surface | Symptom | Evidence |
|---|---|---|
| Settings "Save changes" | local-state only; no backend write | `dashboard/src/components/settings-surface.ts:380,541` |
| Settings VerifyBtn | 700ms fake `setTimeout` → ok, no endpoint call | `settings-surface.ts:226-240` |
| V2 keeper config save | `kcp-save` button has no `onClick`; 0 `fetch`/api calls; persona/instr/model/rt/perm all local `useState` | `dashboard/src/components/keeper-config-panel-v2.ts:144-148,241-243` |
| V2 keeper config tool-permission rows | generic `Record<string, boolean>` toggles, **not** keyed by `masc_*` tool names | `keeper-config-panel-v2.ts:111` (`Object.keys(perm)`) |
| Keeper detail page | still imports the v1 config panel | `keeper-detail-page.ts:9` |

The only existing keeper-config write path is `POST /api/v1/keepers/:name/tools` with a single stringly action `"set_policy"` that updates `tool_access`/`tool_denylist` and persists via `Keeper_meta_store.write_meta_with_merge` (CAS) (`lib/server/server_dashboard_http_keeper_api_post.ml:74-116`). There is **no** write path for persona, instructions, or model/runtime assignment.

For runtime.toml, the backend already has two reusable write surfaces:

- `POST /api/v1/runtime/config/raw` (`lib/server/server_routes_http_routes_dashboard.ml:347-370`) — validates and saves raw runtime.toml text via `Runtime.save_config_text`, then reloads. This is the write counterpart of the read-only resolved runtime-defaults endpoint added by `#21903`.
- `Runtime.set_runtime_id_for_keeper` (`lib/runtime/runtime.ml:666-685`) — validates, edits the `[[runtime.assignments]]` table atomically, and reloads.

This RFC defines the dashboard-facing structured endpoints that reuse these existing functions, plus the Tier A keeper_meta write actions and panel reshape.

This RFC defines the backend write paths + the panel reshape needed to make these Saves real, with the correct identity/host_config boundaries and operator-auth gating.

## 2. Boundary & invariants (the hard constraints)

### 2.1 `persona ⊥ {model, runtime}` (the load-bearing invariant)

`lib/keeper/keeper_meta_contract.ml:675` documents and the type at `:484` enforces:

- `keeper_meta` directly holds `persona : string option`, `instructions : string`, `social_model : string`, `tool_access : string list`, `tool_denylist : string list`.
- **`model`/`runtime` are NOT free `keeper_meta` fields.** A keeper's runtime is assigned in `runtime.toml`; the model/provider identity is *resolved* from that assignment (falling back to the default runtime / persona profile `model`).

Consequence: the v2 panel's *persona / instructions / tool-permission* edits write **keeper_meta** (per-keeper, CAS-safe); its *model / runtime* dropdowns write the **runtime.toml keeper→runtime assignment** (host_config, global routing). These are two different stores with two different risk tiers and MUST NOT be collapsed into one write.

### 2.2 OAS boundary

This is entirely MASC-side config-persistence orchestration. OAS owns provider/model/transport/turn-lifecycle and is not touched. The model/runtime assignment written here is the MASC routing *intent*; OAS resolves it at turn time (RFC-0038-runtime-routing-intent-preservation).

### 2.3 Two risk tiers

| Tier | Store | Scope | Pattern |
|---|---|---|---|
| **A — keeper_meta** | `Keeper_meta_store.write_meta_with_merge` | one keeper | established (set_policy), CAS-merge preserves heartbeat counters |
| **B — runtime.toml** | host_config write + reload | global routing (all keepers) | new; atomic write + `Runtime.reload`; higher gate |

## 3. Design

### 3.1 Tier A — keeper_meta config writes (persona / instructions / tool permissions)

Replace the single stringly `"set_policy"` action with a **typed action sum** so the compiler enforces exhaustiveness and unknown actions are rejected (not coerced to a permissive default):

```ocaml
type keeper_config_action =
  | Set_policy of { tool_access : string list; tool_denylist : string list }
  | Set_persona of string option
  | Set_instructions of string
(* parse from JSON: unknown action -> Error, never a silent default *)
```

- Each action parses a **typed payload**, validates its concrete invariants, and produces an updated `keeper_meta`, persisted via the existing `write_meta_with_merge ~merge:heartbeat_fields_from_disk` CAS path. This generalizes the proven `set_policy` flow rather than adding a parallel one.
- **Tool-permission panel reshape (gap #304):** the panel's `perm` becomes `masc_*`-tool-keyed rows (tool name + risk badge from the tool descriptor registry + access toggle) instead of generic `Record<string, boolean>`. Only then does `perm` map onto `tool_access`/`tool_denylist`. `tool_access` entries are validated against the known masc tool-name set; **unknown tool names are rejected** (`Error`), never silently accepted (AI anti-pattern §2 "unknown → permissive default").
- Validation: `persona`/`instructions` length bounds; `tool_access ⊆ known_masc_tools`; `tool_denylist` likewise.

### 3.2 Tier B — runtime.toml writes (model/runtime assignment + Settings runtime-defaults)

Tier B reuses the existing runtime write surfaces instead of reimplementing them.

#### 3.2.1 Keeper→runtime assignment

A new structured dashboard endpoint `POST /api/v1/keepers/:name/runtime-assignment`:

- Request body: `{ "runtime_id": "provider.model" }`.
- Handler extracts the keeper name, validates `runtime_id`, and calls the existing `Runtime.set_runtime_id_for_keeper ~keeper_name:name ~runtime_id` (`lib/runtime/runtime.ml:666-685`).
- `Runtime.set_runtime_id_for_keeper` already performs: TOML load → table edit → `Fs_compat.save_file_atomic` → validation → `init_default` reload.
- Response: `{ "ok": true, "keeper_name": "...", "runtime_id": "..." }` on success; structured error on failure.
- The v2 panel's model/runtime dropdowns use this endpoint to set the routing *intent* (RFC-0038-runtime-routing-intent-preservation). Unknown `runtime_id` is rejected without writing (fail-closed, RFC-0001).

#### 3.2.2 Settings runtime-defaults editor

The existing `POST /api/v1/runtime/config/raw` endpoint is reused for Settings "Save changes":

- The Settings panel fetches the current resolved defaults via `GET /api/v1/dashboard/runtime-defaults` (#21903) and, when an operator edits them, posts the updated raw `runtime.toml` text to `POST /api/v1/runtime/config/raw`.
- That endpoint validates via `Runtime.save_config_text` and atomically persists + reloads.
- If the Settings UI needs a structured default-runtime editor later, it can be added as a thin wrapper over `Runtime.save_config_text` rather than a parallel parser/writer.

#### 3.2.3 Concurrency and gating

- `Runtime.set_runtime_id_for_keeper` and `Runtime.save_config_text` already use `Fs_compat.save_file_atomic` and `init_default` reload. The reload swaps the in-memory `Atomic.t` singletons, so in-flight keeper admission reads either the old or the new config, never a torn write.
- Concurrent writes to `runtime.toml` from two operators are a risk that remains to be addressed (see §8 open question). A short-term mitigation is to document "last write wins" and require operator coordination; a follow-up may add file-level locking or a version/CAS field.
- This is the highest-risk surface (global routing). It is gated stricter than Tier A (§3.3) and behind a feature flag for rollout (§7).

### 3.3 Auth / operator gating

All write endpoints sit behind **dashboard operator auth**, following the precedent set by `#21898` (gate approvals through dashboard operator auth). Without operator auth the endpoint returns `401`, never a silent allow. Tier B (runtime.toml, global) additionally requires the operator action to be logged to the governance trail.

### 3.4 VerifyBtn

Replace the fake `setTimeout` with a **read-only** verify endpoint that probes the selected runtime's reachability (provider/model resolvable, endpoint live) and returns a typed `{ ok; detail }`. No write, no credential exposure (mask per RFC-0132). This is independent of Tier A/B and can ship first.

## 4. Scope & non-goals

**In scope:** the typed keeper_meta write actions (§3.1), the runtime.toml write endpoint + reload (§3.2), operator-auth gating (§3.3), the verify endpoint (§3.4), the panel reshape to masc-tool-keyed permissions, and wiring the v2 panel + Settings Save to these endpoints (incl. swapping `keeper-detail-page.ts:9` to the v2 panel once persistence lands).

**Out of scope:** dashboard design-fidelity CSS (the `.turn-*`/`.fl-*`/`.lg-*` namespace + visual spec work — a separate design-SSOT wave); any OAS change; approvals decision-model (covered by #21886 / its own RFC).

## 5. Dependencies

- `#21903` resolved runtime-defaults read endpoint (the read counterpart of §3.2).
- `Keeper_meta_store.write_meta_with_merge`, `Keeper_meta_merge.heartbeat_fields_from_disk` (CAS path, Tier A).
- `Runtime.set_runtime_id_for_keeper` and `Runtime.save_config_text` (existing Tier B write surfaces).
- `Runtime.reload` / runtime.toml parser + `Fs_compat.save_file_atomic` (already used by the functions above).
- RFC-0038-runtime-routing-intent-preservation (intent preservation on Tier B writes).
- Operator-auth middleware from `#21898`.

## 6. Verification

- **Round-trip tests** per action: read → write (Set_persona/Set_instructions/Set_policy) → read returns the written value; CAS merge preserves heartbeat counters under a concurrent simulated turn write.
- **Rejection tests**: unknown action → `Error`; `tool_access` with an unknown tool name → `Error` (not accepted); missing operator auth → `401`.
- **Tier B**: `POST /api/v1/keepers/:name/runtime-assignment` round-trip: write → `Runtime.runtime_id_for_keeper` returns the assigned id; unknown `runtime_id` returns error without writing; `POST /api/v1/runtime/config/raw` still validates, saves atomically, and reloads. Runtime.toml write is atomic (no torn read), `Runtime.reload` re-resolves singletons, routing intent preserved (assigned runtime survives reload); rollback on parse failure.
- **TLA+ (optional)**: model runtime.toml write/reload vs in-flight keeper admission as a small concurrency spec (writer swaps singleton; reader never observes a partially-applied config) — bug-model per the TLA+ contract (clean: no torn read; buggy: `TornConfigRead` invariant violated).

## 7. Rollout & risk

- **Order**: §3.4 VerifyBtn (read-only, lowest risk) → §3.1 Tier A keeper_meta writes → §3.2 Tier B runtime.toml writes (feature-flagged, operator-logged).
- **Workaround rejection** (CLAUDE.md bar): no stringly action dispatch (typed sum, exhaustive match); no permissive unknown-tool/unknown-action default; no telemetry-as-fix. Tier B silent-substitution is explicitly forbidden (RFC-0001).
- **Risk**: Tier B edits global routing — a bad write can misroute every keeper. Mitigations: atomic write + validated parse + reload + operator-auth + governance log + feature flag; ship Tier A first to de-risk the pattern.

## 8. Open questions

1. Tier B: should keeper→runtime assignment live in `runtime.toml` (current SSOT) or migrate to a typed host_config store? This RFC assumes runtime.toml (no migration); a follow-up may revisit.
2. Concurrent `runtime.toml` writes: two operators editing assignments or defaults simultaneously can race. Should we add cross-process file locking, a version/CAS field, or serialize through a single writer fiber/process?
3. Should persona edits trigger re-derivation of persona-profile defaults (model fallback), or is persona purely descriptive once a runtime is assigned? Per §2.1 `persona ⊥ {model,runtime}`, this RFC treats persona as descriptive; assignment is explicit via Tier B.
