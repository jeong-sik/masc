# Reverse Engineering Design Map — Gap Tracking

**Date**: 2026-05-19
**Plan SSOT**: `/Users/dancer/Downloads/MASC-MCP Reverse Engineering Design Map.html` (1545 lines)
**Plan baseline commit**: `23a5dd1521` (2026-05-18 generated)
**Current main HEAD**: `e5b73669d8` (2026-05-19)
**Commits between**: 205

## Evidence Record

- **Evidence**: source files at `e5b73669d8`, `git log --oneline 23a5dd1521..origin/main`, plan HTML structured table extraction
- **Timestamp**: 2026-05-19T+09:00
- **Confidence**: High (file:line cross-checked via `rg`)
- **Delta**: Plan published 1 day prior; significant godfile-split + extraction sprint landed (`bef4815bf1`, `7dda94cd4f`, `aacc526f2a`, `e8038264d8`, `8fa893e1ff`, `8c3dbaaad6`); but **typed-vocabulary widening, drift convergence, and "runtime" SSOT consolidation remain open**.

---

## Summary

Plan declares 3 "high-heat" gaps in the `#gaps` table and 1 additional HIGH (Auth identity spread). LOC-side and several PR-1 contract-pinning fixtures landed on main between `23a5dd1521..e5b73669d8`. None of the 3 architectural gaps are *closed*; all show measurable but **partial** progress. RFC candidates below split *PR-able cleanup* vs *RFC-required architecture work*.

