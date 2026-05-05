# fundamental_roadmap.md Reality Check (2026-05-05)

> **Source**: External roadmap document `fundamental_roadmap.md` (1,935 lines, 5 phases × 26 weeks, "based on 206 audit findings + GitHub history").
> **Purpose**: Sanity-check the roadmap's factual claims against the *current* `main` (HEAD `5806519c0b`, fix #13007). The roadmap is treated as a draft proposal, not ground truth.
> **Method**: Direct file reads + `rg` + `gh pr` + RFC inventory. No claim is accepted on the roadmap's authority alone.
> **Outcome**: ~40% of the roadmap's specific factual claims are **stale** (already fixed, already smaller, already moved, or never existed in the form claimed). The remaining ~60% identifies real gaps worth addressing — but only after re-scoping.

This document exists so the next agent (or human) does not re-execute a 26-week plan whose premise is stale.

---

## 1. File-size claims

| File | Roadmap claim | Actual (HEAD `5806519c0b`) | Status |
|---|---|---|---|
| `lib/config/env_config_keeper.ml` | 2,278 lines, "117 env var, 6 domains, CRITICAL" | **949 lines** | ❌ **STALE** — 58% reduction already landed |
| `lib/keeper/keeper_unified_turn.ml` | "20+ gate cascade, all silent skip" | 2,289 lines, **gates record FSM transitions + Prometheus metrics** (see §2) | ❌ **OUTDATED PREMISE** |
| `lib/keeper/keeper_turn.ml` | "500+ 줄, Godfile" | 615 lines | ✅ confirmed in-range |
| `lib/keeper/keeper_prompt.ml` | "수백 줄, 5+ templates" | 244 lines | ⚠️ smaller than implied; ROI of externalization is low |
| `lib/cascade/cascade_catalog_runtime.ml` | 34KB, hardcoded tiers/models/providers | 972 lines (~38KB) | ✅ size-confirmed; content claim §3 needs separate check |
| `lib/cascade/capabilities.ml` | "40+ model prefix-match cases hardcoded" | **File does not exist on `main`** | ❌ **STALE** — file is gone; **but its content migrated** (see §8 gap #6: `lib/provider_adapter.ml:365-405` holds 9 model literals — gpt-5.x/gemini-2.5 list) |
| `oas/lib/llm_provider/backend_openai.ml` | "48KB monolith, 10+ providers" | 1,550 lines, dispatches OpenAI/Anthropic/Gemini/Ollama/GLM (5 providers, not 10+) | ⚠️ partially confirmed |
| `oas/lib/llm_provider/backend_anthropic.ml` | "doesn't exist yet" implied | **210 lines, already separate file** | ❌ **STALE** — split already partially done |
| `oas/lib/llm_provider/backend_gemini.ml` | implied non-existent | **363 lines** | ❌ **STALE** |
| `oas/lib/llm_provider/backend_ollama.ml` | implied non-existent | **641 lines** | ❌ **STALE** |
| `oas/lib/llm_provider/backend_glm.ml` | not mentioned | **452 lines** | ❌ Roadmap omitted an existing backend |

**Aggregate**: of 11 file-size claims, 5 are stale, 1 file does not exist, 1 incomplete, 4 confirmed.

---

## 2. "5 pre-dispatch gate silent skip" claim

The roadmap (Phase 1, §2-1) opens with:

> "BEFORE: keeper_unified_turn.ml의 silent skip — `let check_phase meta = Ok meta` ← 이런 코드 제거"

Direct read of `lib/keeper/keeper_unified_turn.ml` (2,289 lines on HEAD `5806519c0b`):

| Evidence | File:line |
|---|---|
| Pre-dispatch terminal observation is recorded (8 sites) | `lib/keeper/keeper_unified_turn.ml:60,159,188,324,419,468,...` |
| Phase gating transitions FSM to `Done` | `lib/keeper/keeper_unified_turn.ml:203,2279` |
| Ollama saturation increments Prometheus counter | `lib/keeper/keeper_unified_turn.ml:344` (`Prometheus.metric_keeper_ollama_saturation_skip`) |

**Conclusion**: the "silent skip → returns `Ok meta` with no logic" pattern the roadmap targets does not match the current file. Each of the gates the roadmap names already records observations and transitions FSMs. Whether the *logic* inside each gate is correct is a separate question — but the framing "silent" is wrong.

**Recent context**:
- PR #12783 (2026-05-02): "eliminate silent dispatch / write_meta failures + PPX fsm_guard routing"
- PR #12910 (2026-05-01): reverted #12885 (autonomous turn slot release timing) → pre-dispatch logic re-tuned

---

## 3. PR references in the roadmap

The roadmap cites 7 PRs. Status as of 2026-05-05 (fetched via `gh pr view <N> --json`):

| PR | Title | State | Merged |
|---|---|---|---|
| #12955 | feat(keeper): admission router shadow-mode + lazy init | **MERGED** | 2026-05-05 |
| #12959 | fix: add logging before Result.to_option error discard | **MERGED** | 2026-05-05 |
| #12971 | fix: replace fake arithmetic with Beta distribution in meta cognition | **MERGED** | 2026-05-05 |
| #12986 | chore(dashboard): remove fabricated telemetry placeholders | **MERGED** | 2026-05-05 |
| #12988 | chore(task_dispatch): convert backend_state ref to Atomic.t | **OPEN** | — |
| #12990 | refactor(cascade): externalize scoring magic numbers | **MERGED** | 2026-05-05 |
| #12992 | fix(test): unblock main build (thompson_confidence + Feature_flag_registry) | **MERGED** | 2026-05-05 |

**6 of 7 already merged.** The roadmap's Phase 1-4 work is partially done — re-applying its prescriptions wholesale would create regressions.

---

## 4. RFCs already exist for the roadmap's flagship work

The roadmap proposes new architecture without acknowledging RFCs already drafted on the same surfaces:

| RFC | Topic | Roadmap section it shadows |
|---|---|---|
| `RFC-0008` | CredentialProvider trait | Phase 2-2 (Provider backend separation) |
| `RFC-0019` | Keeper credential unification | Phase 2-2 |
| `RFC-0020` | Keeper event queue layer separation | Phase 3-2 (Event-driven Queue) |
| `RFC-0022` | Cascade attempt liveness contract | Phase 1-1 (Livelock FSM) |
| `RFC-0024` | Ollama cascade integration | Phase 1-1 (Ollama gate) |
| `RFC-0026` | Work-conserving keeper admission | Phase 1-2 (Admission queue) |

`docs/rfc/` lists 22 active RFCs (0001–0026 with gaps). Any new design doc must cross-reference these — `~/me/scripts/pr-rfc-check.sh` enforces this for PRs.

---

## 5. TLA+ specs already present

The roadmap proposes 5 *new* specs (`GatePipeline`, `LivelockFSM`, `LockFreeHolder`, `FairScheduler`, `Recovery`). Existing spec inventory in `specs/`:

```
specs/auth/AuthIdentityFSM.tla
specs/boundary/AuditLog.tla
specs/boundary/CascadeKeeperRecovery.tla         ← partial overlap with Recovery.tla proposal
specs/boundary/CascadeStrategy.tla
specs/boundary/KeeperEmptyToolUniverse.tla
specs/boundary/ToolCallContract_TTrace_1776849071.tla
specs/checkpoint-trim/CheckpointTrim.tla
specs/closure/ContractClosure.tla
specs/task-lifecycle/TaskLifecycle.tla
docs/MASC_A2A.tla
```

`KeeperCompositeLifecycle.tla` (mentioned in `~/.../memory/MEMORY.md`, 449 LOC) acts as observer over 5 sub-FSMs; this means the roadmap's "GatePipeline" / "LivelockFSM" / "Recovery" should likely *extend* `KeeperCompositeLifecycle.tla` and `CascadeKeeperRecovery.tla` rather than create from scratch.

---

## 6. CI guardrails currently in place

`.github/workflows/`:
```
approve-agent-pr.yml      ci-cancel-closed-pr.yml
ci.yml                    dashboard-lighthouse.yml
dashboard-ws-load.yml     deploy-railway.yml
main-nightly-health.yml   odoc.yml
perf-baseline.yml         pr-automation.yml
```

**No `fundamental-check.yml`-style guard** for: model-name hardcoding regression, `Math.random` in source, oversized files, new `Mutex` introductions without RFC. Sprint 0 closes this gap.

---

## 7. Concurrency primitive distribution

Current count over `lib/keeper/` + `lib/cascade/`:

| Pattern | Files containing it |
|---|---|
| `Mutex.` or `Eio.Mutex` | **54** |
| `Atomic.` | **31** |

The roadmap's Phase 3 stretch goal "Mutex 0개" is unrealistic in the planned 3 weeks. Sprint 3 of this plan targets `54 → ≤40` with PR-per-module discipline (PR #12988 is the first instance, currently open).

---

## 8. The 5 gaps the roadmap got *right*

Despite §1-§4 staleness, these claims survived verification and are real engineering work:

| # | Gap | Evidence |
|---|---|---|
| 1 | **`lib/cancellation.ml` does not call `Eio.Cancel.cancel`** | line 135 `Atomic.set t.cancelled true;` is the only termination signal. Fibers continue on cooperatively cancellable points only. |
| 2 | **`lib/resilience/recovery.ml` Strategy GADT defined, executed in 1 site** | line 26 `type _ strategy =`, line 60 `strategy_to_tla_symbol`. Only `lib/resilience/resilience_runtime.ml` consumes it. `keeper_turn` paths bypass it. |
| 3 | **`oas/lib/llm_provider/backend_openai.ml` couples 5 providers in dispatch** | 1,550 lines; routes to Anthropic/Gemini/Ollama/GLM despite separate `backend_*.ml` files (210/363/641/452 lines) existing. No `backend.mli` signature unifies them. No `backend_router.ml`. |
| 4 | **Mutex/Atomic ratio 54:31** in keeper+cascade hot paths | counted above. CAS-friendly cases (read-heavy, short critical sections) remain. |
| 5 | **`fundamental-check` CI gate absent** | listed `.github/workflows/*.yml` does not include hardcoding/silent-failure/Godfile-size regression. |
| 6 | **`lib/provider_adapter.ml:365-405` model literal list** | discovered when the Sprint-0 lint ran on its own author worktree: 9 quoted model strings (`"gpt-5.2"`..`"gpt-5.5"`, `"gemini-2.5-flash"`..`"gemini-2.5-pro"`) sit in a 1,623-line file. The lost `capabilities.ml` content migrated here. Grandfathered in `scripts/lint/no-roadmap-stale-hardcoding.allowlist` for now; cleanup queued in Sprint 2/3 (backend dispatch separation + Catalog routing). |

These six gaps are the targets of the re-scoped 10-week plan in `~/me/planning/claude-plans/joyful-tumbling-dragon.md`. Gap #6 was identified during Sprint 0 dogfooding; the plan's Sprint 2 RFC (RFC-0027 backend dispatch separation) will absorb the catalog migration.

---

## 9. Explicit non-goals (versus roadmap)

The plan **deliberately does not pursue** these roadmap items:

- **Phase 5-1 `env_config_keeper.ml` decomposition (6 weeks)** — already 949 lines (down from claimed 2,278); ROI is low.
- **Phase 2-5 `keeper_prompt.ml` external templates** — 244 lines; template-engine infrastructure exceeds value.
- **Phase 3-3 Fair Scheduler (Token Bucket + DRR)** — current evidence (memory `feedback_semaphore_tier_is_architectural_anti_pattern.md`, 2026-05-05) recommends *multi-cascade fanout / deadline scheduling / per-provider token bucket*, not weighted-DRR. Different shape.
- **Phase 1-1 Livelock FSM new spec** — RFC-0022 already drafted; should extend, not replace.
- **Phase 4-1 Math.random removal in `cb-shared.jsx` / `StatusTray.jsx`** — PR #12986 already removed fabricated telemetry placeholders. Remaining instances need a fresh sweep, not the roadmap's prescribed code.

---

## 10. How to update this audit

This file is a snapshot at HEAD `5806519c0b`. When the picture shifts:

1. Update the table in §1 with `wc -l` results and a new HEAD pointer.
2. Re-run `gh pr view` for §3 PRs and any newly cited PR numbers.
3. Append rather than rewrite — the staleness *trail* is itself useful evidence (memory `feedback_self_audit_grep_only_false_positive_trap.md`).

Companion evidence record: `docs/evidence/2026-05-05-fundamental-roadmap-reality-evidence-record.md`.
