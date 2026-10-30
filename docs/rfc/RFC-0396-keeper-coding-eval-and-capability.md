---
rfc: "0396"
status: Draft
---

# RFC-0396 — Keeper coding capability: wire a coding-outcome eval from existing parts, then gate tool improvements on its numbers

- Status: Draft
- Decision driver: external product review of v0.25.0 (2026-08-29): the Keeper coding tool surface is thin (exact-string edit with no failure diagnostics, no multi-edit, no outline) and no number shows a Keeper completing a coding task end to end. Internally, issue #28822 already records that `lib/eval_harness.ml` sits as a spec with no entry point — "wire it or delete it." This RFC decides: wire it, around coding tasks first.
- Area: `lib/eval_harness.{ml,mli}` (statistics: `compute_pass_at_k` without replacement, CI95, `min_runs_met` n≥5 — implemented, zero callers beyond its own test), `scripts/harness_tool_call_quality.sh --live` (working isolated-server + `masc_keeper_up` execution loop), `lib/trajectory/trajectory.ml:49` (`scenario_id : string option` — an eval hook already on the production write path via `lib/mcp_server_eio_call_tool.ml:374`), `test/fixtures/coding_worker_repo_smoke/` (an orphan coding fixture with zero consumers), `lib/keeper/keeper_tool_filesystem_runtime.ml:532` (`apply_patch` — exact substring only; a miss returns one line with no diagnosis).

## Problem (audited)

1. No coding-outcome number exists. `benchmarks/results/runtime-all-models-20260810/REPORT.md` holds a real measured 31/40 (77.5%) task-contract pass — but over 4 tool-call-quality cases, none of which edit code. The multi-keeper acceptance harness (22 missions) asserts existence and visibility ("board_thread_visible", "parallel_keeper_overlap_observed"), not outcome quality.
2. The statistics layer and the execution loop both exist but are not connected (#28822: `Eval_harness.` is referenced only by its own test; `load_scenarios_from_file` has zero call sites; scenario files: zero).
3. Tool-improvement work has no yardstick. Without a completion-rate baseline and a failure taxonomy, an edit-diagnostics PR cannot show it changed anything — the exact gap the external review named.

## Decision

- **D1 — #28822 resolves as "wire", not "delete".** The runner is the only missing piece: the statistics are already implemented correctly, and `Trajectory.scenario_id` is already written on the production tool-call path, so eval runs need no new persistence plumbing.
- **D2 — single verdict authority.** A coding case passes iff its `verify` command exits 0 in the case workspace. The runner executes verify itself and fills `eval_run.passed` (`eval_harness.mli:81-94`), then uses only `summarize_runs` / `compute_pass_at_k` (`eval_harness.mli:142-154`). The `deterministic_grader` taxonomy (Exact/Contains/Regex/NotContains string matchers, `eval_harness.mli:16-28`) is not extended here; a Command grader variant, if ever wanted, is its own decision. `tool_call_quality` composite axes stay diagnostic secondary metrics — never a second pass/fail authority.
- **D3 — corpus.** `benchmarks/coding/` with a difficulty ladder: L1 single-file bug fix (~5 cases), L2 small feature (~5), L3 multi-file change (~3, exercising the known multi-edit gap). Case 1 promotes the orphan `test/fixtures/coding_worker_repo_smoke/` (calc.py + check.sh). External dependencies stay minimal (OCaml stdlib / node:test / python unittest). Each case carries its own `timeout`: coding tasks are multi-turn and do not fit the harness's 90s poll default (`harness_tool_call_quality.sh:18`).
- **D4 — runner.** A bin/-side entry point, outside the keeper/runtime import graph (`scripts/lint/no-eval-tool-selector-runtime-import.sh` stays satisfied), reusing the `--live` loop shape: isolated server, one Keeper via `masc_keeper_up`, fresh copy of the case workspace, task submitted, wait until done or budget, run verify, extract metrics from trajectory and receipts. Runs shard by level and model with `run_slug` resume. n≥5 fills from L1 first; `min_runs_met=false` is reported as such, never hidden.
- **D5 — failure taxonomy.** Extracted from trajectories/receipts as a closed sum: `edit_miss | wrong_file | build_fail | budget_exceeded | provider_error | gave_up`. These buckets — not intuition — order the tool-improvement PRs.
- **D6 — tool improvements land only with before/after harness numbers.** Planned ladder, re-orderable by D5 buckets:
  1. Edit failure diagnostics: on an `old_string` miss, return typed observations — whitespace-only-difference detection, nearest candidate lines with line numbers and excerpts — and never auto-apply; the model decides the retry (per `docs/spec/04-turn-lifecycle.md`, heuristics do not decide).
  2. Freshness guard: Read/Write responses always carry the file's sha256; Edit accepts an optional `expected_sha256` and returns a typed conflict on mismatch — an objective invariant per `docs/spec/04-turn-lifecycle.md:56-59` ("atomic version checks"), not a Gate. The harness measures voluntary adoption; below-threshold adoption escalates to required in one hard cut, pre-registered here so the optional surface cannot quietly die (precedent: RFC-0240 write-time enforcement; `lsp_questions` References' measurement-gated exposure).
  3. Multi-hunk Edit: `edits[]` on one file, all-or-nothing, per-hunk diagnostics on failure; cross-file transactions stay out until a bucket demands them.
  4. File outline: `textDocument/documentSymbol` through the existing `lib/lsp_client/` pool as a **position-less entry point** (an `ask_file` shape) — not a fourth `question` variant, because that variant's contract is position-based (`ask ~line ~character`). The dashboard proxy already allowlists Document_symbol (`lib/server/server_ide_lsp_proxy.ml:140`, raw passthrough on the RFC-0190 dashboard surface); the keeper path reuses the pool, not the proxy.
  5. Build/test output structuring: only if D5 shows `build_fail` dominating.
