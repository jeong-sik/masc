# Provider Credit Balances Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show provider-reported remaining credit for OpenRouter, Ollama Cloud, and Kimi Coding in the Usage API, durable history, native TUI, and dashboard without dropping existing usage windows.

**Architecture:** Decode credit into a dedicated `Credit_balance` utilization variant beside usage fractions and USD spend. OpenRouter uses an optional nested credit read beside its existing key read; Ollama and Kimi balances come from their existing responses. One runtime-resolved/history schema carries the value to both clients.

**Tech Stack:** OCaml 5.5, Eio, Yojson, Alcotest, TypeScript 6, Preact, Valibot, Vitest.

**Spec:** `docs/superpowers/specs/2026-11-19-provider-credit-balances-design.md`

## Global Constraints

- Preserve `main` and every live runtime-owned file; work only in `.worktrees/provider-credit-balances-20261119` on `feat/provider-credit-balances-20261119`.
- Do not read or print credential values. Provider calls in tests are injected fetches; no live paid API call.
- Do not run local Dune builds or watch CI. Name the exact focused OCaml suites for later independent/CI verification.
- No commit or push unless the operator explicitly asks later.
- A zero balance is a reported value. Missing reports, missing totals, malformed values, and unknown shapes remain distinct.
- Do not add OpenRouter/Kimi credit observations to routing decisions. Preserve Ollama's documented included-then-purchased behavior.

## Review Focus

- Zero and absent wallet values: zero is drawn, absent is not; covered by Kimi/Ollama decoder and client rendering tests in Tasks 1 and 3.
- Missing or zero total: no percentage or division by zero; covered by Credit projection and TUI tests in Tasks 2 and 3.
- Kimi fixed-point precision, missing `amountLeft`, and currency fallback: covered by official-shape fixtures in Task 1.
- Inconsistent totals, negative values, wrong units, and malformed timestamps: refuse with a field path in Task 1.
- Independent OpenRouter endpoints and same-host credential boundary: both fetches occur, either report survives the other's failure, and invalid nested config is refused in Task 1.

---

### Task 1: Provider credit decoding and OpenRouter auxiliary read

**Files:**
- Modify: `lib/runtime/runtime_provider_usage_types.{mli,ml}`
- Modify: `lib/runtime/runtime_provider_usage_window.{mli,ml}`
- Modify: `lib/runtime/runtime_provider_usage_observations.ml`
- Modify: `lib/runtime/runtime_schema.{mli,ml}`
- Modify: `lib/runtime/runtime_toml_providers.ml`
- Modify: `lib/runtime/runtime_provider_usage_read.{mli,ml}`
- Modify: `config/runtime.toml`
- Modify: `docs/RUNTIME-TOML-REFERENCE.md`
- Test: `test/test_provider_usage_windows.ml`
- Test: `test/test_runtime_toml_wrong_typed_keys.ml`

**Interfaces:**
- Produces: `Credit_balance of { currency : string; total : float option; remaining : float }` in `Runtime_provider_usage_window.utilization`.
- Produces: `decode_openrouter_credits : Yojson.Safe.t -> (report, decode_error) result`, with source `openrouter.credits`.
- Produces: `usage_read.credit_url : string option`; nested `[providers.<id>.usage-read.credit] url = "https://same-host/..."` is valid only for `openrouter-key`.
- Consumes: existing injected `fetch : api_key:Secret.t -> string -> (string, http_error) result`; no new network abstraction.

- [ ] **Step 1: Add failing provider fixtures and config tests**
  - OpenRouter `{data:{total_credits:100.5,total_usage:25.75}}` becomes USD total `100.5`, remaining `74.75`.
  - Ollama's official credit-plan response becomes included credit `72.5/100` with `period.until`, plus purchased credit `25` without a total; the legacy response keeps both windows and gains purchased credit.
  - Kimi's upstream live wallet shape becomes CNY total `175`, remaining `103.367039`; missing `amountLeft` becomes zero; `{}` and a non-BOOSTER balance add no row.
  - Assert invalid totals/ranges/units/timestamps are errors and that OpenRouter primary/credit fetches both record under their own sources even when the other endpoint fails.
  - Assert nested credit URL parses, and wrong shape, wrong type, unknown key, non-HTTPS, and different host are refused.

