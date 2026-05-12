# RFC-0055: Cascade Fallback Chain Capability-Tier Routing

**Status**: Superseded by RFC-0058 (declarative cascade config — RFC-0058 §1 / Supersedes ledger explicitly absorbs the capability-tier routing concern)  
**Author**: Agent (Claude Sonnet 4.6)  
**Date**: 2026-05-09 · Superseded 2026-05-11  
**Related**: RFC-0041 (hierarchical cascade config), RFC-0058 (declarative cascade config), PR #14358, PR #14360, 2026-05-04 ollama_bench incident

---

## 1. Problem Statement

The current `cascade.json` defines fallback chains that terminate in `local_recovery`, which is a capability dead-end for any turn requiring runtime MCP tools.

### 1.1 Dead-End Chain

`cascade.json` (live SSOT) contains three independent routes into the same sink:

| Line | Cascade | Fallback Target | `keeper_assignable` |
|------|---------|-----------------|---------------------|
| 30 | `big_three` | `local_recovery` | true |
| 92 | `retired_tool_profile` | `local_recovery` | true |
| 127 | `retired_fast_profile` | `retired_tool_profile` | true |

`local_recovery` (lines 67--73) exposes a single model:

```json
{ "model": "ollama:qwen3.6:27b-coding-nvfp4", "weight": 1 }
```

with `keeper_assignable: false` and no further fallback.

### 1.2 Runtime Gate Rejection

`lib/provider_tool_support.ml:160--249` evaluates tool-use eligibility per provider. The gate at line 195--199:

```ocaml
let runtime_mcp_caps_ok =
  caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events
in
if not runtime_mcp_caps_ok && not inline_path_ok then
  Some Runtime_mcp_caps_missing
```

Ollama (all variants) returns `supports_runtime_mcp_tools = false` because it is not an MCP server host. Therefore **every** turn that falls through to `local_recovery` and requires runtime MCP tools receives `Runtime_mcp_caps_missing` and fails.

### 1.3 Operational Impact

- **2026-05-04 incident** (`cascade.json:169` comment): `ollama_bench` escalation into the general keeper path hit the 600 s `MASC_KEEPER_TURN_TIMEOUT_SEC` ceiling. The fiber stayed in `with_timeout_exn` long enough that all 14 keepers entered the 60 s "peers holding slot" skip branch, producing **5,963 skip-turn events in 24 h** until manual restart.
- **2026-05-09 prod log** (09:35:20--09:50:36): `big_three` weighted random selected `claude:claude-sonnet-4-6` (weight 3) and `gemini:gemini-2.5-flash` (weight 4). Both failed with external errors (429 admin-disabled, insufficient balance, quota exceeded). Fallback to `local_recovery` produced 100% `Runtime_mcp_caps_missing` rejections. No terminal successful dispatch occurred.

The cascade system has no terminal fallback that satisfies the capability requirements of the original request.

---

## 2. Goals and Non-Goals

### Goals

1. **Structural guarantee**: A cascade chain must terminate in a model set that satisfies the capability requirements of the original request, or in an explicit terminal `Sink` that signals unrecoverable failure.
2. **Compile-time enforcement**: It must be impossible to configure an `Assignable` cascade whose fallback points to a `Sink` or to a cascade with mismatched capabilities.
3. **Operational visibility**: Every fallback hop must emit a structured event (not just a counter) containing the capability mismatch reason, so operators can trace the chain.

### Non-Goals

- Adding new providers or models. This RFC uses existing catalog entries.
- Changing the liveness guard (TTFT, inter-chunk idle, max token) values. Layer D is a separate concern.
- Fixing Layer B (`worker_oas.ml` thinking + tool_choice mutex). That is RFC-0055-followup or a separate RFC.

---

## 3. Workaround Rejection Bar (Explicit)

This RFC explicitly refuses the following four workaround patterns per `~/me/instructions/software-development.md`:

1. **Telemetry-as-fix**: Adding a Prometheus counter for `local_recovery` rejection rate makes the failure visible but does not fix the dead-end.
2. **String/substring classifier**: Adding a `starts_with ~prefix:"ollama:"` guard in the fallback router is a string classifier where a typed capability check belongs.
3. **N-of-M patch**: Fixing `big_three` fallback only, leaving `retired_tool_profile` and `retired_fast_profile` unchanged, is an N-of-M patch.
4. **Cap/cooldown/dedup/repair**: Raising the `ollama_bench` timeout or adding a cooldown between fallback attempts suppresses the symptom without resolving the structural issue.

