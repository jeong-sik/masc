---
rfc: "0080"
title: "Tool registry SSOT — collapse 15-fold OR membership into typed Tool_name boundary"
status: Draft
created: 2026-05-14
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0070", "0072"]
implementation_prs: [15207,15268,15271]
---

# RFC-0080 — Tool registry SSOT

## 1. Problem statement

Production keeper boot emits ≈540 warn lines per session matching `groups.<name>: tool '<tool>' is not registered` (older binaries) / `is not a known policy tool` (current `main` after PR #14513). Across one production log window (37 533 lines, 2 boot sessions on 2026-05-13) the warn covers **88 distinct tool names** including high-traffic surface (`keeper_pr_create`, `keeper_board_search`, `masc_status`, `masc_goal_list`, `masc_code_write`, `keeper_voice_*`, `extend_turns`, etc.).

The warn is *load-time* validation in `lib/keeper/keeper_tool_policy_config.ml:319-321`, fired once per boot per offending entry in `tool_policy.toml`. It does **not** prevent the tool from dispatching at runtime — `tool_call tool=masc_code_git outcome=ok` co-exists with `groups.coding: tool 'masc_code_git' is not registered`. The warn and the runtime are talking past each other.

The mismatch is structural, not a typo. `is_known_policy_tool_name` (lib/keeper/keeper_tool_policy_config.ml:225-239) currently union-checks across **15 independent sources of truth**:

```ocaml
let is_known_policy_tool_name name =
  let normalized = Keeper_tool_alias.strip_mcp_masc_prefix name in
  Tool_dispatch.is_registered normalized                              (* 1  *)
  || Option.is_some (Tool_name.of_string normalized)                  (* 2  *)
  || Option.is_some (Keeper_tool_alias.route normalized)              (* 3  *)
  || Keeper_tool_alias.is_known_internal normalized                   (* 4  *)
  || Option.is_some (Keeper_tool_alias.public_masc_to_internal n)     (* 5  *)
  || List.mem normalized (Keeper_tool_registry.keeper_internal_…)     (* 6  *)
  || List.mem normalized (Keeper_tool_registry.effective_core_tools ()) (* 7 *)
  || List.mem normalized Keeper_tool_registry.keeper_admin_dispatched (* 8  *)
  || List.mem normalized (tool_schema_names …all_keeper_tool_schemas) (* 9  *)
  || Tool_catalog_surfaces.is_on_surface Public_mcp     normalized    (* 10 *)
  || Tool_catalog_surfaces.is_on_surface Spawned_agent  normalized    (* 11 *)
  || Tool_catalog_surfaces.is_on_surface Local_worker   normalized    (* 12 *)
  || Tool_catalog_surfaces.is_on_surface Admin          normalized    (* 13 *)
```

Symptoms this produces:

- **Warn-as-fix antipattern.** Boot dumps a long warn list; some tools still dispatch fine (the union eventually accepts them at *runtime call* via a different code path), others would fail late. The warn alone neither prevents dispatch nor proves the entry is dead. It is a counter, not a fix.
- **Reader cannot answer "is this tool live?"** A reader who greps a name has to chase 5+ files to determine which source admits it. The list mutates across PRs (most recently #14513, #15051, #15092).
- **N-of-M migration risk.** Several historical PRs add tool surfaces one at a time across catalog/alias/dispatch — exactly the workaround #3 pattern CLAUDE.md flags. Without a single SSOT, future surface additions can be silently partial.

## 2. Current architecture (audit)

```
                    ┌── S2. Tool_name.t (lib/tool_name.ml)                   ── 397 closed variant cases
                    │         Keeper sub-module (~48) + Masc sub-module (~100+)
                    │
                    │── S1. Tool_dispatch table (lib/tool_dispatch.ml)       ── Hashtbl (string, handler)
                    │         NOTE: empty at policy-load time; populated later
                    │         during server init. Tools known only to dispatch
                    │         will always produce a warn on boot.
                    │
                    │── S3-5. Keeper_tool_alias (lib/keeper/keeper_tool_alias.ml)
                    │         route (7 entries) / is_known_internal /
                    │         public_masc_to_internal / strip_mcp_masc_prefix
                    │
keeper preset       │── S6-8. Keeper_tool_registry (lib/keeper/keeper_tool_registry.ml)
in tool_policy.toml │         3 list APIs derived from tool_catalog_surfaces
       │            │         + hardcoded core_always list
       │            │
       ▼            │── S9. Tool_shard.all_keeper_tool_schemas               ── per-shard name extraction
   is_known_policy_tool_name ──────────────────┐
                    │                          │
                    │                          ▼
                    │     ┌─ S10-13. Tool_catalog_surfaces.is_on_surface     ── 8 surface variants total:
                    │     │      Public_mcp                                   ── only 4 checked at policy boundary;
                    │     │      Spawned_agent                                ── Session_min / Keeper_internal /
                    │     │      Local_worker                                 ── Keeper_denied / System_internal
                    │     │      Admin                                        ── are NOT checked here
                    │     └──────────────────────────────────────────────
                    │
                    ▼
        15-fold OR → "known" / "unknown" boolean
```

Split-brain: policy validation and runtime routing use **separate code paths**:

```
  Policy load (boot-time):
    is_known_policy_tool_name   ── 15 sources OR ──→ bool
    called at keeper_tool_policy_config.ml:319,328,336

  Runtime tool dispatch (call-time):
    keeper_tool_disclosure.ml   ── strip → masc_to_internal → route → is_known_internal
                                 ──→ Mcp_mapped | Route_hit | Already_internal | Miss
```

The two paths share some sources (`Keeper_tool_alias.*`) but diverge elsewhere. A tool that `Miss`-es at disclosure can still be `true` at policy validation (via a different source), and vice versa. This is the structural cause of the 540-warn / dispatch-ok split-brain.

There is no single point of truth for *"this tool name resolves to that handler"*. Each source admits a name on its own terms; the union covers reality only because each adds *something*. Removing any one source today would fail unknown for a chunk of policy entries.

`Tool_name.t` (397 closed variant cases) is the closest thing to a typed registry — but it is treated as *one input* to the OR, not as *the* admission gate.

## 3. Proposed solution

### 3.1 Direction

Collapse the 15-fold OR into **typed conversion at the policy load boundary**:

```ocaml
(* lib/keeper/tool_resolution.ml — new *)
type tried_source =
  | Dispatch_table                           (* S1 *)
  | Tool_name_variant                        (* S2 *)
  | Alias_route                              (* S3 *)
  | Alias_internal                           (* S4 *)
  | Alias_masc_to_internal                   (* S5 *)
  | Registry_internal_candidate              (* S6 *)
  | Registry_core_tools                      (* S7 *)
  | Registry_admin_dispatched                (* S8 *)
  | Shard_schema                             (* S9 *)
  | Surface of Tool_catalog_surfaces.surface (* S10-13 *)

type resolution =
  | Resolved of { canonical : string ; via : tried_source ;
                  surface : Tool_catalog_surfaces.surface option }
  | Alias_to of { from : string ; canonical : string ; via : tried_source }
  | Unknown of { name : string ; tried : tried_source list }

val resolve : string -> resolution
(* Parse, don't validate. *)
```

The 15 sources become *implementations of the resolution rule* hidden behind the `resolve` API. Callers (policy loader, dispatch table, catalog surfaces) stop touching the sources directly and call `resolve`. Boot-time validation becomes:

```ocaml
List.iter (fun raw ->
  match resolve raw with
  | Resolved _ | Alias_to _ -> ()
  | Unknown { name ; tried } ->
      (* explicit, typed reason — not "is not a known policy tool" *)
      Log.Keeper.warn "policy entry %s unresolved: %s" name
        (string_of_tried tried)
) policy_entries
```

### 3.2 Three-step migration

1. **`tool_resolution.ml` shim.** Wrap the existing 15-fold OR behind `resolve`, returning a uniform `resolution` value. **No behaviour change** — same admit/reject decisions, but every call site is now expressible as one of three typed outcomes. Single PR. Worktree: `rfc/0080/phase-1-shim`.
2. **Caller migration.** Replace each direct source check (`Tool_dispatch.is_registered`, `Tool_catalog_surfaces.is_on_surface`, …) at *policy validation* call sites with `resolve`. Other domains (runtime dispatch, schema export) keep their direct calls — they are not part of the SSOT collapse. Per-call-site PR pattern to keep diffs small; CI smoke retains 88-warn baseline ± 0 after each PR. Worktree: `rfc/0080/phase-2-callers/<call-site>`.
3. **Source pruning.** Once `resolve` is the only policy gate, walk the 15 sources to identify dead entries (admitted by exactly 0 sources after PR #14513/#15051/#15092 already trimmed several). Per-domain PR (alias, registry list, catalog surface) with explicit removal evidence in body. Worktree: `rfc/0080/phase-3-prune/<domain>`.

### 3.3 Non-goals

- Renumber/rename existing `Tool_name.t` cases. Keep canonical names stable.
- Restructure `tool_policy.toml` schema. Policy format unchanged.
- Touch runtime dispatch hot-path latency. `resolve` runs only at boot and at MCP ingress.
- Block existing dual-emit pattern (RFC-0072 typed sub-FSM transitions). Orthogonal to this RFC.

## 4. Verification

### 4.1 Per-phase gate

| Phase | Gate | Evidence |
|---|---|---|
| 1. shim | `boot warn count` unchanged within 1 % vs `origin/main` baseline | dune build + smoke boot |
| 2. callers | each call-site PR shows `git grep -nE 'Tool_dispatch\.is_registered\|Tool_catalog_surfaces\.is_on_surface' lib/keeper/keeper_tool_policy_config.ml` shrinking monotonically | PR body diff |
| 3. prune | each removed entry has 3-cross-check: (1) `git grep` 0 dispatch hits, (2) policy `boot warn 0`, (3) production log search shows ≤ 0 historical `tool_call tool=<name>` over 30 days | PR body + linked log query |

### 4.2 Workaround Rejection self-check

CLAUDE.md §워크어라운드 거부 기준:

| 시그니처 | 회피 방법 |
|---|---|
| Counter-as-fix (warn dump alone, no resolution) | Phase 1 shim **changes warn structure** from list-of-strings to typed `Unknown { tried = … }`. Reader sees *why* unknown, not just *that* unknown. Counter is bait. |
| String/substring 분류기 보강 | `Tool_name.of_string` already exhaustive over 397 cases. No new substring matcher added. Aliases stay in `Keeper_tool_alias` but are addressed through `Alias_to` typed outcome, not free-form string. |
| N-of-M 패치 (admits abstraction failure) | Phase 2 plan is *explicitly migration*, not "fix this one site." Each phase-2 PR body must declare ratio (e.g., *3/7 policy-loader sites migrated; remaining 4 in PR #N+1*). |
| Cap / cooldown / log dedup | None proposed. |
| Repair / sanitize at read | None. Resolution is at ingress, not at use. |

### 4.3 Symptom override

If a phase-2 caller migration breaks dispatch (regression: tool name previously admitted by source S, now rejected by `resolve` due to bug), revert that single PR — do *not* widen `resolve` until root cause is in `tool_resolution.ml`. Reverting is safer than expanding.

## 5. Risks

- **Test surface gap.** `is_known_policy_tool_name` is currently covered by load-time tests only. Phase 1 must add unit coverage per `tried_source` variant before Phase 2 begins, to catch regressions outside the smoke boot baseline.
- **Boot warn baseline mutation.** PR #14513 / #15051 / #15092 each shifted what counts as "known"; baseline must be captured at start of Phase 1 and re-anchored after each merge. Otherwise Phase 2 over/undershoots.
- **Alias map drift.** `Keeper_tool_alias.public_masc_to_internal` overlap with `Keeper_tool_alias.route` historically caused PR #13089 collision (MEMORY: `Types collision RESOLVED`). Phase 2 alias call-site migration must run after Phase 1 shim covers both, not before.

## 6. Implementation summary

To be filled at closeout. Each phase PR appends to this section.

## 7. Appendix — Empirical inventory

### 7.1 Production log evidence (2026-05-13)

Source: `<base-path>/.masc/logs/masc-mcp-8935.log`. 2 boot sessions, 540 `is not registered` lines, 88 distinct tool names.

Sample (full list in PR body of Phase 1):

```
extend_turns
keeper_bash
keeper_board_{cleanup,comment,curation_read,curation_submit,delete,get,list,post,search,stats,vote}
keeper_broadcast
keeper_context_status
keeper_fs_{edit,read}
keeper_library_{read,search}
keeper_memory_search
keeper_pr_{create,list,review_comment,review_read,review_reply,status}
keeper_preflight_check
keeper_shell
keeper_task_{claim,create,done,force_release,submit_for_verification}
keeper_tasks_{audit,list}
keeper_time_now
keeper_tool_search
keeper_tools_list
keeper_voice_{agent,listen,session_end,session_start,sessions,speak}
masc_add_task / masc_agent_card / masc_agents / masc_approval_pending /
masc_batch_add_tasks / masc_broadcast / masc_claim_next /
masc_code_{delete,edit,git,read,search,shell,symbols,write} /
masc_coordination_fsm_snapshot / masc_dashboard /
masc_goal_{list,review,transition,upsert,verify} /
masc_heartbeat / masc_join / masc_keeper_{list,msg,msg_result,status} /
masc_leave / masc_messages / masc_plan_get / masc_plan_get_task /
masc_status / masc_task_history / masc_tasks / masc_tool_help /
masc_transition / masc_web_search / masc_who /
masc_worktree_{create,list,remove}
```

### 7.2 88 × 15 matrix (deferred to Phase 1 PR)

Mechanical static analysis: for each of the 88 names, grep against each of the 15 sources and record hit/miss. Categorise into:

| Category | Definition |
|---|---|
| A. Multi-source admit | ≥ 2 sources admit. Healthy redundancy, candidate for source-pruning in Phase 3. |
| B. Single-source admit | Exactly 1 source admits. Fragile — phase-2 migration must keep that path. |
| C. Zero-source admit | 0 sources admit on current `main`. Dead entry in `tool_policy.toml`. Direct deletion candidate. |
| D. Alias-only | Admitted only via `Keeper_tool_alias.*`. Real handler exists under a different canonical name. |

Phase 1 PR includes the table as Appendix evidence.

### 7.3 Related history

- PR #14513 (`feat(keeper): validate tool policy config against tool registry at load time`, 2026-05-03~04) — introduced the boot-time validation that produces these warns.
- PR #15051 (`fix(keeper): validate policy tools against static routes`) — adjusted some `tool_policy.toml` entries.
- PR #15092 (`fix(keeper): separate noisy runtime diagnostics`) — split warn wording from `is not registered` to `is not a known policy tool`; production binary < 2026-05-14 still emits old wording.
- RFC-0070 (typed credential/identity boundary) — *related pattern*; same workaround-rejection lens applies.
- RFC-0072 (typed keeper sub-FSM transitions) — *related pattern*; closed sum type as the admission gate.