- [ ] **Step 2: Run the focused OCaml checks if an authorized runner is available**
  - Targets: `test/test_provider_usage_windows.exe` and `test/test_runtime_toml_wrong_typed_keys.exe`.
  - Expected before implementation: missing Credit constructors/decoders and nested config support. If no authorized runner is available, record `미실행(외부 세션 로컬 Dune 금지)` rather than claiming a red/green result.

- [ ] **Step 3: Implement the typed Credit value and provider decoders**
  - Add `Credit_balance` to both shared runtime type files and re-export it from `runtime_provider_usage_window`.
  - Add `Openrouter_credits_read` with source word `openrouter.credits`, complete-snapshot reduction, and no `gate_coverage` routing behavior.
  - Add strict OpenRouter credits, both Ollama balance shapes, and Kimi booster decoding as specified. Validate finite nonnegative amounts, `remaining <= total` where a total exists, and required fixed-point/unit markers.

- [ ] **Step 4: Implement nested OpenRouter credit configuration and independent reads**
  - Extend `usage_read` with `credit_url`; parse the nested table with the existing HTTPS/same-host rules.
  - Keep `usage_report` primary-only for refusal handling. In the operator read path, fetch and record primary and credit reports independently, returning an error only after both declared reads have been attempted.
  - Declare the default OpenRouter `/credits` URL and document the nested table.

- [ ] **Step 5: Review the Task 1 diff**
  - Check every `utilization` and `source` match for exhaustiveness, no fabricated default balances, no routing read of `Openrouter_credits_read`, and no credential output.
  - Run `git diff --check` and record the focused OCaml checks as executed or explicitly unexecuted.

### Task 2: Durable history and shared client decoding

**Files:**
- Modify: `lib/server/server_provider_usage_history_projection.ml`
- Modify: `lib/tui_decode_usage.{mli,ml}`
- Modify: `dashboard/src/api/schemas/runtime-resolved.ts`
- Test: `test/test_provider_usage_history_snapshots.ml`
- Test: `test/test_tui_overview_providers.ml`
- Test: `dashboard/src/api/schemas/runtime-resolved.test.ts`

**Interfaces:**
- Consumes: Task 1 `Credit_balance` values and `Usage.utilization_fields`.
- Produces wire utilization: `{unit:"credit_balance", currency:string, total:number|null, remaining:number}`.
- Produces: `Tui_decode_usage.Utilization_credit_balance` and the equivalent Valibot-inferred TypeScript union member.

- [ ] **Step 1: Add failing round-trip tests**
  - Record OpenRouter account credit and Ollama purchased credit; assert durable history and runtime-resolved decoding retain currency, total, remaining, and observation time.
  - Add a Valibot test for capped USD and uncapped CNY credit, plus rejection of unknown credit units.

- [ ] **Step 2: Implement wire/history/client decoding**
  - Serialize Credit through the existing `utilization_fields` path; decode it strictly in history and TUI, requiring finite nonnegative amounts and `remaining <= total` when total is present.
  - Add the dashboard Valibot union member without converting missing values to zero.

- [ ] **Step 3: Run available focused checks**
  - Run `pnpm exec vitest run src/api/schemas/runtime-resolved.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1` in `dashboard/`.
  - Record `test/test_provider_usage_history_snapshots.exe` and `test/test_tui_overview_providers.exe` as executed or `미실행(외부 세션 로컬 Dune 금지)`.

### Task 3: Remaining-first TUI/dashboard presentation and observation

**Files:**
- Modify: `bin/masc_tui_overview_providers.{mli,ml}`
- Modify: `bin/masc_tui_usage_trend.ml`
- Modify: `dashboard/src/components/overview/runtime-stats.ts`
- Test: `test/test_tui_overview_providers.ml`
- Test: `dashboard/src/components/overview/runtime-stats.test.ts`