---

## 4. Design

### 4.1 Phantom-Typed Cascade Definition

Introduce a GADT that separates cascades that can be assigned to keepers from terminal cascades that cannot:

```ocaml
(* cascade_tier.ml *)

type assignable
and sink

(* phantom-typed cascade identifier *)
type 'a cascade_id = private string

(* model_entry is unchanged from current definition *)
type model_entry = {
  model : string;
  weight : int;
  supports_tool_choice : bool option;
}

type _ cascade_def =
  | Assignable : {
      id : assignable cascade_id;
      models : model_entry list;
      fallback : assignable cascade_id;
      (* capability contract: what this cascade guarantees *)
      min_capability : Capability_set.t;
    } -> assignable cascade_def
  | Sink : {
      id : sink cascade_id;
      models : model_entry list;
      (* terminal: no fallback; failure is explicit *)
    } -> sink cascade_def
```

### 4.2 Capability Monotonicity Invariant

The fallback arrow must be monotonic with respect to capability sets:

```ocaml
let fallback_monotonic (src : assignable cascade_def) (dst : assignable cascade_def) : bool =
  Capability_set.is_subset src.min_capability dst.min_capability
```

A cascade whose `min_capability` requires `runtime_mcp_tools` cannot fall back to a cascade whose `min_capability` lacks it. This check runs at config load time (not per-request) and fails fast with a typed error.

### 4.3 Terminal Sink for Unrecoverable Failure

The existing `local_recovery` is reclassified as a `Sink`:

```ocaml
let local_recovery : sink cascade_def =
  Sink {
    id = ("local_recovery" :> sink cascade_id);
    models = [
      { model = "ollama:qwen3.6:27b-coding-nvfp4"; weight = 1; supports_tool_choice = None };
    ];
  }
```

No assignable cascade may point to a `sink cascade_id`. The only way to reach a `Sink` is via an explicit terminal dispatch decision, not via fallback.

### 4.4 New Assignable Terminal Cascade

Introduce a new assignable cascade that serves as the **true** fallback for runtime-MCP-capable requests. It contains only models that satisfy `runtime_mcp_caps_ok`:

```ocaml
let retired_tool_profile : assignable cascade_def =
  Assignable {
    id = ("retired_tool_profile" :> assignable cascade_id);
    models = [
      { model = "claude_code:auto"; weight = 3; supports_tool_choice = Some true };
      { model = "glm-coding:auto"; weight = 2; supports_tool_choice = Some true };
      { model = "kimi_cli:kimi-for-coding"; weight = 1; supports_tool_choice = Some true };
    ];
    fallback = ("retired_fast_profile" :> assignable cascade_id);
    min_capability = Capability_set.of_list [ Runtime_mcp_tools; Inline_tools; Tool_choice ];
  }
```

`retired_fast_profile` fallback is preserved but its own fallback is changed to a new assignable terminal cascade `retired_cloud_profile` (see Migration).

### 4.5 JSON Config Validation

At config load time (`cascade_catalog_runtime.ml` or equivalent):

1. Parse all cascade definitions into the GADT.
2. Run `fallback_monotonic` on every `Assignable` edge.
3. If any edge violates monotonicity, fail with `Cascade_config_invalid` containing the violating pair.
4. Verify that no `Assignable` fallback references a `Sink`.

---

## 5. Migration Plan

### 5.1 Target Topology

```
big_three ──► retired_tool_profile ──► retired_fast_profile ──► retired_cloud_profile
                                                    │
                                                    ▼
                                                (terminal: no fallback)

local_recovery ──► [Sink, no keeper_assignable]
```

Where `retired_cloud_profile` is a new assignable cascade containing only cloud providers that are known to satisfy `runtime_mcp_caps_ok`:

```json
{
  "retired_cloud_profile_models": [
    { "model": "claude_code:auto", "weight": 3, "supports_tool_choice": true },
    { "model": "glm-coding:auto", "weight": 2, "supports_tool_choice": true },
    { "model": "kimi_cli:kimi-for-coding", "weight": 1, "supports_tool_choice": true }
  ],
  "retired_cloud_profile_temperature": 0.2,
  "retired_cloud_profile_max_tokens": 30000,
  "retired_cloud_profile_keeper_assignable": true,
  "retired_cloud_profile_strategy": "weighted_random",
  "retired_cloud_profile_fallback_cascade": null
}
```

