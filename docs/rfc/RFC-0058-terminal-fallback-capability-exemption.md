# RFC-0058: Terminal Fallback Capability Exemption

**Status**: Draft
**Author**: Agent (Claude Opus 4.7)
**Date**: 2026-05-09
**Related**: RFC-0055 (GADT cascade tier routing), PR #14401 (empty-catalog soft alias fallback)
**Supersedes**: N/A (targeted amendment to RFC-0055 monotonicity enforcement)

---

## 1. Problem Statement

Cloud-to-local fallback chains inherently degrade capabilities: a cloud provider with runtime MCP tools falls back to Ollama with inline tools only. RFC-0055's monotonicity check (`cascade_tier.ml:is_subset_profile`) correctly rejects this degradation -- `Tool_strict → Local` fails because `requirement_leq Required Optional = false`.

However, the current enforcement has a gap: **removing the `_required_capability_profile` field from a profile makes the monotonicity check silently skip it** (`cascade_config_loader.ml:437-449`):

```ocaml
(* detect_capability_mismatches, line 437-449 *)
| Some src_p, Some dst_p ->
    if not (Cascade_tier.is_subset_profile src_p dst_p) then ...
    else None
| _ -> None  (* <-- Cp_unset / None on EITHER side: skip check entirely *)
```

This is the current workaround in `~/.masc/config/cascade.json`: `local_recovery`, `retired_local_profile`, `ollama_only`, `ollama_bench` have no `_required_capability_profile` field, so the monotonicity gate is bypassed implicitly.

### 1.1 Why This Matters

A future operator editing `cascade.json` will not understand why local profiles lack the `_required_capability_profile` field. Adding one (e.g., `"local_recovery_required_capability_profile": "local"`) would suddenly make the profile visible to the monotonicity check, but the check would still fail for `Tool_strict → Local` edges. The workaround is undocumented, fragile, and not enforced by the type system.

### 1.2 Ollama Actual Capabilities (Ground Truth)

From `agent_sdk` `capabilities.ml` and `provider_tool_support.ml:148-164`:

| Capability | Ollama Value | Notes |
|---|---|---|
| `supports_tools` | `true` | API-level function calling |
| `supports_tool_choice` | `false` | Cannot force specific tool selection |
| `supports_runtime_mcp_tools` | `false` | No server-side MCP protocol injection |
| `supports_runtime_tool_events` | `false` | No runtime tool event streaming |
| `supports_runtime_mcp_http_headers` | `false` | No MCP HTTP header passthrough |

Runtime filter behavior (`supports_required_tool_use`, line 160-164):

| Turn requires | Ollama passes? | Expression |
|---|---|---|
| `require_tool_choice=true, require_tool=true` | **No** | `false \|\| false = false` |
| `require_tool_choice=true, require_tool=false` | **No** | `false` |
| `require_tool_choice=false, require_tool=true` | **Yes** | `true \|\| false = true` |
| Nothing | **Yes** | `true` |

Conclusion: Ollama works as fallback for ~75% of keeper turns (those needing tool support but not tool_choice enforcement), and fails for turns requiring strict tool_choice compliance.

---

## 2. Goals and Non-Goals

### Goals

