# Tool → Keeper Boundary Severance — Audit & Frozen Plan

**Date**: 2026-05-31
**Goal (user)**: "Tools 개념 Surface 정리 SSOT 로 가야하고 불필요/낭비/반복/무의미한 Wiring 제거. Tool 이 Keeper 를 알 필요가 전혀 없음."
**RFC status (honest)**: RFC-0084 enforced the Tool→Keeper direction for the dispatch
*path* only (`tool_dispatch.ml`, done). RFC-0194 §3 is the `dispatch_layer` taxonomy, **not**
this surface-wide invariant. RFC-0080 Phase 4 (source-membership pruning) is deferred and
covers the registry wiring, not the reverse-dependency calls. **No existing RFC owns the
surface-wide "a tool must not call a Keeper_ module" invariant** — 3 of 4 RFC-reader agents
in the 2026-05-31 audit found it unowned. Decision pending (§6): adopt a one-paragraph RFC, or
let this gate + plan doc stand as the contract. This PR does not stamp a misfit citation.

## 1. Verified scope (not a guess — measured)

The raw `rg 'Keeper'` count over `lib/**/tool_*.ml` is misleading. After excluding two
false-positive classes — (a) `Tool_name.Keeper` / `Keeper.` name-namespace constructors,
(b) `Keeper_internal` / `Keeper_denied` which are `Tool_catalog_surfaces.surface`
constructors, not keeper modules — and after stripping nested comments + string literals,
the real set is **12 tool-surface files that call a `Keeper_<module>`**:

| File | Keeper module(s) called | Bucket | Severance |
|------|-------------------------|--------|-----------|
| `lib/tool_usage_log.ml` | `Keeper_fd_pressure`, `Keeper_disk_pressure` | infra-leak | **DONE** — `~on_io_failure` injected at install boundary |
| `lib/multimodal/tool_emission.ml` | `Keeper_emitter` (+`Multimodal_keeper_bridge`) | infra-leak | pass emit fn / move to keeper-bridge domain |
| `lib/tool_unified.ml` | `Keeper_observation.cascade_metrics_json` | infra-leak | ⚠️ cascade-demolition zone — re-eval after main green (field may be deleted) |
| `lib/tool_task_payloads.ml` | `Keeper_tools_oas_workflow.workflow_rejection_*` | infra-leak | relocate pure payload builders to neutral module (RFC-0195 territory) |
| `lib/tool_resource_axis.ml` | `Keeper_tool_alias.*` | misplaced | relocate `keeper_tool_alias` → `tool_alias` (surface concern). ⚠️ collides with #19290 |
| `lib/tool_registration_check.ml` | `Keeper_tool_policy`, `Keeper_tool_policy_config` | infra-leak | ⚠️ collides with #19290/#19282; sequence after they land |
| `lib/tool_control.ml` | `Keeper_meta_store`, `Keeper_registry`, `Keeper_types_profile_toml_normalizers` | domain-handler | invert via injected reader interface |
| `lib/tool_coord.ml` | `Keeper_identity`, `Keeper_runtime` | domain-handler | invert: identity-resolver interface keeper registers into |
| `lib/tool_deep_review.ml` | `Keeper_turn_driver.run_named` | domain-handler | inject turn-runner capability |
| `lib/tool_inline_dispatch.ml` | `Keeper_approval_queue.*` | domain-handler | inject approval-queue port |
| `lib/tool_inline_dispatch_coord.ml` | `Keeper_identity.*` | domain-handler | shared identity-resolver port (with tool_coord) |
| `lib/tool_task_handlers.ml` | `Keeper_config`, `Keeper_registry`, `Keeper_identity`, `Keeper_current_task_reconcile`, `Keeper_tool_policy`, `Keeper_meta_store` | domain-handler | largest; multiple injected ports |

`tool_keeper*.ml` (keeper-purpose handlers — keeper IS their domain) are out of scope for
this gate. The dispatch path (`tool_dispatch.ml`) is already keeper-clean (RFC-0084).

## 2. Definition of Done (Harness First)

`masc_mcp` is one flat library (`(include_subdirs unqualified)`), so the compiler cannot
enforce the direction. The deterministic gate is `scripts/lint/tool-keeper-boundary-ratchet.sh`
(wired into `fundamental-check.yml`, runs on every PR): the baseline `.callers` list may
**shrink but not grow**. Each severance PR removes its file and regenerates the baseline in
the same PR (paired update — avoids the baseline-drift failure mode).

Done = baseline empty (0 tool-surface files call a Keeper module). Structural root fix
(beyond the lint): split the tool surface into its own dune sub-library so the dependency
direction is compiler-enforced; the lint holds the line until then.

## 3. This is not a workaround

The ratchet is an invariant-enforcement gate (the compiler can't express the direction in a
flat library), not a "counter-as-fix": this same PR severs `tool_usage_log` (baseline 12→11),
proving the ratchet drives toward zero. Removal target: empty baseline / sub-library split.

## 4. Sequencing (in-flight PR collisions)

- Clear runway (no in-flight PR): `tool_usage_log` (done), `tool_emission`, `tool_inline_dispatch*`,
  `tool_control`, `tool_coord`, `tool_deep_review`, `tool_task_handlers`, `tool_task_payloads`.
- Contended — sequence AFTER they land: `tool_registration_check`, `tool_resource_axis`
  (#19290 / #19282 typed-predicate pair touches these + `keeper_tool_policy`).
- Hold: `tool_unified` (cascade demolition in-flight; `cascade_metrics_json` may be removed).

## 5. Status

main is currently red from the in-flight cascade→Runtime demolition (25 `Cascade_*`
unbound-module errors, identical set on pristine main — this PR adds none). Verification is
asymmetric because a flat library stops typechecking at the first broken module:

- `tool_usage_log.{ml,mli}` severance: **compile-verified** (`_build` `.cmt` regenerated
  after the edit; reached and typechecked).
- `server_bootstrap_maintenance.ml` injection: **reasoned-correct, not compile-verified**
  (downstream of the broken keeper modules; only its `.cmti` was produced, the `.ml` was
  never reached). The DI type logic is sound (`~site` punning matches the original
  `?site` call) but reachability is unproven until main greens.
- `scripts/lint/tool-keeper-boundary-ratchet.sh`: **fully verified** (compile-independent;
  tested for pass, drift-up fail, stale-baseline fail, and comment/string false-positives).

Full `dune build @check` + `@runtest` and Ready transition are gated on main returning to green.

## 6. Open decision — RFC ownership

The surface-wide invariant ("a tool surface module must not call a `Keeper_` module") is not
owned by any RFC (RFC-0084 covers only the dispatch path; RFC-0194 §3 is the dispatch_layer
taxonomy). Two acceptable resolutions, user's call:

- **(a)** Adopt a one-paragraph RFC that declares the invariant + names this ratchet as its
  enforcement + the sub-library split as the root fix. (3/4 RFC-reader agents recommended this.)
- **(b)** Let this gate + plan doc stand as the contract, citing it as a generalization of
  RFC-0084. Lower ceremony; the invariant is still enforced by CI.

This PR takes neither stance in code — it cites RFC-0084 as the precedent and flags the gap.