**Interfaces:**
- Consumes: Task 2 client Credit union.
- Presentation: `Credit USD 74.75 left` for a balance without context; with a stated total, add `used USD 25.75/USD 100.50` and a used-share meter. Dashboard uses the same facts in Korean: `Credit USD 74.75 남음 · USD 25.75/USD 100.50 사용`.

- [ ] **Step 1: Add failing client rendering tests**
  - TUI: capped and uncapped Credit rows show remaining, only capped rows draw a meter, zero is visible, and narrow rows still fit.
  - Dashboard: render capped USD and uncapped CNY Credit beside existing key usage; retain the existing USD-spend assertions.

- [ ] **Step 2: Implement remaining-first rendering**
  - Exhaustively handle Credit in share, zero, amount, and at-limit helpers. A missing/zero total has no meter; zero remaining is spent only for the existing role-based alarm logic.
  - Keep all layout, wrapping, and role behavior; no new controls or CSS dependency.

- [ ] **Step 3: Run focused client verification**
  - Run `pnpm typecheck` and both focused Vitest files in `dashboard/`.
  - Record `test/test_tui_overview_providers.exe` as executed or `미실행(외부 세션 로컬 Dune 금지)`.

- [ ] **Step 4: Observe the actual dashboard and final diff**
  - Serve the changed dashboard with a controlled runtime-resolved fixture containing OpenRouter USD, Ollama USD, and Kimi CNY Credit; inspect the rendered Usage account cards in a real browser and save a bounded screenshot/log under `artifacts/provider-credit-balances-20261119/`.
  - Run `git diff --check`, inspect `git status`, and list exactly which OCaml suites and live `~/me/.masc` application steps remain unverified.

### Task 4: Codex finite/unlimited Credit and Claude balance boundary

**Files:**
- Modify: `lib/runtime/runtime_provider_usage_types.{mli,ml}`
- Modify: `lib/runtime/runtime_provider_usage_window.{mli,ml}`
- Modify: `lib/server/server_provider_usage_history_projection.ml`
- Modify: `lib/tui_decode_usage.{mli,ml}`
- Modify: `bin/masc_tui_overview_providers.ml`, `bin/masc_tui_types.ml`, `bin/masc_tui_usage_trend.ml`, `bin/masc_tui_render_runtime.ml`
- Modify: `dashboard/src/api/schemas/runtime-resolved.ts`, `dashboard/src/components/overview/runtime-stats.ts`
- Test: `test/test_provider_usage_windows.ml`, `test/test_provider_usage_history_snapshots.ml`, `test/test_tui_overview_providers.ml`, `dashboard/src/api/schemas/runtime-resolved.test.ts`, `dashboard/src/components/overview/runtime-stats.test.ts`

**Interfaces:**
- Adds `Credit_unlimited` beside `Credit_balance`; wire unit is `credit_unlimited`.
- Codex finite balances use `currency = "credits"`, `total = None`, and the reported JSON decimal string as `remaining`.
- `hasCredits = false` or `balance = null` writes `credit_retracted`, revoking stale balances across both Codex read/update sparse sources and restart; unlimited remains explicit regardless of `hasCredits`.
- Kimi's captured `balance: "0"` means no wallet and must not discard valid plan windows.

- [ ] **Step 1: Add failing Codex and client tests**
  - Cover finite `2500.75`, unlimited, disabled/hidden balances, negative/wrong-typed balances, and durable history.
  - Extend the real browser fixture with finite and unlimited Codex accounts; leave Claude out because it has no public balance API.

- [ ] **Step 2: Implement Codex CreditsSnapshot decoding and unlimited propagation**
  - Decode booleans and the nullable decimal string strictly, with field-path errors.
  - Preserve unlimited and finite values through history, TUI decoding, Valibot, and remaining-first rendering without a meter for unlimited.

- [ ] **Step 3: Verify**
  - Watch the new Valibot test fail before implementation, then pass all 22 schema tests and all 19 runtime-stats tests.
  - Run OCaml parse-only checks and the real browser fixture; record focused OCaml suites as `미실행(외부 세션 로컬 Dune 금지)`.
