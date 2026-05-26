---
title: masc_* Coordination Tool Descriptor Projection + Tool_spec SSOT Consolidation
rfc: "0181"
status: Draft
created: 2026-05-26
updated: 2026-05-26
author: vincent
supersedes: []
superseded_by: null
related: ["0064", "0179"]
implementation_prs: []
---

# RFC-0181 — masc_* Coordination Tool Descriptor Projection + Tool_spec SSOT Consolidation

Status: Draft · Architectural framing, no code yet
Related: RFC-0064 (LLM-native two-surface tool model), RFC-0179 (keeper_* descriptor coverage)

## 0. Problem framing

RFC-0179 (PR #18710, 2026-05-26 merged) brought `keeper_*` coordination tools — 39 entries — under the `Agent_tool_descriptor.t` projection layer. `internal_descriptors` grew from 1 to 39, `Keeper_exec_tools.execute_keeper_tool_call_with_outcome` lost its legacy match chain (12 arms → 0), and 38 additional tools began emitting `route_evidence_json` per call.

A 2026-05-26 audit found that `masc_*` MCP-public coordination tools — the surface MASC agents call most heavily (`masc_join`, `masc_broadcast`, `masc_heartbeat`, `masc_messages`, `masc_board_*`) — have **0 descriptor coverage**:

| Layer | Count | Descriptor-backed |
|---|---|---|
| LLM-native public (RFC-0064) | 7 | 7 (100%) |
| `keeper_*` coordination (RFC-0179) | 39 | 39 (100%) |
| `masc_*` MCP-public coordination | **124** | **0 (0%)** |
| **Total ecosystem (audited)** | **~286** | **46 (~16%)** |

The 124 figure comes from a registration-matrix audit (`/.tmp/masc-tool-registration-matrix-2026-05-26.md`) that cross-checked `Tool_spec.register` call sites against `tool_catalog.ml` metadata entries. It is 3 more than the 121 surfaced by match-arm grep — the gap is the audit anomaly this RFC also addresses.

## 1. Two layers, not one

`Tool_spec.t` (`lib/tool_spec.ml`, since 2.196.0) and `Agent_tool_descriptor.t` (`lib/keeper/agent_tool_descriptor.ml`) are not competing SSOTs. They are vertical layers sharing `Tool_catalog.{visibility, effect_domain}` as the cross-cut metadata:

```
┌─────────────────────────────────────────────────────────┐
│  Tool_catalog  (visibility / effect_domain / module_tag) │
└─────────────────────┬───────────────────────────────────┘
                      │ (shared metadata)
       ┌──────────────┴───────────────┐
       ▼                              ▼
┌────────────────────────┐  ┌────────────────────────────────┐
│ Tool_spec.t            │  │ Agent_tool_descriptor.t        │
│ Registration SSOT      │  │ Capability projection SSOT     │
│                        │  │                                │
│ - name, schema         │  │ - public_name / internal_name  │
│ - handler_binding:     │  │ - executor / backend / sandbox │
│   { Direct | Shared    │  │ - runtime_handler (19 today)   │
│   | Tag_dispatch       │  │ - policy (readonly, retryable) │
│   | Match_chain }      │  │                                │
│ - permission / dest.   │  │ "agent/LLM-facing"             │
│                        │  │                                │
│ MCP layer dispatch     │  │ Receipt / route_evidence       │
└────────────────────────┘  └────────────────────────────────┘
```

`Tool_spec` answers "how does this tool get registered and routed at MCP boundary?". `Agent_tool_descriptor` answers "what does the agent see, and what receipt does each call emit?". The two are orthogonal — a tool can have either, both, or neither, and `keeper_*` has only the second while `masc_*` has only (most of) the first.

This RFC adds the second layer to `masc_*`, *and* consolidates the first layer where it was skipped.

## 2. Anomaly: 21 tools skip Tool_spec.register

The registration matrix audit found 21 of 124 `masc_*` tools live as metadata-only entries in `tool_catalog.ml` without a corresponding `Tool_spec.register` call. They include high-traffic surface tools:

- Coordination: `masc_join`, `masc_leave`, `masc_broadcast`, `masc_messages`, `channel_gate`
- Execution: `masc_execute`, `masc_execute_dry_run`
- Portal: `masc_portal_open`, `masc_portal_close`, `masc_portal_send`
- Approval: `masc_approval_get`, `masc_approval_pending`, `masc_approval_resolve`
- Admin/destructive: `masc_admin_cleanup`, `masc_admin_reset`, `masc_gc_force`, `masc_room_delete`, `masc_force_leave`, `masc_set_param`, `masc_spawn`, `masc_tool_revoke`

Three observations:

1. **No architectural reason for the split**. The handler_binding distribution across the 103 registered tools is 100% `Tag_dispatch` (Direct/Shared/Match_chain unused in practice — `Match_chain` is a dead enum case). The 21 unregistered tools dispatch through the same MCP path; they simply lack the Tool_spec metadata wrapper.

2. **Asymmetric ratchet coverage**. Tool_spec-registered tools participate in catalog metadata invariants. Metadata-only entries do not. Any future ratchet on the registration SSOT will silently skip these 21, hiding regressions in exactly the tools agents touch most.

3. **Same RFC-0181 work surface**. Adding `Agent_tool_descriptor.t` projection requires resolving each tool's identity (name, schema, executor target, policy). For the 21 unregistered tools, this is the same work as `Tool_spec.register`. Splitting into RFC-0181 (descriptors for 103) + RFC-0182 (Tool_spec migration for 21) would duplicate effort and leave the surface inconsistent in the interim — the exact `[feedback_codex_partial_sweep_fan_out_anti_pattern]` shape.

This RFC bundles both: 124 tools get `Agent_tool_descriptor.t` projection, and the 21 metadata-only tools get `Tool_spec.register` migration in the same PR.

## 3. Approach

### 3.1 Descriptor projection (124 tools)

Add 124 entries to `internal_descriptors` in `lib/keeper/agent_tool_descriptor.ml`. Cluster variants reuse RFC-0179's pattern: tools that share a typed dispatcher (e.g. `Tool_board_registry.tools` for board_*, `tool_agent.ml` for agent_*) get a single `Tool_*_dispatch` runtime_handler variant routed by `descriptor.internal_name`.

| Cluster | Tools | Cluster variant |
|---|---|---|
| `masc_board_*` (incl. sub_board) | ~20 | `Tool_masc_board_dispatch` |
| `masc_keeper_*` / `masc_persona_*` | ~19 | `Tool_masc_keeper_dispatch` |
| `masc_plan_*` / `masc_note_*` | ~8 | `Tool_masc_plan_dispatch` |
| `masc_room_*` (coord status/heartbeat/goal) | ~8 | `Tool_masc_room_dispatch` |
| `masc_task_*` | ~7 | `Tool_masc_task_dispatch` |
| `masc_operator_*` | ~6 | `Tool_masc_operator_dispatch` |
| `masc_run_*` | ~6 | `Tool_masc_run_dispatch` |
| `masc_agent_*` | ~5 | `Tool_masc_agent_dispatch` |
| `masc_library_*` | ~5 | `Tool_masc_library_dispatch` |
| `masc_control_*` (pause/resume) | ~3 | `Tool_masc_control_dispatch` |
| `masc_shard_*` (tool_grant/revoke) | ~2 | `Tool_masc_shard_dispatch` |
| `masc_local_runtime_*` | ~2 | `Tool_masc_local_runtime_dispatch` |
| `masc_agent_timeline` | 1 | `Tool_masc_agent_timeline` |
| Singletons (`masc_join`, `masc_broadcast`, `masc_execute`, etc.) | ~32 | individual variants |

Net new `runtime_handler` variants: ~14 cluster + ~32 singletons = **~46**. Net new descriptor entries: **124**. After this RFC: `internal_descriptors` = 39 + 124 = **163**.

The In_process handler for each cluster routes to the existing typed dispatcher — no logic is moved out of `tool_board_dispatch.ml`, `tool_task.ml`, etc. The descriptor layer is a *projection*, not a relocation.

### 3.2 Tool_spec consolidation (21 tools)

Each of the 21 metadata-only tools gets a corresponding `Tool_spec.register` call placed in the most semantically-appropriate `tool_*.ml` module:

| Tool | Proposed module |
|---|---|
| `masc_join`, `masc_leave`, `masc_broadcast`, `masc_messages`, `channel_gate` | `tool_inline_dispatch.ml` (Mod_inline) |
| `masc_execute`, `masc_execute_dry_run` | `tool_control.ml` (Mod_control) |
| `masc_approval_*` (3) | new `tool_approval.ml` or `tool_inline_dispatch.ml` |
| `masc_portal_*` (3) | new `tool_portal.ml` or `tool_misc.ml` |
| `masc_admin_*` / `masc_gc_force` / `masc_room_delete` / `masc_force_leave` / `masc_set_param` / `masc_spawn` / `masc_tool_revoke` (8) | new `tool_admin.ml` or appropriate existing module |

All 21 use `handler_binding = Tag_dispatch` to match the existing 103-tool norm. Permission metadata is preserved as-is (the catalog already has it; we move it from raw entries to `Tool_spec.create ~required_permission`).

### 3.3 Match_chain dead-code removal

`Tool_spec.handler_binding.Match_chain` is unused across all 103 registrations and across the new 21 migrations. Remove it from the variant in the same PR. This is the structural root-fix the audit signal points to: an unused dispatch path that suggests legacy match-chain dispatch still exists in `masc_*`, which is now demonstrably false.

## 4. Output parity

Each cluster handler returns the JSON output its current dispatcher produces, byte-for-byte. Outcome (`Success`/`Failure`) is inferred via `Tool_result.classify_tool_result_payload` — same pattern as RFC-0179. No handler emits new fields, no schema changes.

## 5. Invariants preserved

- `List.length public_descriptors = 7` (RFC-0064 hard-cut). Unaffected.
- `test_alias_table_is_stable` continues to pass.
- `Agent_tool_runtime.handle` remains structurally exhaustive across the expanded `runtime_handler` (~65 variants × 4 executors). Compiler enforces no missing cases.
- `Agent_tool_descriptor.descriptors_for_internal` continues to walk `all_descriptors () = public_descriptors @ internal_descriptors`. Unique `internal_name` per descriptor → deterministic resolution. Audit step: assert no `internal_name` collision between keeper_* (39) and masc_* (124).
- `Tool_catalog` permission/visibility metadata for the 21 migrated tools is preserved (transferred to `Tool_spec.create` args).

## 6. Receipt observability gain

Before: 124 `masc_*` tools emit `tool_descriptor_summary` (PR #18723) with `descriptor_id = None`. Route evidence is empty.
After: 124 emit per-call descriptor_id, executor=in_process (cluster passthrough), visibility, readonly classification. Aligns with the receipt projection landed in #18723.

## 7. Risk & rollback

| Risk | Detection | Mitigation |
|---|---|---|
| Cluster variant misroutes (descriptor.internal_name mismatched against runtime_handler dispatch table) | Compiler exhaustiveness on each Tool_*_dispatch handler match | Per-cluster unit test verifies every tool in the cluster resolves to the cluster handler and dispatches to the right typed function |
| 21 migration introduces handler_binding semantics mismatch | `dune build --root . lib/` + existing tool_catalog invariant tests | All 21 use `Tag_dispatch` matching the existing 103 norm. If any of the 21 has a Direct/Shared handler in practice, the matrix audit flags it before code is written |
| `internal_name` collision between `keeper_*` and `masc_*` (unlikely but possible if a tool exists in both naming conventions) | Test assertion: `List.sort_uniq String.compare (List.map (fun d -> d.internal_name) (all_descriptors ()))` length equals total list length | Resolve any collision by renaming the masc_* entry to its true canonical (the keeper_* set is fixed by RFC-0179) |
| PR size (estimated 1500-2000 LoC) makes review hard | PR body has cluster-by-cluster diff summary; cluster handlers are mechanically isomorphic | Diff size is intentional per `[feedback_radical_improvement_over_diff_size]` for a user-of-one codebase. Single PR, single rebase, single CI pass |
| 21 tool migrations require a new `tool_*.ml` module (tool_approval, tool_portal, tool_admin) | Build break if name collides with existing file | Verify with `ls lib/tool_*.ml` before writing |

Rollback: revert is a single PR revert. RFC-0179 set the precedent — squash merge, descriptor entries added en bloc, can be reverted en bloc. No data migration, no on-disk schema, no replay.

## 8. Workaround Rejection Bar self-check

| Signature | Hit? |
|---|---|
| §1 Telemetry-as-fix | No — descriptors are not counters; they are projection of typed metadata that enables typed dispatch and per-call receipt. |
| §2 String/substring classifier | No — descriptors *remove* string-match dispatch (RFC-0179 retired `match name with "keeper_*"` chain). This RFC continues that direction; it does not add new substring matching. |
| §3 N-of-M | **Risk addressed**. The Explore matrix surfaces 21 partial-sweep candidates (the metadata-only set). The RFC explicitly bundles them into Phase 1 to avoid creating a `RFC-0182 = 21` follow-up that exhibits the exact anti-pattern. |
| §4 Cap / cooldown / dedup / repair | No — no caps added, no cooldowns, no dedup, no normalize-on-read. |
| §5 test backdoor | No — no `set_*_for_test` or `reset_for_test` surface added. |

## 9. Scope explicitly out

- LLM-native public-name surface (RFC-0064's 7) is unchanged.
- `dashboard_*` HTTP-route tools (~30) require a new executor variant (`Http_route` or equivalent) — separate RFC.
- Operator/control plane tools (`operator_*`, ~20) intersect with credential/identity subsystem — gated by `<agent_delegation>` in workflow rules. Separate RFC.
- Remote MCP passthrough (~80) is wire-string forwarding without local dispatch logic — descriptor projection adds no observable value. Out of scope.

## 10. Implementation order

| Step | PR | Scope |
|---|---|---|
| 1 | This document, **Draft RFC-0181 body** | RFC body only, no code. Architectural commit. |
| 2 | Single big-bang implementation PR | 124 descriptor entries + ~46 runtime_handler variants + 21 Tool_spec.register migrations + Match_chain removal + tests + invariant checks |
| 3 | Closeout: flip RFC-0181 status from Draft → Implemented, add the implementation PR number to `implementation_prs:` frontmatter, audit `scripts/audit-rfc-closeout-lag.sh`. |

Implementation PR target diff: ~1500-2000 LoC, ~10 files (`agent_tool_descriptor.ml`, `agent_tool_descriptor.mli`, `agent_tool_in_process_runtime.ml`, `agent_tool_in_process_runtime.mli`, `agent_tool_runtime.ml`, `agent_tool_runtime.mli`, `tool_spec.ml` (remove Match_chain), `tool_spec.mli`, new tool_approval/portal/admin modules, test files).

## 11. Open questions (resolve in implementation PR or as comments here)

- Q1: Should the 21 migrated tools each land in their own new module (`tool_approval.ml`, `tool_portal.ml`, `tool_admin.ml`) or be bundled into `tool_misc.ml` / `tool_inline_dispatch.ml`? Module proliferation vs. concentration trade-off.
- Q2: `channel_gate` does not follow the `masc_*` prefix convention. Should it be renamed to `masc_channel_gate` as part of consolidation, or kept as-is?
- Q3: The 21 metadata-only tools include `masc_set_param` flagged as `hidden_active` and `CanAdmin`-permissioned. Should it remain hidden after `Tool_spec.register` (i.e. registered but `Hidden`), or surface to public catalog? Implementer's choice unless there is a known external dependency on its hidden state.

---

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