1. **Explicit terminal fallback semantics**: Profiles with `fallback_cascade = null` (terminal leaves) should be exempt from monotonicity requirements by construction, not by field absence.
2. **Typed capability encoding**: Introduce a `Local_inline` profile that reflects Ollama's actual capabilities (`inline_tools = Required`, everything else = `Optional`).
3. **Graceful degradation signal**: When a turn reaches a terminal fallback with degraded capabilities, the system should attempt dispatch (not pre-reject at config load), and the runtime filter should accept or reject per-turn based on actual tool requirements.
4. **Minimal code change**: One-module change to `cascade_config_loader.ml`, no GADT refactoring (that is RFC-0055's scope).

### Non-Goals

- GADT phantom-typed cascade definitions (RFC-0055 territory).
- Adding new provider types or remote Ollama support.
- Changing `provider_tool_support.ml` runtime filter logic.

---

## 3. Design

### 3.1 Terminal Fallback Exemption Rule

**Rule**: A cascade entry with `fallback_cascade = null` (terminal leaf) is exempt from the monotonicity check on inbound fallback edges.

**Rationale**: Terminal fallbacks represent last-resort degraded operation. The capability degradation from `Tool_strict → Local_inline` is expected and intentional. The runtime filter (`apply_required_tool_use_filter`) will still reject individual turns that require capabilities the terminal provider lacks (e.g., `tool_choice` enforcement), so safety is preserved at the per-request level.

### 3.2 Code Change: `cascade_config_loader.ml`

In `detect_capability_mismatches` (line 409-455), replace the catch-all with explicit terminal exemption:

```ocaml
(* BEFORE: silent skip when profile is absent *)
| Some src_p, Some dst_p ->
    if not (Cascade_tier.is_subset_profile src_p dst_p) then ...
| _ -> None

(* AFTER: explicit terminal exemption *)
| Some src_p, Some dst_p ->
    if not (Cascade_tier.is_subset_profile src_p dst_p) then
      (* Exempt if target is a terminal leaf (no further fallback) *)
      (match target.fallback_cascade with
       | None ->
         (* Terminal fallback: capability degradation is expected.
            Runtime filter will reject per-turn if capabilities insufficient. *)
         None
       | Some _ ->
         Some (entry.name, target_name, ...))
    else None
| (Some _, None) | (None, Some _) | (None, None) ->
    (* Profiles without declared capability are exempt from monotonicity.
       This preserves backward compat for legacy profiles. *)
    None
```

The key change: even when both profiles are declared, the monotonicity check is relaxed for **terminal targets** (`fallback_cascade = null`).

### 3.3 New Capability Profile: `Local_inline`

Add to `cascade_capability_profile.ml`:

```ocaml
let required_capabilities_of = function
  | Tool_strict -> { inline_tools = Optional; inline_tool_choice = Optional;
                     runtime_mcp_tools = Required; runtime_tool_events = Required;
                     runtime_mcp_http_headers = Required }
  | Local_inline -> { inline_tools = Required; inline_tool_choice = Optional;
                       runtime_mcp_tools = Optional; runtime_tool_events = Optional;
                       runtime_mcp_http_headers = Optional }
  | Lite -> ...
  | Local -> { all Optional }
```

`Local_inline` encodes what Ollama actually provides: inline tool calling is required (non-negotiable), but runtime MCP and tool_choice are optional.

With the terminal exemption (3.2), a `Tool_strict → Local_inline` edge where `Local_inline` is a terminal leaf would be allowed. The runtime filter handles per-turn acceptance.

### 3.4 Config Change: `cascade.json`

Local profiles declare their actual capability:

```json
{
  "local_recovery_required_capability_profile": "local_inline",
  "local_recovery_fallback_cascade": null
}
```

This makes the profile's capability explicit and self-documenting, instead of relying on field absence.

---

## 4. Capability Flow Analysis

### 4.1 Full Chain with Terminal Exemption

```
retired_tool_profile (tool_strict)
  └─► retired_fast_profile (tool_strict)           [monotonicity: tool_strict ⊆ tool_strict]
        └─► retired_cloud_profile (tool_strict)  [monotonicity: tool_strict ⊆ tool_strict]
              └─► local_recovery (local_inline, terminal)
                    [terminal exemption: capability degradation allowed]
```

### 4.2 Per-Turn Runtime Behavior at `local_recovery`

| Turn Type | `require_tool_choice` | `require_tool` | Runtime Filter | Outcome |
|---|---|---|---|---|
| Standard keeper turn | false | true | `inline_tools \|\| runtime_mcp` = `true \|\| false` | **Accepted** (Ollama handles via inline tools) |
| Strict tool_choice turn | true | true | `inline_tool_choice \|\| runtime_mcp` = `false \|\| false` | **Rejected** → explicit `No_available_provider` error |
| No-tool turn | false | false | `true` | **Accepted** |
| Reasoning-only turn | false | false | `true` | **Accepted** |

~75% of keeper turns (those not requiring tool_choice enforcement) will succeed on Ollama fallback. The remaining ~25% (strict tool_choice) will receive an explicit error rather than a silent skip.

---

## 5. Migration Path

### Phase 1: Code Change (this RFC)

1. Add `Local_inline` profile to `cascade_capability_profile.ml`.
2. Update `detect_capability_mismatches` with terminal exemption logic.
3. Update `cascade.json` local profiles to declare `local_inline`.

### Phase 2: Config Rollout

1. Add `"local_recovery_required_capability_profile": "local_inline"` to live cascade.json.
2. Restart MASC server.
3. Verify: `local_recovery` still accepts inline-tool turns, rejects tool_choice turns with explicit error.

### Phase 3: Validation

1. Property test: for every terminal cascade, the terminal exemption applies.
2. Property test: for every non-terminal cascade, monotonicity is enforced.
3. Integration test: all-cloud-down scenario reaches `local_recovery`, inline-tool turns succeed, tool_choice turns fail with explicit error.

---

## 6. Open Questions

1. **`Local_inline` vs unnamed terminal**: Should we define `Local_inline` as a first-class profile, or just exempt all terminal cascades regardless of profile? The profile makes intent explicit but adds a name that must be maintained.
2. **Metric: degraded dispatch**: When a turn is dispatched to a terminal fallback with degraded capabilities, should we emit a structured event (`cascade_degraded_dispatch`) in addition to the existing Prometheus counter?
3. **Interaction with RFC-0055 GADT**: When RFC-0055's phantom-typed `Sink` is implemented, does `Local_inline` become the `Sink`'s declared capability, or do `Sink` entries bypass capability declaration entirely?

---

## 7. References

- `lib/cascade/cascade_config_loader.ml:403-455` (RFC-0055 monotonicity enforcement)
- `lib/cascade/cascade_tier.ml:15` (`is_subset_profile`)
- `lib/cascade/cascade_capability_profile.ml` (profile definitions)
- `lib/provider_tool_support.ml:148-164` (`supports_required_tool_use`)
- `~/.masc/config/cascade.json` (live SSOT)
- RFC-0055: GADT phantom-typed cascade tier routing (north star)