- **D7 — deferred.** The 1-vs-N keeper control experiment stays deferred on RFC-0333's own power analysis (n=5 gives SE≈0.22; the sufficient-power A/B needs n≈200). This corpus is deliberately the substrate that experiment will reuse. Also out of scope: TUI/IDE human coding surfaces; sandbox-as-security-boundary work.

## Workaround-gate self-check

- Diagnostics return observations (byte facts about the file), never classify or decide — not a string-classifier signature.
- No auto-fuzzy apply — no repair/sanitize signature; a failing call stays failed, with a better message.
- The eval adds no counters to production paths; it reads receipts that already exist.

## Waves

| Wave | Scope | Exit criterion |
|---|---|---|
| W1 | Corpus skeleton + case schema (`timeout`, verify contract) + smoke case promoted from the orphan fixture | schema decodes; verify runs deterministically with no LLM |
| W2 | Runner entry point + trajectory/receipt metric extraction + report writer | smoke case × n=2 completes on a local model; `benchmarks/results/coding-baseline-*/REPORT.md` exists with pass@k and honest `min_runs_met` |
| W3 | L1/L2/L3 corpus filled; sharded baseline collection | L1 reaches n≥5; failure buckets published |
| W4+ | Tool PRs gated on W3 buckets | no tool PR without its before/after number |

## Verification

- Harness self-tests (no LLM) run in CI as a registered suite — both `(names)` and `(modules)` in the stanza, CI target registration checked.
- The runner consumes every export it introduces (dead-surface ratchet in ci.yml); `no-unknown-permissive-default.allowlist` rows for eval_harness get consumed or removed.
- Docs sync: the `docs/spec/15-testing.md` and `docs/spec/05-keeper-agent.md` lines that cite #28822's unwired state update in the wiring PR.

## Boundaries (untouched)

- `compute_pass_at_k` and the CI math — reused, unchanged.
- Keeper turn lifecycle — no phases, no build/test gates, no coding FSM; the configured LLM keeps deciding and the eval only observes.
- `tool_call_quality` scoring contract — untouched; its axes are read as diagnostics.

## Evidence record

- Evidence: file:line citations above, re-read in-session at `fe6bc386da`; external review of v0.25.0 (2026-08-29); issue #28822; `benchmarks/results/runtime-all-models-20260810/REPORT.md`; adversarial design review 2026-08-29 (six questions; the conditional items — runner fills `passed` directly, position-less LSP entry point, per-case timeout and sharded collection, sha256 escalation rule — are folded into D2/D4/D6).
- Timestamp: 2026-08-29T12:30+09:00
- Confidence: High for the wiring facts (all cited lines re-read this session); Medium for run-cost estimates (the 3–25h full-baseline wall-clock figure is an estimate — hence sharding and the smoke-first exit criterion).
- Delta: converts #28822 from "spec without entry point" into a decided wiring plan, and gives masc its first coding-outcome metric; tool-surface work stops being unmeasured.
