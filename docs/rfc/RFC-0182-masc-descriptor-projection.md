---
title: masc_* Workspace Tool Descriptor Projection + Tool_spec SSOT Consolidation
rfc: "0182"
status: Draft
created: 2026-05-26
updated: 2026-05-26
author: vincent
supersedes: []
superseded_by: null
related: ["0064", "0179"]
implementation_prs: []
---

# RFC-0182 — masc_* Workspace Tool Descriptor Projection + Tool_spec SSOT Consolidation

Status: Draft · Architectural framing, no code yet
Related: RFC-0064 (LLM-native two-surface tool model), RFC-0179 (keeper_* descriptor coverage)

> Renumber note: This RFC was authored and merged as RFC-0181 (PR #18726, 2026-05-26 11:39 UTC). PR #18697 (capability/intent-based runtime SSOT, OPEN/Draft) had previously claimed the 0181 slot. The 0181 collision was resolved by renumbering this document to 0182; user-authored #18697 retains 0181. All other content is unchanged from the merged body.

## 0. Problem framing

RFC-0179 (PR #18710, 2026-05-26 merged) brought `keeper_*` workspace collaboration tools — 39 entries — under the `Agent_tool_descriptor.t` projection layer. `internal_descriptors` grew from 1 to 39, `Agent_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome` lost its legacy match chain (12 arms → 0), and 38 additional tools began emitting `route_evidence_json` per call.

A 2026-05-26 audit found that `masc_*` MCP-public workspace collaboration tools — the surface MASC agents call most heavily (`masc_bind`, `masc_broadcast`, `masc_heartbeat`, `masc_messages`, `masc_board_*`) — have **0 descriptor coverage**:

| Layer | Count | Descriptor-backed |
|---|---|---|
| LLM-native public (RFC-0064) | 7 | 7 (100%) |
| `keeper_*` workspace collaboration (RFC-0179) | 39 | 39 (100%) |
| `masc_*` MCP-public workspace collaboration | **124** | **0 (0%)** |
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

- Workspace: `masc_bind`, `masc_unbind`, `masc_broadcast`, `masc_messages`, `channel_gate`
- Execution: `masc_execute`, `masc_execute_dry_run`
- Portal: `masc_portal_open`, `masc_portal_close`, `masc_portal_send`
- Approval queue access is no longer a MASC tool surface.
- Admin/destructive: `masc_admin_cleanup`, `masc_admin_reset`, `masc_gc_force`, `masc_workspace_delete`, `masc_force_unbind`, `masc_set_param`, `masc_spawn`, `masc_tool_revoke`

Three observations:

1. **No architectural reason for the split**. The handler_binding distribution across the 103 registered tools is 100% `Tag_dispatch` (Direct/Shared/Match_chain unused in practice — `Match_chain` is a dead enum case). The 21 unregistered tools dispatch through the same MCP path; they simply lack the Tool_spec metadata wrapper.

2. **Asymmetric ratchet coverage**. Tool_spec-registered tools participate in catalog metadata invariants. Metadata-only entries do not. Any future ratchet on the registration SSOT will silently skip these 21, hiding regressions in exactly the tools agents touch most.

3. **Same RFC-0182 work surface**. Adding `Agent_tool_descriptor.t` projection requires resolving each tool's identity (name, schema, executor target, policy). For the 21 unregistered tools, this is the same work as `Tool_spec.register`. Splitting into RFC-0182 (descriptors for 103) + a follow-up RFC (Tool_spec migration for 21) would duplicate effort and leave the surface inconsistent in the interim — the exact `[feedback_codex_partial_sweep_fan_out_anti_pattern]` shape.

This RFC bundles both: 124 tools get `Agent_tool_descriptor.t` projection, and the 21 metadata-only tools get `Tool_spec.register` migration in the same PR.

## 2a. Post-body-merge audit (2026-05-26)

After the body merged (PR #18726 → renumber #18731), a 5-prong dead/live audit (`.tmp/masc-21-metadata-only-dead-audit-2026-05-26.md`) examined each of the 21 metadata-only tools across (1) qualified-name grep, (2) handler-function grep, (3) facade re-export / `include Module`, (4) test fixture, (5) prompt/config text. Result: **7 dead, 12 live, 2 ambiguous**.

| Verdict | Tools | Decision |
|---|---|---|
| **dead** (no handler, no live caller) | `masc_execute`, `masc_execute_dry_run`, `masc_admin_cleanup`, `masc_admin_reset`, `masc_gc_force`, `masc_workspace_delete`, `masc_force_unbind` | delete tool_catalog metadata; do not migrate |
| **dead** (after ambiguous decision) | `masc_spawn` (dispatch explicitly removed with comment `"masc_spawn removed: vendor-specific agent spawning belongs to OAS domain"` at `mcp_tool_runtime.ml:287`; metadata and test fixture left behind) | delete metadata + test fixture (completes the in-progress cleanup) |
| **live** | `masc_bind`, `masc_unbind`, `masc_broadcast`, `masc_messages`, `channel_gate`, `masc_set_param`, `masc_tool_revoke` (7 tools) | migrate to `Tool_spec.register`; descriptor projection added |
| **deferred** (separate RFC) | `masc_portal_open`, `masc_portal_close`, `masc_portal_send` | live, but dispatch is at `mcp_server_eio_protocol.ml` protocol level — not in-process. This RFC's cluster-variant pattern does not fit. Tracked for a separate RFC (RFC-0183 candidate). Excluded from this RFC's scope. |

Q2 (`channel_gate`) and Q3 (`masc_set_param`) — initially flagged for removal in §11 open questions — are now confirmed live by the audit (HTTP subsystem dispatch at `server_routes_http_routes_channel_gate.ml` and `server_routes_http_routes_activity.ml:with_tool_auth` respectively). They are migrated to `Tool_spec.register`, not removed. `masc_set_param` retains its current `Hidden` visibility (`hidden_active` semantics preserved through `Tool_spec.create ~visibility:Hidden`).

The 8 dead tools + 3 portal-deferred tools reduce the scope from "21 migration + 124 projection" to **"10 migration + 113 projection + 8 dead delete + Match_chain remove + portal-RFC stub"**.

## 3. Approach

### 3.1 Descriptor projection (113 tools)

> Scope updated from 124 to 113 per §2a audit: −8 dead (deleted, not projected) −3 portal trio (deferred to separate RFC).

Add 113 entries to `internal_descriptors` in `lib/keeper/agent_tool_descriptor.ml`. Cluster variants reuse RFC-0179's pattern: tools that share a typed dispatcher (e.g. `Tool_board_registry.tools` for board_*, `tool_agent.ml` for agent_*) get a single `Tool_*_dispatch` runtime_handler variant routed by `descriptor.internal_name`.

| Cluster | Tools | Cluster variant |
|---|---|---|
| `masc_board_*` (incl. sub_board) | ~20 | `Tool_masc_board_dispatch` |
| `masc_keeper_*` / `masc_persona_*` | ~19 | `Tool_masc_keeper_dispatch` |
| `masc_plan_*` / `masc_note_*` | ~8 | `Tool_masc_plan_dispatch` |
| `masc_workspace_*` (workspace status/heartbeat/goal) | ~8 | `Tool_masc_workspace_dispatch` |
| `masc_task_*` | ~7 | `Tool_masc_task_dispatch` |
| `masc_operator_*` | ~6 | `Tool_masc_operator_dispatch` |
| `masc_run_*` | ~4 | `Tool_masc_run_dispatch` |
| `masc_agent_*` | ~5 | `Tool_masc_agent_dispatch` |
| `masc_library_*` | ~5 | `Tool_masc_library_dispatch` |
| `masc_shard_*` (tool_grant/revoke) | ~2 | `Tool_masc_shard_dispatch` |
| `masc_local_runtime_*` | ~2 | `Tool_masc_local_runtime_dispatch` |
| `masc_agent_timeline` | 1 | `Tool_masc_agent_timeline` |
| Singletons (`masc_bind`, `masc_broadcast`, `masc_execute`, etc.) | ~32 | individual variants |

The direct workspace-control cluster described by the original draft has since
been removed. Workspace control now enters through the typed operator action
descriptor and confirmation path; it has no independent dispatch variant.

> Update (2026-06-09): the `masc_run_*` cluster dropped from 6 to 4
> tools — `masc_run_log` and `masc_run_deliverable` were removed (0
> recorded writes in fleet logs; the surviving `init`/`plan`/`get`/`list`
> cover run tracking). The `~N` per-cluster counts above are live
> approximations; the net-new totals are the point-in-time projection
> at RFC authoring and are left as the historical record.

The In_process handler for each cluster routes to the existing typed dispatcher — no logic is moved out of `tool_board_dispatch.ml`, `tool_task.ml`, etc. The descriptor layer is a *projection*, not a relocation.

### 3.2 Tool_spec consolidation (7 live tools)

> Scope updated from 21 to 7 per §2a audit and the 2026-06-04 approval surface removal. Dead tools handled in §3.3; portal trio deferred to RFC-0183 candidate.

Each of the 10 live metadata-only tools gets a corresponding `Tool_spec.register` call placed in the most semantically-appropriate `tool_*.ml` module:

| Tool | Proposed module | Q3 visibility |
|---|---|---|
| `masc_bind`, `masc_unbind`, `masc_broadcast`, `masc_messages`, `channel_gate` | `mcp_tool_runtime.ml` (Mod_inline) | `Default` (preserved) |
| `masc_set_param` | `mcp_tool_runtime.ml` | **`Hidden`** (preserved from current `hidden_active`, Q3 decision) |
| `masc_tool_revoke` | `tool_shard.ml` (Mod_shard) — existing `masc_tool_grant` is registered here | `Default` (preserved) |

All 7 use `handler_binding = Tag_dispatch` to match the existing 103-tool norm. Permission metadata (`required_permission = Some Masc_domain.CanXxx`) is preserved as-is — moved from raw `tool_catalog.ml` entries to `Tool_spec.create ~required_permission`.

Q1 (module layout) resolution: existing dispatchers only. Audit found existing dispatchers (`mcp_tool_runtime.ml`, `tool_shard.ml`) already host functionally-adjacent registrations. New single-purpose modules would proliferate files and violate `[feedback_radical_improvement_over_diff_size]` (avoid unnecessary file growth in user-of-one codebase). `masc_set_param` stays with `mcp_tool_runtime.ml`.

### 3.3 Dead tool metadata + test cleanup (8 tools)

> New section per §2a audit.

Delete from `lib/tool_catalog.ml` (per-tool entry rows) and from any test fixture that locks the tool name:

```
masc_execute            — no handler, no dispatch, no live caller
masc_execute_dry_run    — no handler, no dispatch, no live caller
masc_admin_cleanup      — no handler, no dispatch, no live caller
masc_admin_reset        — no handler, no dispatch, no live caller
masc_gc_force           — no handler, no dispatch, no live caller
masc_workspace_delete        — no handler, no dispatch, no live caller
masc_force_unbind        — no handler, no dispatch, no live caller
masc_spawn              — dispatch explicitly removed (mcp_tool_runtime.ml:287
                          comment `"masc_spawn removed: vendor-specific agent
                          spawning belongs to OAS domain"`), metadata+test left
                          behind. This RFC completes the cleanup.
```

For each dead tool the impl PR also deletes:
- the row in `tool_catalog.ml`
- any `test/test_*.ml` fixture that asserts the tool's existence or metadata shape
- any prompt/config string that names it (audit confirms: none of the 8 have prompt/config references, so this step is precautionary)

This is *deletion*, not deprecation — there are no live callers to migrate.

### 3.4 Portal trio deferred to separate RFC

> New section per §2a audit decision.

`masc_portal_open`, `masc_portal_close`, `masc_portal_send` are live but dispatch at `mcp_server_eio_protocol.ml` (protocol-level pattern match), not at the in-process tool dispatcher. RFC-0182's cluster-variant + In_process passthrough model does not fit — they would need a new executor variant (e.g. `Protocol_dispatch`) or a different abstraction.

A follow-up RFC (RFC-0183 candidate) will design the portal projection separately. RFC-0182's impl PR adds a brief note in `Agent_tool_descriptor` source comments pointing forward to the deferred portal work. No descriptor or Tool_spec changes for the 3 portal tools in this RFC.

### 3.5 Match_chain dead-code removal

`Tool_spec.handler_binding.Match_chain` is unused across all 103 registrations and across the new 10 migrations. Remove it from the variant in the same PR. This is the structural root-fix the audit signal points to: an unused dispatch path that suggests legacy match-chain dispatch still exists in `masc_*`, which is now demonstrably false.

## 4. Output parity

Each cluster handler returns the JSON output its current dispatcher produces, byte-for-byte. Outcome (`Success`/`Failure`) is inferred via `Tool_result.classify_tool_result_payload` — same pattern as RFC-0179. No handler emits new fields, no schema changes.

## 5. Invariants preserved

- `List.length public_descriptors = 7` (RFC-0064 hard-cut). Unaffected.
- `test_alias_table_is_stable` continues to pass.
- `Agent_tool_runtime.handle` remains structurally exhaustive across the expanded `runtime_handler` (~58 variants × 4 executors). Compiler enforces no missing cases.
- `Agent_tool_descriptor.descriptors_for_internal` continues to walk `all_descriptors () = public_descriptors @ internal_descriptors`. Unique `internal_name` per descriptor → deterministic resolution. Audit step: assert no `internal_name` collision between keeper_* (39) and masc_* (113).
- `Tool_catalog` permission/visibility metadata for the 10 migrated tools is preserved (transferred to `Tool_spec.create` args). `masc_set_param` keeps `Hidden` visibility per §2a Q3 decision.

## 6. Receipt observability gain

Before: 113 `masc_*` tools emit `tool_descriptor_summary` (PR #18723) with `descriptor_id = None`. Route evidence is empty.
After: 113 emit per-call descriptor_id, executor=in_process (cluster passthrough), visibility, readonly classification. Aligns with the receipt projection landed in #18723. (8 dead tools deleted, so they no longer appear in receipt streams at all. 3 portal tools remain `descriptor_id = None` until RFC-0183.)

## 7. Risk & rollback

| Risk | Detection | Mitigation |
|---|---|---|
| Cluster variant misroutes (descriptor.internal_name mismatched against runtime_handler dispatch table) | Compiler exhaustiveness on each Tool_*_dispatch handler match | Per-cluster unit test verifies every tool in the cluster resolves to the cluster handler and dispatches to the right typed function |
| 7-tool migration introduces handler_binding semantics mismatch | `dune build --root . lib/` + existing tool_catalog invariant tests | All 7 use `Tag_dispatch` matching the existing 103 norm. Audit confirmed 100% Tag_dispatch across all live registrations |
| `internal_name` collision between `keeper_*` and `masc_*` | Test assertion: `List.sort_uniq String.compare (List.map (fun d -> d.internal_name) (all_descriptors ()))` length equals total list length | Resolve any collision by renaming the masc_* entry to its true canonical (the keeper_* set is fixed by RFC-0179) |
| PR size (estimated 1200-1800 LoC after dead-tool delete reduces additions) makes review hard | PR body has cluster-by-cluster diff summary; cluster handlers are mechanically isomorphic | Diff size is intentional per `[feedback_radical_improvement_over_diff_size]` for a user-of-one codebase. Single PR, single rebase, single CI pass |
| 8 dead-tool delete removes a row that some forgotten consumer relies on | `rg <tool_name>` audit (§2a 5-prong) — all 5 paths empty except for tool_catalog.ml self-row | Audit results pinned in `.tmp/masc-21-metadata-only-dead-audit-2026-05-26.md`; impl PR re-runs the same grep before delete to guard against drift since 2026-05-26 |
| Portal trio deferral leaves 3 tools without descriptors → asymmetric coverage | Tracked as known gap, resolved by RFC-0183 candidate | Explicit `descriptor_id = None` is acceptable interim state; receipt projection (#18723) already handles `None` gracefully |

Rollback: revert is a single PR revert. RFC-0179 set the precedent — squash merge, descriptor entries added en bloc, can be reverted en bloc. No data migration, no on-disk schema, no replay.

## 8. Workaround Rejection Bar self-check

| Signature | Hit? |
|---|---|
| §1 Telemetry-as-fix | No — descriptors are not counters; they are projection of typed metadata that enables typed dispatch and per-call receipt. |
| §2 String/substring classifier | No — descriptors *remove* string-match dispatch (RFC-0179 retired `match name with "keeper_*"` chain). This RFC continues that direction; it does not add new substring matching. |
| §3 N-of-M | **Risk addressed**. The Explore matrix surfaces 21 partial-sweep candidates (the metadata-only set). The RFC bundles 10 live migrations + 8 dead deletions into one PR. The 3 portal-trio tools are deferred to a separate RFC on *architectural* grounds (different dispatch layer), not partial-sweep grounds — that distinction is explicit per §3.4. |
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
| 1 | RFC-0182 body | PR #18726 (merged 2026-05-26 11:39 UTC as RFC-0181) + #18731 (renumber 0181→0182, merged 2026-05-26 11:46 UTC). |
| 1a | RFC-0182 scope update (this document) | Post-body audit results (§2a) folded in. §3.1/§3.2/§3.3/§3.4/§3.5 reflect 113+10+8+3-deferred+Match_chain scope. |
| 2 | Single big-bang implementation PR | 113 descriptor entries + ~39 runtime_handler variants + 10 Tool_spec.register migrations + 8 dead-tool metadata deletes (including `masc_spawn` test fixture cleanup) + Match_chain removal + invariant tests |
| 3 | Closeout: flip RFC-0182 status from Draft → Implemented, add the implementation PR number to `implementation_prs:` frontmatter, audit `scripts/audit-rfc-closeout-lag.sh`. |
| 4 (separate) | RFC-0183 candidate: portal trio descriptor model (protocol-level dispatch layer). |

Implementation PR target diff: ~1200-1800 LoC, ~8-9 files (`agent_tool_descriptor.ml`, `agent_tool_descriptor.mli`, `agent_tool_in_process_runtime.ml`, `agent_tool_in_process_runtime.mli`, `agent_tool_runtime.ml`, `agent_tool_runtime.mli`, `tool_spec.ml` (remove Match_chain), `tool_spec.mli`, `tool_catalog.ml` (delete 8 dead rows), `mcp_tool_runtime.ml` (add 9-10 registrations), `tool_shard.ml` (add masc_tool_revoke), test files affected by dead-tool cleanup).

## 11. Open questions — resolved

The original §11 had three open architectural questions. The post-merge audit (§2a) and user decision chain resolved them as follows:

- **Q1 (module layout)** — *resolved*: existing dispatchers only. Keep approval dispatch in the keeper-owned surface (`Keeper_tool_surface` / `Keeper_tool_in_process_runtime`) and reuse `tool_shard.ml` for shard tools (existing `masc_tool_grant` lives there). `masc_set_param` stays with `mcp_tool_runtime.ml`. Rationale in §3.2.
- **Q2 (`channel_gate` rename)** — *resolved*: keep as-is. The audit (§2a) confirmed `channel_gate` is live with HTTP subsystem dispatch (`server_routes_http_routes_channel_gate.ml`). Renaming would force prompt/persona/config updates with no architectural benefit; the unconventional name is preserved for backward compatibility. Migration is to `Tool_spec.register` only.
- **Q3 (`masc_set_param` visibility)** — *resolved*: keep `Hidden`. The audit confirmed live HTTP dispatch with admin auth (`server_routes_http_routes_activity.ml:with_tool_auth`). Visibility-level isolation reflects the original design intent (internal HTTP runtime-parameter mutation route). Registered as `Tool_spec.create ~visibility:Hidden ~required_permission:(Some CanAdmin)`.

## 12. Phase 5 — Eio plumbing for remaining 10 tools (post-#18823)

After PR #18823 (21 descriptors via dispatch-ref pattern, 83% non-portal coverage), the remaining 10 unprojected tools all require Eio resources (`sw`, `clock`, `proc_mgr`, `net`, `mcp_session_id`) that are not present in the current `Keeper_dispatch_ref.dispatch` / `Workspace_dispatch_ref.dispatch` / `Persona_dispatch_ref.dispatch` signatures.

### 12.1 Tools blocked on Eio context

| Tool | Eio dependency | Backing function |
|---|---|---|
| `masc_keeper_up` | `start_keepalive ~sw ~clock` | `Keeper_keepalive.start_keepalive` (lib/keeper/keeper_keepalive.ml:451) |
| `masc_keeper_msg` | `Keeper_msg_async.submit ~clock ~sw` + Turn dispatch | `Tool_keeper_ops.handle_keeper_msg` (lib/tool_keeper_ops.ml:438) |
| `masc_keeper_sandbox_status` | `load_or_materialize_boot_meta` (clock-aware) | `Tool_keeper.handle_keeper_sandbox_status` |
| `masc_keeper_create_from_persona` | `execute_keeper_up` → Turn lifecycle | `Tool_keeper_ops.handle_keeper_create_from_persona` |
| `masc_persona_generate` | retired on main | no backing function |
| `masc_operator_snapshot` | `Operator_control.context` (sw/clock/proc_mgr/net/mcp_session_id) | `Tool_operator.dispatch` |
| `masc_operator_digest` | same | same |
| `masc_operator_action` | same | same |
| `masc_operator_confirm` | same | same |
| `masc_operator_judgment_write` | same | same |

### 12.2 Decision: signature extension OR ctx record extension

**Option A — Per-ref signature extension** (incremental):
- Extend `Keeper_dispatch_ref.dispatch` from `(~config ~agent_name ~name ~args)` to also accept `~sw ~clock ~proc_mgr ~net ~mcp_session_id`.
- Create `Operator_dispatch_ref` mirroring the full operator ctx.
- Existing registrations accept-and-ignore the new params.
- Pro: localized per-cluster.  Con: each new field forces every existing registration to accept-and-ignore — N×M edit pressure.

**Option B — `Agent_tool_runtime.ctx` Eio extension** (recommended):
- Add fields to `Agent_tool_runtime.context`:
  ```ocaml
  ; sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option
  ; mcp_session_id : string option
  ```
- Caller (`Agent_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome`) constructs the full ctx from the existing keeper Eio context.
- `Agent_tool_in_process_runtime.handle_masc_keeper` (and new `handle_masc_operator`) receive these via the existing handler signature pattern: `~config ~meta ~sw ~clock ~proc_mgr ~net ~name ~args`.
- Cycle-safety preserved: `Agent_tool_runtime.ctx` already imports Eio types — adding fields adds no new module deps.
- Pro: one structural change unlocks the remaining keeper/operator tools.  Con: signature ripple across the affected handler dispatch arms in `Agent_tool_runtime.handle_in_process`.

**Recommendation: Option B.**  Single ctx extension, hits OCaml record-update sites once.  The operator cluster can use this without dispatch-ref indirection if its backing modules stay late enough to import directly.

### 12.3 Per-cluster wiring after ctx extension

| Cluster | Mechanism | Notes |
|---|---|---|
| `masc_keeper_{up,msg,sandbox_status,create_from_persona}` | Keeper_dispatch_ref signature extension (Tool_keeper-side registration) | Same dispatch-ref pattern; ref signature adds `~sw ~clock ~proc_mgr ~net` |
| `masc_operator_*` (5) | New `Operator_dispatch_ref` OR direct `Tool_operator.dispatch` import | Tool_operator is in lib/, sits LATE.  Direct import from Agent_tool_in_process_runtime closes cycle (Tool_operator → Operator_control → Keeper_runtime → ...).  Use dispatch-ref. |

### 12.4 Estimated PR sizes

| Phase 5 sub-PR | LoC estimate | Files | Risk |
|---|---|---|---|
| PR-A: ctx Eio extension | ~50 | 2 (agent_tool_runtime.ml/.mli + Agent_tool_dispatch_runtime caller) | low (compile-error-driven ripple) |
| PR-B: keeper Eio cluster (4 tools) | ~150 | 4 (Keeper_dispatch_ref sig extend + Tool_keeper register + handler + descriptor) | medium |
| PR-C: operator cluster (5 tools) | ~200 | 4 (Operator_dispatch_ref new + Tool_operator register + handler + 5 descriptors) | medium |

Each sub-PR independently mergeable, gated by PR-A.

### 12.5 Coverage target

| Stage | Active routing |
|---|---|
| Phase 5 base (PR #18823 merged) | 87/105 (83%) |
| After PR-A + PR-B | 91/105 (87%) |
| After PR-C | 92/105 (88%) |
| After PR-D | 97/105 (92%) |
| Remaining 8 | 6 MCP-surface only + 2 public_descriptors (architecturally not internal-callable) |

**Effective ceiling: ~92%** without RFC-0183 (portal trio).  6 MCP-surface tools (broadcast/join/leave/messages/start/who) are by design only callable from the MCP transport surface, not from inside a keeper's tool dispatch loop.  2 public_descriptors (web_search/web_fetch) are already projected via the LLM-native surface (RFC-0064).

### 12.6 Audit findings record (Phase 5 prereqs)

From the 17-iter /loop session that built PR #18823:

1. `Eio_guard.with_mutex` (Eio.Mutex.create) — pure inside [`Keeper_status_detail`](../../lib/keeper/keeper_status_detail.ml).  Did NOT block status projection.
2. Persona authoring schema/save/generate surfaces are retired on main; persona creation now routes through `masc_keeper_create_from_persona`, and the former persona-generate turn-driver cycle has no backing function.
3. `Keeper_turn_up.handle_keeper_up` surface ctx.config-only BUT `start_keepalive` transitively requires Eio.  Cannot ctx-free.
4. `handle_keeper_repair` carried `ignore (ctx.sw, ctx.clock, ctx.config)` warning-suppression scaffolding — was phantom dependency, real body returns stub.

### 12.7 Out of Phase 5 scope

- RFC-0183 (portal trio): protocol-level dispatch design.
- `masc_set_param` (HTTP route only — not internal-callable).
- `masc_session` (Mcp_tool_runtime with `load/save_mcp_sessions` callbacks — caller-injected closures, not ctx Eio fields).

---

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
