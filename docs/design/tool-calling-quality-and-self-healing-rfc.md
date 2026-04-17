---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_decision_pipeline_contract.ml
  - lib/keeper/keeper_composite_observer.ml
  - lib/keeper/keeper_measurement.ml
---

# Tool Calling Quality and Self-Healing RFC

**Status**: Internal-runtime scope implemented in local worktrees; benchmark/program work remains partially unimplemented
**Date**: 2026-04-03
**Scope**: `masc-mcp` + `oas` + local benchmark harness
**One sentence**: tool calling 품질을 `first-pass selection`에서 `bounded convergence under validation pressure`로 재정의하고, public MCP와 internal OAS 자율 경로의 경계를 유지한 채 self-healing helper와 공통 benchmark contract를 도입한다.

## Related Documents

- `../BENCHMARK-RUNBOOK.md`
- `../COMMAND-PLANE-RUNBOOK.md`
- `./contract-driven-agent-loop-rfc.md`
- `./contract-driven-agent-loop-rfc-review.md`
- Local code references:
  - `/Users/dancer/me/workspace/yousleepwhen/oas/lib/structured.ml`
  - `/Users/dancer/me/workspace/yousleepwhen/oas/lib/agent/agent_tools.ml`
  - `/Users/dancer/me/workspace/yousleepwhen/oas/lib/tool_input_validation.ml`
  - `/Users/dancer/me/workspace/yousleepwhen/oas/test/test_agent_pipeline.ml`
  - `/Users/dancer/me/workspace/yousleepwhen/oas/test/test_structured.ml`
- Experiment evidence:
  - `/Users/dancer/me/.worktrees/exp-gemma4-tool-bench/docs/gemma4-tool-benchmark-20260403.md`
  - `/Users/dancer/me/.worktrees/exp-gemma4-tool-bench/docs/strict-v2-quality-summary-20260403.md`
  - `/Users/dancer/me/.worktrees/exp-gemma4-tool-bench/docs/samchon-runtime-audit-20260403.md`

## Implementation Update (2026-04-04)

Runtime scope has moved since the original draft.

- `oas` now has a generic internal helper `Tool_retry_policy` and uses it in both the generic agent tool loop and `Structured.extract_with_retry`.
- `masc-mcp` now opts in to that helper only on internal OAS-backed autonomous paths:
  - keeper turn path
  - proactive keeper generation path
  - OAS worker builder path
  - local worker resume path
- `masc-mcp` public MCP path remains one-shot and deterministic. No model-facing retry loop was added there.
- Benchmark runner abstraction, MLX harness lane, and the broader program phases below are still proposal-level unless explicitly marked otherwise.

## 1. Problem Statement

현재 스택은 tool validation과 prefilter는 이미 갖고 있지만, 다음 네 가지가 한 contract로 묶여 있지 않다.

- 어떤 benchmark가 canonical truth인지
- `first_try`와 `final convergence`를 어떻게 분리해서 읽는지
- internal autonomous path와 public MCP one-shot path의 보장 범위가 어디까지 다른지
- recent local model expansion을 어떤 backend contract로 추가할지

그 결과:

- benchmark가 raw selection, BM25 selection, oracle self-heal upper-bound로 흩어져 있다
- `samchon`식 recovery가 OAS 안에 부분적으로 존재하지만 generic helper로 표면화돼 있지 않다
- `masc-mcp` public MCP path에 retry를 넣어야 하는지에 대한 경계가 문서화돼 있지 않다
- MLX 실험은 필요하지만 현재 harness가 `OpenAI-compatible endpoint` 전제라 바로 붙일 수 없다
- 최신 모델 추가가 ad hoc하게 일어나고, artifact schema와 acceptance gate가 고정돼 있지 않다

이 RFC의 목적은 더 많은 모델을 늘어놓는 것이 아니다. `tool call quality`를 하나의 typed program으로 만들고, 그 위에서 model/backend/repair policy를 비교할 수 있게 하는 것이다.

## 2. Non-Goals

이 RFC는 다음을 하지 않는다.

- public MCP wire protocol을 변경하지 않는다
- public MCP one-shot call에 model-facing auto-retry를 추가하지 않는다
- OAS에 deprecated MLX provider surface를 되살리지 않는다
- Anthropic식 hidden-state probe, steering, interpretability 실험을 1차 범위에 넣지 않는다
- reward-hacking bench를 safety verdict engine으로 과장하지 않는다
- benchmark artifact를 곧바로 production policy truth로 승격하지 않는다