| Plan gap | Plan heat | Now | RFC required |
|---|---|---|---|
| 1. Keeper turn FSM vs run_turn mixed orchestration | HIGH | Partial — `turn_plan` typed at phase gate; SpawnAdmission/PostTurn/MetricsClose still untyped inside 2,066-LoC monolith | RFC required |
| 2. OAS provider/model redaction broad + regression-prone | HIGH | Untreated — 11+ scattered `"runtime"` literals, no SSOT constant; `observability_redact` is secrets-only and orthogonal | RFC required |
| 3. H1/H2 MCP route behavior drift | HIGH | Partial — `Server_mcp_request_context` shared; **actor injection drift already closed by PR #16137** (see CORRECTION below); internal_keeper_runtime decision still duplicated; profile_conflict not extracted | PR-able + RFC for full identity FSM |
| 3-bonus. Auth identity spread (token owner / request hints / dashboard actor / `_agent_name` / SSE query-token) | HIGH | Partial — caller identity extracted to `mcp_server_eio_caller_identity.ml` (PR #16163); transport-side still rewrites `_agent_name` inline | RFC required (request identity reducer) |

LOC moves since plan (size monolith-reduction proxy):

| File | Plan LoC | Now LoC | Δ |
|---|---|---|---|
| `lib/keeper/keeper_unified_turn.ml` | 2,890 | 2,066 | −824 (−28%) |
| `lib/server/server_dashboard_http_keeper_api.ml` | 3,022 | 2,075 | −947 (−31%) |
| `lib/keeper/keeper_registry.ml` | 2,192 | 2,169 | ~0 |
| `lib/server/server_runtime_bootstrap.ml` | 2,007 | 1,847 | −160 |
| `lib/server/server_mcp_transport_http.ml` | (H1/H2 split) | 870 | — |
| `lib/server/server_h2_gateway.ml` | (H1/H2 split) | 1,006 | — |
| `lib/auth.ml` | 1,651 | 1,651 | 0 |
| `lib/coord_goals.ml` | 1,095 | 1,001 | −94 |

---

## Gap 1 — Keeper turn FSM vocabulary stronger than run_turn shape

### Plan claim
- Plan `#gaps` row 3: *"`Keeper_turn_fsm` has typed states; docs still list run_turn-side streaming/tool transitions and cancellation propagation as pending/risky."*
- Plan `#refactor` row 1: `keeper_unified_turn.ml` 2,890 LoC, first cut = "pre-dispatch gate / OAS dispatch / post-turn / acquisition guard modules".
- Plan `#improvement-plan` evidence-box 3: Pipeline stages `SpawnAdmission → EventIntake → PhaseGate → PromptPlan → ProviderAttempt → ReceiptClose → PostTurn → MetricsClose`.

### Current state (file:line evidence)
- `lib/keeper/keeper_unified_turn.ml`: **2,066 LoC** (was 2,890; −28% via PRs #16215, #16285, #16286, others).
- `lib/keeper/keeper_unified_turn.mli:222-244` defines `turn_plan_status` variant + `turn_plan` record + `decide_turn_plan_at_phase_gate` *for the PhaseGate boundary only* (PR #16215 `bef4815bf1` 2026-05-18).
- `lib/keeper/keeper_turn_driver.mli:1-10`, `mli:145-210`, `ml:153-246`, `ml:1360-1398` still expose un-recorded turn-driver entrypoints; intake/provider/post-turn pass values via long parameter lists rather than typed step records.
- No `turn_spawn`, `turn_event_intake`, `turn_provider_attempt`, `turn_post_turn`, `turn_metrics_close` records. PR #16215 description in plan = "PR-1 of pipeline-records" — `task-372 TurnPlan records` from `#keeper-wbs` row 2 is open (5 sub-tasks: spawn no-fork, event queue payload, receipt fixtures, heartbeat seam, TurnPlan records — only the last has the phase-gate slice landed).
- Test pins for contracts landed: `test/test_keeper_unified.ml` extended +157 lines (PR #16215); `test: pin keeper spawn admission no-fork denial` (#16175, #16210); `test: pin keeper wakeup event queue contract` (#16185); `test: pin keeper receipt manifest closeout` (#16194). Plan `#keeper-wbs` PR 1 wave (task-368/369/370) is **substantially landed** as fixtures.

### Progress since plan
- LoC down 28%.
- PR-1 contract-pinning wave per `#keeper-wbs` is largely landed (spawn, wake, receipt fixtures).
- First pipeline record (`turn_plan` at PhaseGate) is typed and tested.

### Remaining (RFC scope)
- Convert remaining 6 stages (SpawnAdmission, EventIntake, PromptPlan, ProviderAttempt, ReceiptClose, PostTurn, MetricsClose) into a uniform step-record pipeline as plan §3 evidence-box dictates.
- Each stage must preserve the "보존해야 할 동작" listed at plan line 1054: spawn denial without fork, wake hint vs event payload split, turn id pre-assign, manifest append position, side-effect retry suppression, admission queue permit, receipt authority, post-turn lifecycle event order.

### RFC candidate
**Title**: *Keeper Turn typed pipeline records (post-PhaseGate stages)*
**Scope**: One-sentence — extend `turn_plan`-style typed-record contract from PhaseGate to the remaining 7 stages so `run_keeper_cycle` becomes a record-passing fold rather than a 2,066-LoC monolith, preserving the 8 listed turn invariants under `KeeperTaskAcquisition.tla` + receipt authority tests.

### Classification
**RFC required** — architecture-level boundary contract across 7 stages; per `workflow-pr.md` agent_delegation list this touches `lib/keeper/keeper_unified_turn.ml` which has no narrow surgical cut; behavior preservation guarantees must precede file moves.

---

## Gap 2 — OAS provider/model redaction broad + regression-prone

### Plan claim
- Plan `#gaps` row 4: *"Boundary doc enumerates many compatibility keys that must emit neutral runtime/null values."*
- Plan `#cascade-flow` `boundary contract`: *"compatibility fields are redacted to `runtime`, `null`, or non-identifying lane values."*
- Plan refactor advice: *"Centralize redaction helpers and make dashboard normalizers consume only redacted projection types."*

### Current state (file:line evidence)
**11+ emit sites with `"runtime"` string literal scattered across modules — no SSOT constant**:

| Site | Purpose |
|---|---|
| `lib/cascade/cascade_catalog_runtime_probe.ml:14-15` | `public_runtime_provider_label = "runtime"`, `public_runtime_model_label = "runtime"` (local constants) |
| `lib/cascade/cascade_legacy_runner.ml:49` | `public_runtime_model_label = "runtime"` (duplicate local) |
| `lib/cascade/cascade_attempt_liveness_observer.ml:34` | `public_runtime_provider_label = "runtime"` (duplicate local) |
| `lib/cascade/cascade_attempt_fsm.ml:556` | `public_runtime_provider_label = "runtime"` (duplicate local) |
| `lib/cascade/cascade_runner.ml:412-413` | Inline `~provider_id:"runtime" ~model_id:"runtime"` |
| `lib/keeper/keeper_agent_run.ml:763` | Inline `let model = "runtime"` |
| `lib/keeper/keeper_generation_lineage.ml:120, 169` | Inline `let model = "runtime"` (2 sites) |
| `lib/keeper/keeper_oas_checkpoint.ml:71` | Inline `model = "runtime"` |
| `lib/keeper/keeper_turn_driver_wrappers.ml:85` | Inline `model = Some "runtime"` |
| `lib/keeper/keeper_rollover.ml:314` | Inline `let model = "runtime"` |

**Documented intent (no enforcement)**: `lib/keeper/keeper_unified_metrics.mli:141` documents *"neutral ['runtime'] lane instead of deriving provider identity"* — comment only.

**Tangentially related but separate**: `lib/observability_redact.ml/.mli` exists but covers **secrets** (API keys, tokens, denied tools), not provider/model neutralization. It is not the central redaction helper plan §4 asks for.

**MEMORY context**: `feedback_runtime_lens_boundary_carve_out.md` (2026-05-13~14 #15040/#15070/#15089) records *exactly this anti-pattern* — "외부 surface redact 'runtime', 내부 observability real provider" — with binary-rebuild as the typical fix. So the scatter is known-recurring.

### Progress since plan
- None directly. PR sweep includes `dashboard_actor_fallback` typed `Auth_error_kind` (#16315) but no provider/model redaction SSOT.

### Remaining (RFC scope)
- Single SSOT module e.g. `Boundary_redaction` exposing `provider_label`, `model_label`, `redacted_projection_t` types so callers cannot supply raw string `"runtime"`.
- Type-narrow at function signatures: change `provider_id:string` to `provider_id:Boundary_redaction.public_provider_id` (private type alias). Compiler enforces SSOT.
- Per `software-development.md` §AI 안티패턴 1 ("하드코딩 산포") — this is the canonical case.
- Per `software-development.md` §워크어라운드 거부 기준 §2 ("String/Substring 분류기 보강") — *adding* a constant without typed boundary is workaround; closed-sum type is the root fix.

### RFC candidate
**Title**: *OAS-MASC boundary redaction SSOT — closed public-label types*
**Scope**: One-sentence — replace 11+ inline `"runtime"` string literals across `lib/cascade/*` and `lib/keeper/*` with a single `Boundary_redaction` module exporting a private type that makes the neutral-lane projection the only constructible value at the OAS↔MASC boundary, so future regressions fail to type-check rather than silently leak provider identity.

### Classification
**RFC required** — touches `lib/keeper/*` (covered in `agent_delegation` subsystem list indirectly via cascade), introduces a new module with cross-cutting type boundary; *not* a narrow cleanup because the boundary doc (`docs/OAS-MASC-BOUNDARY.md:62-68, :108-188`) lists many compatibility keys that need a coherent treatment.

---

## Gap 3 — H1/H2 MCP route behavior drift

### Plan claim
- Plan `#gaps` row 7: *"H1 transport and H2 gateway both handle MCP auth/session/Accept/session DELETE logic."*
- Plan `#improvement-plan` evidence-box 1: H1/H2 reducer with outputs (session_id, accept_mode, actor, auth_token, internal_keeper_flag, response framing). Plan notes divergence: H2 differs on GET SSE branch, known-session validation, streaming POST/SSE framing.

### Current state (file:line evidence)
**Progress landed**:
- `lib/server/server_mcp_request_context.ml/.mli` (PR #16143 `aacc526f2a`, 2026-05-18) — typed `t` record + `decide_post_body : (post_body_decision, post_body_rejection) result`. Carries **3 of the 6 planned outputs**: session_id (line 2), auth_token (line 4), accept_mode (line 21).
- `test/test_mcp_h1_h2_admission_parity.ml` (PR #16137 `33adab28fd`) — H1/H2 parity test fixture exists.
- Caller identity extracted to `lib/mcp_server_eio_caller_identity.ml/.mli` (PR #16163 `7dda94cd4f`, 268+31 lines).
- Actor injection extracted to `lib/server/server_mcp_actor_injection.ml/.mli` (108+8 LoC, exists on disk).

**Drift still present**:
- `server_mcp_actor_injection` is referenced **only from H1** (`server_mcp_transport_http.ml:196, :201`). H2 (`server_h2_gateway.ml`) does **not** use the shared injection — `rg 'Server_mcp_actor_injection' lib/server/server_h2_gateway.ml` returns 0 matches.
- `internal_keeper_runtime` decision still duplicated: `server_mcp_transport_http.ml:385, :765` (2 sites) and `server_h2_gateway.ml:408` (1 site). Same boolean is computed independently.
- Plan evidence-box 1 outputs *response framing*, *profile-conflict gate*, *streaming branch capability* are not in `Server_mcp_request_context.t`.
- H1 vs H2 keeps independent Accept negotiation, session profile validation, body actor rewriting — plan §`#code-atlas` step 7 ("H2 repeats the same MCP decision chain", `server_h2_gateway.ml:392-507`) still applies.

### Progress since plan
- Big — 3 PRs landed: request context, actor injection module, caller identity. About 40% of evidence-box 1 by output coverage.

### Remaining (mixed)
1. *PR-able*: Wire `Server_mcp_actor_injection` into H2 gateway so the injection logic stops being H1-only. Narrow, behavior-preserving, requires parity test.
2. *PR-able*: Extract `internal_keeper_runtime` decision (3 duplicated sites) into a shared helper, possibly added to `Server_mcp_request_context`.
3. *RFC-required*: Plan's full evidence-box 1 reducer with all 6 outputs + 6 protected behaviors, plus the full *request identity FSM* of plan evidence-box 2 (overlaps Gap 3-bonus). This is per workflow-pr.md agent_delegation: `lib/server/` MCP transport is covered + this is an architecture-level change.

### RFC candidate
**Title**: *MCP request admission reducer + identity FSM (H1/H2 parity)*
**Scope**: One-sentence — promote `Server_mcp_request_context.t` from a 3-field session/accept/token reducer to the full 6-output admission decision (adding actor, internal_keeper_flag, response_framing) and consume it from both H1 and H2 transports as a one-line `decide → adapt → respond` adapter, eliminating the parallel auth/session/Accept/streaming branches currently duplicated across `server_mcp_transport_http.ml` and `server_h2_gateway.ml`.

### Classification
- **PR-able** (narrow): "Wire H2 to `Server_mcp_actor_injection`" + "Hoist `internal_keeper_runtime` decision". Both ≤ 1 file each on the transport side, gated by existing H1/H2 admission parity test.
- **RFC required**: full reducer expansion + identity FSM rollout.

---

## Gap 3-bonus — Auth identity spread (request identity reducer)

### Plan claim
- Plan `#gaps` row 8: *"Token owner, request hints, dashboard actor fallback, `_agent_name` injection, and SSE query-token auth span server auth, MCP transport, and execute dispatcher."*
- Plan `#improvement-plan` evidence-box 2: identity SM with inputs `_agent_name`, legacy `agent_name`, auth token, session cache → outputs resolved agent, token owner, keeper identity, strict-auth verdict.

### Current state (file:line evidence)
- `lib/mcp_server_eio_caller_identity.ml/.mli` (PR #16163) — 268 LoC consolidated identity resolver. Carries the resolution chain `_agent_name → session cache → legacy persisted session files → generated alias` documented in plan #code-atlas step 10 (`mcp_server_eio_execute.ml:225-273`).
- `lib/server/server_mcp_actor_injection.ml` (108 LoC) — rewrites `_agent_name` from bearer-token owner. H1-only as noted in Gap 3.
- `lib/auth.ml` — **1,651 LoC, unchanged** vs plan baseline.
- `lib/server/server_auth.mli:1, :56, :237, :283` still composes raw token extraction + role/permission + public-read + CORS + admin/tool auth combinators.
- Dashboard transport-token convergence landed in PR #16229 `8c3dbaaad6` (*"share bearer token reader across transports"*). Plan `#dashboard-flow` step "Dashboard auth is client-visible and server-validated" partially addressed.

### Progress since plan
- Caller identity resolution extracted (largest win).
- Dashboard bearer token reader shared across HTTP/SSE/WS (plan §dashboard step 4).

### Remaining (RFC scope)
- `auth.ml` 1,651 LoC unchanged — credential store, alias resolution, internal keeper token, role/tool permission, dashboard actor in one module.
- No `Request_identity.t` reducer record consumed at transport+auth+dispatcher.
- Plan refactor §7 "request identity reducer + credential store adapter" untouched.

### RFC candidate
**Title**: *Request Identity reducer + Auth/credential store carve-out*
**Scope**: One-sentence — introduce a `Request_identity.t` record (token, resolved agent, keeper identity, strict-auth verdict) emitted once by `Server_mcp_request_context`, consumed by `Mcp_server_eio_caller_identity`, `Server_auth.authorize_tool_v2`, and dashboard actor projection; then split `auth.ml` (1,651 LoC) into `Credential_store` (adapter) and `Request_identity` (pure reducer), preserving raw `<base>/.masc/auth` location.

### Classification
**RFC required** — `auth.ml` is on the workflow-pr.md agent_delegation credential subsystem list; carve-out is architecture-level. *No* narrow PR-able cleanup here because the existing module is monolithic and shared by 4+ consumers.

---

## Auxiliary observations (not the 3 big gaps, but tracked in plan)

### Plan #6 JSONL writer contract — partial
- `lib/jsonl_writer/jsonl_writer.ml/.mli` exists (PR #16112 `e8038264d8`, 30+29 LoC).
- Adopted by `lib/dated_jsonl/dated_jsonl.ml` and `lib/shared_audit/store.ml`.
- `Jsonl_atomic`, `Dated_jsonl`, `Fs_compat.append_jsonl` still co-exist (plan `#gaps` row 9). 33 callers of `append_jsonl|Jsonl_atomic\.append` across `lib/`.
- **RFC candidate**: *Single JSONL substrate (sunset `Fs_compat.append_jsonl`)* — narrower than the 3 big gaps; PR-able with caller migration.

### Plan #5 Dashboard `DashboardSurface` envelope — barely adopted
- `lib/server/server_dashboard_surface.ml/.mli` exists (151+37 LoC, PR #16240 `60d7e58b0d`).
- **Only 1 consumer** in `lib/` per `rg -l 'Server_dashboard_surface'`.
- Plan §5 calls for *all* dashboard read-models to consume `DashboardSurface` envelope. Wide rollout open.
- **PR-able**: each domain projection (keeper, OAS telemetry, planning, governance) can wrap independently. **RFC required** for the envelope contract version 2 if cache state / stale fallback / broadcast hook fields need extension.

### Plan #refactor row "Metrics SSOT transitional" — substantial progress
- 6 prometheus-split PRs landed (#16193, #16192, #16196, #16199, #16277, #16278, #16291): core/transport/cascade/oas/policy/runtime metric names split into separate modules.
- Plan `#gaps` row 10 (cascade vs prometheus drift) likely resolved. Recommend close.

---

## RFC Candidate Summary

| # | Title | Scope | Class |
|---|---|---|---|
| A | Keeper Turn typed pipeline records (post-PhaseGate stages) | Extend `turn_plan`-style record contract to 7 remaining stages; preserve 8 listed turn invariants | RFC required |
| B | OAS-MASC boundary redaction SSOT — closed public-label types | Replace 11+ `"runtime"` literals with `Boundary_redaction` module exposing private types | RFC required |
| C | MCP request admission reducer + identity FSM (H1/H2 parity) | Expand `Server_mcp_request_context` to 6 outputs; consume from H1+H2 as adapters | RFC required (with 2 PR-able prereqs) |
| C-pre1 | ~~*PR-able*: Wire H2 to `Server_mcp_actor_injection`~~ — **WITHDRAWN, already closed by PR #16137 (`33adab28fd`, "test: pin MCP H1/H2 admission parity")** | n/a | closed |
| C-pre2 | ~~*PR-able*: Hoist `internal_keeper_runtime` decision (3 sites)~~ — **WITHDRAWN, hoist already exists at `lib/server/server_auth.ml:351` (`Server_auth.is_verified_internal_keeper_request`); the "3 sites" are byte-identical applications of the already-hoisted function, not three independent decisions** | n/a | closed |
| D | Request Identity reducer + Auth/credential store carve-out | `Request_identity.t` record; split `auth.ml` 1,651 LoC into `Credential_store` + `Request_identity` | RFC required |
| E | Single JSONL substrate (sunset `Fs_compat.append_jsonl`) | Migrate 33 callers; converge on `Jsonl_writer` | PR-able (multi-PR) |
| F | DashboardSurface envelope adoption | Per-projection wrap; possibly v2 contract | PR-able per projection + RFC for v2 |

---

## Risk notes (per `software-development.md` §Workaround Rejection Bar)

- **Gap 2 (redaction scatter)** is the highest workaround-bait surface: any "add one more `"runtime"` literal" PR would entrench the anti-pattern (matches §AI 안티패턴 1 *Scattered Hardcoded Defaults* exactly). RFC must precede any further inline literal addition.
- **Gap 3 partial** state (actor injection H1-only) is a textbook **N-of-M migration** (§Workaround §3) — RFC-0085-style "complete the migration" language is the warning sign. Treat as PR sequencing, not "almost done."
- **Gap 1 PhaseGate-only** record is fine *for now* because PR #16215 explicitly stages the remaining record extractions. Watch for stage-stuck plateau.

---

## Provenance

- Plan SSOT: `/Users/dancer/Downloads/MASC-MCP Reverse Engineering Design Map.html` lines 409–1545.
- Code evidence: `git log --oneline 23a5dd1521..origin/main | wc -l = 205`; `wc -l` of 8 plan-tracked files; `rg` for `"runtime"`, `Server_mcp_actor_injection`, `turn_plan`, `Server_dashboard_surface`, `Jsonl_writer`, `internal_keeper_runtime`.
- Cross-referenced MEMORY entries: `feedback_runtime_lens_boundary_carve_out.md`, `project_godfile_decomp_track_a_b_synthesis.md`, `feedback_fallback_constant_to_discriminated_union.md`.
- Not committed — author review pending.

---

## CORRECTION (2026-05-19, post-dispatch verification)

### Gap 3 C-pre1 lane was factually invalidated

**Finding**: Sub-agent dispatched to implement C-pre1 (H2 actor injection wiring) discovered that the premise no longer holds at `origin/main` HEAD `e5b73669d8`.

**Actual state**:

- `lib/server/server_h2_gateway.ml:403-406` already calls `Server_mcp_transport_http.body_with_canonical_http_actor` in the `POST /mcp | /mcp/managed | /` dispatch path, immediately before `Mcp_eio.handle_request` at line 413. This is byte-equivalent to the H1 call site at `server_mcp_transport_http.ml:382`.
- `body_with_canonical_http_actor` (defined at H1 lines 199-201) internally composes `Server_mcp_actor_injection.reduce` + `inject_agent_name_into_body`. One call = both steps. The original Gap 3 framing ("H2 calls them 0 times") was a misreading of the composed helper.
- H1's second `inject_agent_name_into_body` site at `server_mcp_transport_http.ml:762` is inside `handle_post_messages` — the **legacy `POST /messages?session_id=...` SSE-fanout transport**, which H2 does not implement by design (`rg '/messages' lib/server/server_h2_gateway.ml` → 0 hits). There is no H2 counterpart.
- Git provenance: H2's `body_with_canonical_http_actor` call was added in `f0075c3611` (initial introduction) and refined in `33adab28fd` (PR #16137, "test: pin MCP H1/H2 admission parity"). PR #16137 explicitly pinned H1/H2 admission parity, the exact gap surface described.

### Implications for the rest of this document

This finding implies other gap entries should also be **re-verified against `origin/main` after PR sweep**. The plan baseline `23a5dd1521` (2026-05-18) is 1 day old but 205 commits behind; multiple gaps may already be closed by intervening PRs that the original synthesis did not cross-check.

**Recommended re-verification list** (status here is *unverified*, treat as candidates for re-check):

- Gap 3 C-pre2 (internal_keeper_runtime hoist) — still 3 sites at HEAD? grep shows 17+ parameter references; *decision sites* count needs separate measurement.
- Gap 1 (remaining 7 turn pipeline stages) — any landed since `23a5dd1521`?
- E (JSONL substrate sunset) — 33 caller count needs refresh.
- F (DashboardSurface adoption) — 1 consumer claim needs refresh.

### Process correction

Future research syntheses should:

1. Run the dispatch ratchet *before* the synthesis is committed (each PR-able lane validated by a quick dispatch).
2. Include `git log --oneline <baseline>..origin/main -- <gap-file-list>` per gap, not only aggregate count.
3. Treat "1-day-old plan + 205 commits" as high-drift baseline requiring per-claim verification.

---

## CORRECTION 2 (2026-05-19, post-dispatch verification of C-pre2)

### Gap 3 C-pre2 lane is also factually invalidated

**Finding**: Verify-only sub-agent dispatch on C-pre2 (`internal_keeper_runtime` decision hoist) discovered the hoist target already exists.

**Actual state at `origin/main` HEAD `909c334f4e`**:

- The 3 "decision sites" identified (`server_h2_gateway.ml:408-411`, `server_mcp_transport_http.ml:385-388`, `server_mcp_transport_http.ml:765-768`) are *byte-identical 2-line applications* of `Server_auth.is_verified_internal_keeper_request ~base_path request`.
- The decision function itself lives at `lib/server/server_auth.ml:351-355`:
  ```ocaml
  let is_verified_internal_keeper_request ~base_path request =
    match auth_token_from_request request with
    | Some token when Auth.verify_internal_keeper_token base_path ~token ->
        Option.is_some (internal_keeper_agent_from_request request)
    | _ -> false
  ```
- Production `true`-emitting sites: **0** (token + agent header gated by `Auth.verify_internal_keeper_token`). Test-only literals: 2 in `test_mcp_server_eio.ml:2228, 2284` (fixture-injected, not decision binding).
- The 13+ `~internal_keeper_runtime` plumbing references in `lib/mcp_server_eio*.ml` are pure forwarders (curry/partial application) — they thread the value, never decide.

### Implications

- C-pre2 as described ("hoist the decision into a helper") is *already done*. Recommended action **demote to closed (no-op)**.
- Optional H2 (de-dup the 2-line application snippet into a transport-level helper) is < 30 LoC churn, not PR-worthy as a standalone.
- **2/2 PR-able prereqs (C-pre1, C-pre2) invalidated by dispatch ratchet**. This is a stronger signal than a single false claim — the original Gap 3 synthesis systematically conflated "current code state" with "plan-baseline state".

### Remaining PR-able candidates from §RFC Candidate Summary

Untested by ratchet (treat as candidates pending verify):

- **E**: JSONL substrate sunset — 33 caller migration. Caller count needs refresh against current HEAD.
- **F**: DashboardSurface envelope adoption — 1 consumer claim needs refresh.

Both should run the same verify-only ratchet before any dispatch.