`null` fallback means terminal: no further fallback, explicit failure.

### 5.2 Per-Cascade Changes

| Cascade | Current Fallback | New Fallback | Rationale |
|---------|-----------------|--------------|-----------|
| `big_three` | `local_recovery` | `retired_tool_profile` | Preserve cloud-capable path |
| `retired_tool_profile` | `local_recovery` | `retired_fast_profile` | Continue down the capability-preserving chain |
| `retired_fast_profile` | `retired_tool_profile` | `retired_cloud_profile` | Break the cycle; point to terminal cloud-only cascade |
| `local_recovery` | N/A | N/A (Sink) | Remove from assignable set; only explicit non-tool dispatch may use it |

### 5.3 Backward Compatibility

- Existing `cascade.json` files without the new `retired_cloud_profile` section will fail validation at load time with a typed error, not silently default.
- The `admission` table (lines 178--362) does not reference `local_recovery` directly; no admission changes required.
- `ollama_bench` and `ollama_only` keep their direct cascade override path; they are unaffected because they bypass the assignable_set gate.

---

## 6. Verification

### 6.1 TLA+ Bug Model

Apply the TLA+ Bug Model pattern from `software-development.md`:

- **`BugAction`**: A config loader that permits an `Assignable -> Sink` fallback edge.
- **`SafetyInvariant`**: `NoAssignablePointsToSink` -- for all `c` in `Assignable`, `c.fallback` is in `Assignable`.
- **`Next` (clean)**: Config loader enforces GADT + monotonicity.
- **`NextBuggy`**: `Next \/ BugAction`.
- **Expected**: Clean config passes; buggy config violates `NoAssignablePointsToSink`.

### 6.2 Property Tests

1. **Monotonicity**: For random capability sets `A` and `B`, generate random cascade definitions. Assert that every fallback edge satisfies `is_subset`.
2. **Cycle freedom**: Build a directed graph from fallback edges. Assert it is a DAG (no cycles).
3. **Sink terminality**: Assert that no path from any `Assignable` root reaches a `Sink`.

### 6.3 Integration Tests

1. **Config load rejection**: Provide a config where `big_three.fallback = "local_recovery"`. Assert load fails with `Cascade_config_invalid`.
2. **Happy path dispatch**: Mock all cloud providers as available. Assert a runtime-MCP request succeeds without touching `local_recovery`.
3. **All-cloud-down path**: Mock all cloud providers as returning 429. Assert the request reaches `retired_cloud_profile`, exhausts its models, and returns an explicit `No_available_provider` error (not a silent skip).

### 6.4 Smoke Test

- Start a dev server with the migrated config.
- Run a single keeper turn that requires `runtime_mcp_tools`.
- Verify in logs that fallback hops emit structured events with `from_cascade`, `to_cascade`, and `capability_check` fields.

---

## 7. Open Questions

1. **RFC-0041 mesh**: RFC-0041 introduced hierarchical cascade config + TOML groups. How does the GADT validation interact with group-level overrides? Does a group override that changes `fallback` re-trigger monotonicity checking?
2. **Terminal fallback necessity**: Is `retired_cloud_profile` (a terminal assignable cascade) actually required, or should `retired_fast_profile` itself become terminal? The trade-off is between "one more retry layer" and "simpler topology".
3. **Layer B interaction**: `worker_oas.ml` has a known thinking + tool_choice mutex on Sonnet 4.6/Opus 4.6/4.7. If `big_three` currently routes to these models and the mutex causes a request-level failure, the fallback chain is exercised more frequently. Should Layer B be fixed before or concurrently with this RFC?

---

## 8. References

- `~/me/.masc/config/cascade.json` (live SSOT, lines 30, 67--73, 92, 127, 169)
- `lib/provider_tool_support.ml` (lines 160--249, runtime capability gate)
- `docs/tla-audit/state-fsm-gap-2026-04-13.md` (P1/P3/P4 proposals)
- RFC-0041: Hierarchical cascade config + TOML groups (PR #14358, merged 2026-05-08)
- `~/me/instructions/software-development.md` (Workaround Rejection Bar, TLA+ Bug Model)
- 2026-05-04 incident note: `cascade.json:169` (`ollama_bench` 600 s ceiling, 14 keepers, 5,963 skip-turn events)