## 3. Current State

### 3.1 Benchmark truth

현재 가장 신뢰할 수 있는 local benchmark는 `strict_v2`다.

- `Gemma 4 E4B raw`: selection `96.3%`, exact first-try `92.6%`, avg latency `544ms`
- `Gemma 4 E4B BM25 + improved`: selection `100.0%`, exact first-try `96.3%`, normalized first-try `100.0%`, avg latency `1481ms`
- `Qwen3-Coder-Next raw`: selection `96.3%`, exact first-try `92.6%`, avg latency `4024ms`
- `Qwen 9B BM25 + improved`: selection `48.1%`, exact first-try `44.4%`, avg latency `3187ms`

현재 self-healing harness는 oracle upper-bound다.

- `Qwen 9B raw`: `33.3% -> 100.0% final exact`
- `Qwen 9B BM25`: `44.4% -> 100.0% final exact`
- `Gemma 4 E4B raw no-think`: `88.9% -> 100.0% final exact`

즉, `better first pass`와 `bounded recovery`는 둘 다 중요하며, 둘을 하나의 표에서 같이 봐야 한다.

### 3.2 Runtime truth

`samchon` parity는 여전히 surface별로 다르지만, internal runtime scope에서는 helper boundary가 이제 명시적이다.

- `masc-mcp` public MCP path:
  - deterministic validation 있음
  - model-facing retry loop 없음
- `masc-mcp` internal keeper/OAS path:
  - validation 있음
  - bounded same-run correction 가능
  - OAS `Tool_retry_policy.default_internal`로 opt-in
- `oas` generic tool loop:
  - invalid input / recoverable tool error를 typed retry decision으로 평가
  - policy-enabled agent에서 same-run next turn correction 가능
- `oas` structured path:
  - `Structured.extract_with_retry`가 같은 helper core를 사용해 explicit bounded retry를 제공

이 상태는 여전히 uneven하지만, reusable helper와 adoption boundary 자체는 이제 코드로 존재한다.

### 3.3 Backend truth

현재 benchmark harness는 사실상 `llama.cpp server` 같은 OpenAI-compatible endpoint를 가정한다.

- current runners: endpoint POST `/v1/chat/completions`
- current score artifacts: JSON output files under `data/tool-calling-benchmark/results-*`
- MLX는 local runtime 후보이지만 OAS provider surface에서는 이미 deprecated다

따라서 MLX를 넣으려면 `provider resurrection`이 아니라 `benchmark runner abstraction`이 필요하다.

## 4. Goals

이번 RFC는 다음 네 가지를 고정한다.

1. canonical benchmark contract
2. internal self-healing helper adoption path
3. backend-neutral runner contract
4. recent-model expansion policy

## 5. Benchmark Contract

### 5.1 Canonical suites

세 개를 canonical suite로 고정한다.

- `strict_v2_tool`
  - required params가 모두 채워진 tool-calling set
  - main KPI: selection, exact first-try, normalized first-try, final exact at retry budget
- `coding_short`
  - small coding pass/fail set
  - main KPI: pass rate, total latency, output validity
- `pressure_behavior_v1`
  - impossible constraints, contradictory requirements, budget pressure, tool-family ambiguity under pressure
  - main KPI: reward hack rate, honest fail rate, clarify rate, hallucinated success rate, tool misuse rate

### 5.2 Result schema

모든 backend는 `benchmark_result_v2`로 저장한다. 최소 필수 필드는 다음이다.

- `backend`
- `model_id`
- `model_source`
- `model_date`
- `harness_version`
- `schema_version`
- `case_set`
- `prompt_version`
- `chat_template_profile`
- `metrics`
- `failure_taxonomy`
- `artifacts`
- `hardware_profile`

`metrics` 최소 필드:

- `selection_accuracy`
- `exact_first_try`
- `normalized_first_try`
- `final_exact_at_3`
- `avg_attempts`
- `avg_latency_ms`
- `avg_total_latency_ms`
- `prefilter_recall`
- `reward_hack_rate`
- `honest_fail_rate`
- `hallucinated_success_rate`
- `tool_misuse_rate`

### 5.3 Scoring policy

normalized scoring은 딱 두 경우만 허용한다.

- string leaf value의 trailing punctuation 제거
- `masc_check.assertions` expected subset 인정

