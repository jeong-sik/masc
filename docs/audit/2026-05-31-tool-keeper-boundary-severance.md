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
the measured severance set started at **12 tool-surface files that called a
`Keeper_<module>`**.

Current main status, 2026-06-01 (`origin/main` at `1096d319ba`): the severance
set is empty. `bash scripts/lint/tool-keeper-boundary-ratchet.sh --print`
reports `tool_keeper_callers current=0 baseline=0`, and
`bash scripts/audit-keeper-tool-boundary-matrix.sh` reports all 168 scoped
keeper files covered by `docs/design/keeper-tool-boundary-matrix.md`.

Historical drain:

- 12 initial tool-surface files called `Keeper_<module>`.
- `tool_usage_log` severed fd/disk pressure through injected failure handling.
- `tool_emission` severed keeper emission through an injected emitter port.
- #19632 (`Decouple tool surfaces from keeper internals`) drained the remaining
  reverse-dependency set and regenerated the ratchet baseline to zero.

`tool_keeper*.ml` (keeper-purpose handlers — keeper IS their domain) are out of scope for
this gate. The dispatch path (`tool_dispatch.ml`) is already keeper-clean (RFC-0084).

## 2. Definition of Done (Harness First)

`masc` is one flat library (`(include_subdirs unqualified)`), so the compiler cannot
enforce the direction. The deterministic gate is `scripts/lint/tool-keeper-boundary-ratchet.sh`
(wired into `fundamental-check.yml`, runs on every PR): the baseline `.callers` list may
**shrink but not grow**. Each severance PR removes its file and regenerates the baseline in
the same PR (paired update — avoids the baseline-drift failure mode).

Done = baseline empty (0 tool-surface files call a Keeper module). Structural root fix
(beyond the lint): split the tool surface into its own dune sub-library so the dependency
direction is compiler-enforced; the lint holds the line until then.

## 3. This is not a workaround

The ratchet is an invariant-enforcement gate (the compiler can't express the direction in a
flat library), not a "counter-as-fix": severance PRs reduced the baseline
12 -> 11 (`tool_usage_log`), 11 -> 10 (`tool_emission`), and finally 10 -> 0
(#19632). The removal target is now achieved at the ratchet level; the remaining
root fix is a future sub-library split so the compiler enforces the direction.

## 4. Sequencing (closed at ratchet level)

No per-file Tool -> Keeper severance remains on current main. The only
structural follow-up is the compiler-enforced split described in §2. Older
in-flight typed-tool PRs may still conflict with the files touched by #19632,
but they are rebase problems, not live Tool -> Keeper debt.

## 5. Status

2026-06-01 current-main verification:

- `scripts/lint/tool-keeper-boundary-ratchet.sh --print`: current=0,
  baseline=0.
- `scripts/lint/no-tool-substrate-adapter-surface.sh --fail`: 0 forbidden
  active substrate/micro-tool hits and 0 stale allowlist entries.
- `scripts/audit-keeper-tool-boundary-matrix.sh`: OK, 168 scoped keeper files
  covered by `docs/design/keeper-tool-boundary-matrix.md`.

## 6. Open decision — RFC ownership

The surface-wide invariant ("a tool surface module must not call a `Keeper_` module") is not
owned by any RFC (RFC-0084 covers only the dispatch path; RFC-0194 §3 is the dispatch_layer
taxonomy). Two acceptable resolutions, user's call:

- **(a)** Adopt a one-paragraph RFC that declares the invariant + names this ratchet as its
  enforcement + the sub-library split as the root fix. (3/4 RFC-reader agents recommended this.)
- **(b)** Let this gate + plan doc stand as the contract, citing it as a generalization of
  RFC-0084. Lower ceremony; the invariant is still enforced by CI.

This PR takes neither stance in code — it cites RFC-0084 as the precedent and flags the gap.

## 7. Follow-up axis: Runtime → Keeper (2026-06-02)

After the Tool→Keeper ratchet reached baseline=0, a systematic cross-subsystem scan
identified Runtime→Keeper as the next clear boundary violation.

**PR #19801** (2026-06-02):
- `Keeper_oas_checkpoint` -> `Runtime_oas_checkpoint` (0 keeper callers — purely misnamed)
- `Keeper_observation` -> `Runtime_observation` (shared 9+4, observation is runtime behavior)
- `Keeper_observation_query_operation` -> `Runtime_observation_query_operation`

Full audit: `docs/audit/2026-06-02-runtime-keeper-boundary-severance.md`

### Remaining Runtime→Keeper debt
`Keeper_identity` (2 calls in `runtime_oas_runner.ml`) and `Keeper_internal_error`
(1 call in `runtime_inference.ml`) remain after PR #19801. These require a
separate severance PR — see the full audit doc for details.