그 외 fuzzy matching, semantic equivalence, paraphrase scoring은 금지한다.

이유:

- benchmark가 grading convenience 때문에 오염되면 self-healing 가치를 과대평가한다
- param fidelity는 여전히 deterministic contract여야 한다

## 6. Backend and Model Program

### 6.1 Runner contract

harness는 backend-neutral runner interface를 가진다.

- `prepare_case(case, prompt_profile) -> invocation`
- `invoke(invocation) -> raw_response`
- `extract_tool_call(raw_response) -> tool_name * params`
- `extract_text(raw_response) -> text`
- `extract_usage(raw_response) -> usage`
- `backend_metadata() -> backend info`
- `build_retry_feedback(case, attempt_result, retry_policy) -> retry_messages`

retry loop ownership은 runner가 아니라 harness controller에 둔다.

- runner는 single-attempt execution primitive만 제공한다
- convergence metric과 retry budget 집행은 harness controller가 담당한다
- `final_exact_at_3`는 `retry disabled` baseline과 동일 case set에서 비교한다

backend 종류는 두 개만 허용한다.

- `llama_cpp_openai`
- `mlx_lm_local`

### 6.2 MLX rule

MLX는 benchmark harness 내부 runtime으로만 도입한다.

- OAS provider surface에는 추가하지 않는다
- deprecated `local_mlx`를 revive하지 않는다
- local Python runner가 `mlx-lm`을 직접 호출한다

### 6.3 Phase-1 model matrix

Phase-1 표준 매트릭스는 여섯 개로 고정한다.

- `gguf/gemma4-e4b-it-q4`
- `gguf/gemma4-e2b-it-q8`
- `gguf/nemotron-cascade-2-30b-a3b-q4km`
- `mlx/nemotron-cascade-2-30b-a3b-4bit`
- `mlx/qwen3-coder-next-4bit`
- `mlx/lfm2.5-1.2b-thinking-6bit`

control-only retained model:

- `gguf/qwen3-coder-next-q4km`

제외 규칙:

- 60일 cutoff 밖이면 default matrix에서 제외
- local memory/latency 예산을 명백히 초과하면 optional lane으로만 남긴다
- 동일 base model의 중복 quant는 winner-takes-all로 줄인다

60일 cutoff anchor는 다음으로 고정한다.

- model source가 Hugging Face면 repo `initial commit` 또는 official publish timestamp를 사용한다
- 로컬 다운로드 일시는 cutoff truth로 쓰지 않는다
- benchmark report에는 `model_date_source`를 반드시 기록한다

## 7. Self-Healing Runtime Proposal

### 7.1 OAS helper

OAS에 generic internal helper `tool_retry_policy`를 추가한다.

Implementation status:

- done in local worktrees
- core module exists
- generic pipeline adoption exists
- structured-path adoption exists

typed fields:

- `max_retries : int`
- `retry_on_validation_error : bool`
- `retry_on_recoverable_tool_error : bool`
- `feedback_style : [structured_tool_result | plain_error_text]`

adoption target:

- `agent_tools` generic tool path
- `Structured.extract_with_retry`는 이 helper를 공통 core로 사용

### 7.2 MASC adoption boundary

`masc-mcp`에서는 다음 경계만 허용한다.

- internal OAS-backed autonomous path: retry policy 사용 가능
- public MCP path: retry policy 금지, current deterministic validation 유지

Implementation status:

- internal keeper / worker OAS-backed paths: adopted
- public MCP path: unchanged

이 boundary는 red line이다.

- public MCP response semantics를 model loop처럼 바꾸지 않는다
- public client에게 hidden retry 비용을 떠넘기지 않는다

### 7.3 Prefilter rule

prefilter는 serving path와 benchmark path 모두에서 description quality에 민감하다.

따라서:

- canonical benchmark descriptions는 artifact로 versioning한다
- `tool_prefilter` synonym table은 benchmark-derived임을 명시적으로 유지한다
- hand-tuned synonym drift는 benchmark evidence 없이 넣지 않는다

## 8. Pressure Behavior v1

Anthropic의 `desperate/calm` 결과는 1차에서 behavioral benchmark로만 가져온다.

case family:

- impossible constraints
- contradictory requirements
- tight budget pressure
- tool-family ambiguity under pressure

allowed label set:

- `honest_fail`
- `clarify`
- `valid_partial`
- `reward_hack`
- `hallucinated_success`
- `tool_misuse`
- `broad_tool_escape`

이 벤치는 interpretability claim을 하지 않는다.
하는 일은 하나다:

- pressure 조건에서 model이 어떤 실패 모드로 무너지는지 계량화

## 9. API and Interface Changes

Public wire changes:

- none

Internal interface additions:

- OAS `tool_retry_policy`
- benchmark `backend runner` abstraction
- benchmark `benchmark_result_v2`
- benchmark `model_catalog.json`

Compatibility rules:

- 기존 `strict_v2` JSON artifact는 read-only legacy artifact로 유지
- new reports는 `v2` schema로만 생성
- legacy summary script는 transitional adapter를 둘 수 있으나 new source of truth는 `v2`다

## 10. Acceptance Gates

implementation은 다음 gate를 만족해야 한다.

### 10.1 Harness gate

- same repo snapshot
- same case set
- same prompt version
- same backend metadata
- same model catalog revision
- MLX result 비교는 `same hardware_profile` 조건에서만 latency gate에 넣는다

### 10.2 Runtime gate

internal retry helper는 `retry disabled` baseline 대비 측정한다.

`weak model` 정의:

- same suite에서 `exact_first_try <= 70%`인 non-anchor model
- 그런 모델이 없으면 lowest-scoring non-anchor model을 weak model로 간주

gate:

- `final_exact_at_3`를 baseline 대비 `+10pp` 이상 올려야 한다

and `Gemma 4 E4B`에서:

- retry disabled baseline에서 이미 first-try success인 case들만 기준으로
- median total latency overhead가 `35%` 이하여야 한다

### 10.3 Boundary gate

- public MCP path golden tests unchanged
- internal OAS path only retry activation proven
- no new MCP wire field

### 10.4 Pressure bench gate

Phase-1에서 점수 threshold는 두지 않는다.
대신 다음만 요구한다.

- label consistency documented
- deterministic grading reproducible
- artifact schema stable
- `system_error`는 explicit bucket으로 허용하며 unlabeled bucket으로 보지 않는다

## 11. Test Plan

OAS:

- validation error retry success
- recoverable tool error retry success
- retry exhaustion returns final error cleanly
- retry disabled path preserves current behavior

MASC:

- public MCP path still returns one-shot validation failure
- internal OAS worker path can consume retry policy
- tool prefilter benchmark-derived table remains deterministic

Harness:

- `llama_cpp_openai` runner and `mlx_lm_local` runner produce same `benchmark_result_v2` shape
- case validators reject missing required params and invalid labels
- summary generator emits the canonical comparison table
- pressure grader emits `system_error` explicitly for transport, decode, or runtime failures

## 12. Rollout

Phase 0:

- RFC + execution program doc
- model catalog draft

Status: pending

Phase 1:

- runner abstraction
- `benchmark_result_v2`
- MLX local runner

Status: pending

Phase 2:

- `pressure_behavior_v1`
- updated summaries and tables

Status: pending

Phase 3:

- OAS `tool_retry_policy`
- internal-path-only integration in `masc-mcp`

Status: completed in local worktrees on 2026-04-04

Phase 4:

- compare `first-pass` vs `final convergence`
- decide default serving profile for local model path

Status: pending

## 13. Risks

- oracle-style self-heal result를 production parity로 오해할 위험
- MLX model pool이 실제 60일 cutoff와 local memory budget 사이에서 자주 바뀔 위험
- internal helper convenience 때문에 public MCP path에 retry leakage가 생길 위험
- pressure benchmark가 safety theater가 될 위험

대응:

- oracle upper-bound를 artifact 이름과 doc prose에서 분리 표기
- model catalog에 `date_source`와 `enabled`를 명시
- boundary golden test를 merge gate로 둔다
- pressure bench는 behavior taxonomy artifact로만 취급한다

## 14. Final Read

이 RFC의 핵심은 다음이다.

- benchmark truth를 `first-pass + bounded recovery + pressure behavior`의 세 축으로 고정한다
- OAS의 existing retry shape를 generic helper로 끌어올린다
- 그 helper는 internal autonomous path에만 연결한다
- MLX는 OAS provider가 아니라 harness backend로 도입한다

이 네 줄이 지켜지면 model expansion과 runtime improvement를 같은 계약 아래에서 비교할 수 있다.
