---
rfc: "0095"
title: "OpenAI-compat provider streaming wire-up"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: jeong-sik
supersedes: []
superseded_by: null
related: ["0047", "0045", "0033", "0058"]
implementation_prs: []
---

# RFC-0095 — OpenAI-compat provider streaming wire-up

## 1. Summary

masc-mcp 의 streaming infrastructure 는 4 layer (llama-server SSE,
cascade transport `complete_stream`, OAS streaming hooks,
`llm_metric_bridge` Prometheus emission) 모두 코드 수준에 정착돼 있으나,
**`Custom_openai_compat` runtime binding 을 사용하는 provider
(예: 본 RFC 작성 시점의 `runpod_mtp`, `local_mtp`) 는 streaming chunk 를
emit 하지 않는다**. 동일 global metric sink 에서 `glm` provider 는 정상
emit (5332 chunks observed). 본 RFC 는 격차를 진단하고 wire-up 을 정리한다.

## 2. Evidence (measured 2026-05-17, masc-mcp 0.19.17 build 84d1cd8fb6)

`/metrics` (Prometheus exposition, masc-mcp dashboard port 8935):

| Provider label | Model label | first_chunk_count | inter_chunk_count |
|---|---|---:|---:|
| `glm` | `glm-5-turbo` | 17 | 4072 |
| `glm` | `glm-5.1`     |  1 | 1260 |
| (no label, fallback bucket) | — |  0 |  0  |

`openai_compat` 라벨로 분류돼야 할 호출 (`runpod_mtp`, `local_mtp` —
both running Qwen3.6-35B-A3B-MTP via llama-server + PR #22673) 모두
fallback bucket 으로 떨어지며 chunk count = 0.

**서버 SSE 자체 동작은 별도 검증됨**: 동일 endpoint 에 `curl` 로
`stream: true` 직접 송신 시 llama-server 는 `delta:{content:"1"}` 형식의
SSE chunk 를 정상 송출. 즉 *서버는 streaming 가능*, *masc-mcp 가 cascade
경로에서 그 path 를 발화시키지 않음*.

## 3. Background — current streaming pipeline

| Layer | File:Line | 상태 |
|---|---|---|
| L1 server-side SSE | external llama-server / RunPod proxy | ✓ |
| L2 cascade transport `complete_stream` | `lib/cascade/cascade_transport.ml:1535, 1656, 1711` | ✓ defined |
| L3 OAS hooks | `lib/oas_compat/oas_compat.ml:257-288` | ✓ `first_chunk` + `chunk_index` + `inter_chunk_ms` |
| L4 metric emission | `lib/llm_metric_bridge.ml:448-469` | ✓ global Prometheus sink |
| **Master switch** | `Cascade_attempt_liveness_config.current_mode ()` | controls `liveness_observer_opt` |
| **Wire to SDK** | `keeper_turn_driver_try_provider.ml:332-457` → `Cascade_runner.run:?on_event` (cascade_runner.ml:438 body) → `Agent_sdk.Agent.run_stream` | ✓ when `on_event = Some _` |

전체 chain 은 glm 호출 path 에서 정상 동작 — `provider="glm"` 라벨 metric
이 직접 증거. openai_compat path 에서 어느 link 가 끊겼는지가 본 RFC 의
진단 대상.

### 3.1 핵심 분기 (cascade_runner.ml:438 의 `run` 함수 ~510줄대)

```ocaml
let r = match on_event with
  | Some cb -> Agent_sdk.Agent.run_stream ~sw ?clock ?on_yield ?on_resume
                 ~on_event:cb agent goal
  | None    -> Agent_sdk.Agent.run ~sw ?clock ?on_yield ?on_resume agent goal
in
```

`on_event` 는 caller (`keeper_turn_driver_try_provider.ml:457`) 에서
`?on_event:liveness_on_event` 로 forward. `liveness_on_event` 는
`liveness_observer_opt = Some` 일 때만 `Some cb`
(`keeper_turn_driver_try_provider.ml:410-411`).

### 3.2 `liveness_observer_opt` 활성 조건 (keeper_turn_driver_try_provider.ml:332-363)

```ocaml
let liveness_mode = Cascade_attempt_liveness_config.current_mode () in
let liveness_observer_opt =
  match liveness_mode with
  | Off -> None
  | Observe | Enforce -> Some (Cascade_attempt_liveness_observer.create ...)
```

즉 **liveness_mode 가 master switch** — cascade 단위도 provider 단위도
아닌 **process 전역 single mode**. `Observe`/`Enforce` 면 모든 attempt 에
observer attach. metric 이 glm 에서는 흐르고 openai_compat 에서는 0 인
것은 *전역 mode 가 Off 가 아님* + *2 차 분기가 SDK 또는 그 사이에
있음* 을 의미.

## 4. Hypotheses

| ID | 가설 | 일차 검증 방법 |
|---|---|---|
| H1 | Agent SDK 가 `Custom_openai_compat` binding 에 대해 `run_stream` 진입 시 outbound HTTP body 의 `stream: true` 필드를 *송신하지 않음* | local llama-server `--verbose` 또는 mitmproxy 로 inbound body capture, `"stream"` 필드 검사 |
| H2 | cascade.toml `streaming = true` provider/model 플래그가 *provider config → SDK request body* 변환 단계에서 dead-read (`Cascade_config.openai_compatible_custom_model` 흐름) | `rg '"stream"' lib/cascade_config*` + `rg 'streaming' lib/oas_compat/` 호출 경로 trace |
| H3 | SDK 는 stream=true 를 송신하고 SSE 를 수신하지만 *openai_compat path 의 chunk parser 가 metric callback chain 으로 forward 하지 않음* (라벨 분류 단계 누락) | metric 의 `provider=""` fallback bucket 에 count > 0 발생 여부 (라벨 누락 emit) |

H1/H2/H3 는 *상호 배타 아님*. Phase 0 이 어느 가설이 참인지 결정한다.

### 4.1 사전 신호 (RFC body 작성 시점에 확보된 정황)

- `lib/llm_metric_bridge.ml:468-469` 에 `~on_streaming_first_chunk:emit_streaming_first_chunk` 가 *global sink* 로 install. 라벨 누락은 emit chain 의 *마지막 단계* 가 아니라 *parser 단계* 일 가능성 높음 (H3 보다 H1/H2 가 더 유력).
- cascade.toml 의 `streaming = true` 가 *capability 선언* 인지 *request body 명시* 인지는 `Cascade_config` 파서가 어떻게 해석하는지에 달림. `rg "\"stream\"" lib/cascade_config*` 결과가 0 hit 이면 H2 강력 확정.
- glm 은 *built-in adapter* (별도 `Provider_runtime_binding.Http` variant), openai_compat 은 *generic adapter* (`Provider_runtime_binding.Custom_openai_compat`). 두 path 가 SDK 내부에서 분기될 가능성 (H1).

## 5. Phase 0 — Diagnostic (no production behavior change)

목적: H1/H2/H3 중 어느 가설(들) 이 참인지 측정으로 확정.

스코프:
1. `lib/cascade_decl/` 또는 `lib/cascade/cascade_config.ml` 에 *임시
   trace log*: provider config → SDK request body 직전 시점의
   `stream` 필드 값 dump (debug level, 1 line/turn).
2. local llama-server 를 `--verbose` 또는 access-logging wrapper 로
   재기동하여 inbound request body 의 `"stream"` 필드 capture
   (5 분 트래픽 sample 충분).
3. `lib/cascade/cascade_runtime_candidate.ml` 의 `provider_label`
   결정 trace — `Custom_openai_compat` candidate 가 어떤 label 로
   classify 되는지.
4. **결과 기록**: 본 RFC §4 표에 측정값 (H1/H2/H3 각각 confirmed |
   refuted) 을 commit msg 와 함께 추가.

Phase 0 PR 은 **production behavior 무변경**. trace 코드는 `-tags trace`
또는 `Log.Misc.debug` 뒤로 격납. Phase 0 closeout 시 trace 제거 또는
영구 metric 으로 승격 결정.

## 6. Phase 1 — Fix (Phase 0 outcome 에 따라 분기)

가설별 대응 (직교적 — 둘 이상 동시 적용 가능):

- **H1 confirmed**: SDK provider binding adapter 가 `Custom_openai_compat`
  에 대해 `stream: true` body field 를 default true 로 송신하도록 수정.
  필요 시 `Cascade_config` 에서 per-model override (`streaming = false`
  허용) 제공.
- **H2 confirmed**: `Cascade_config.openai_compatible_custom_model`
  파서가 model frontmatter 의 `streaming` 플래그를 읽어 SDK request
  builder 에 forward. 현재 dead-read 가 *확인되면* 본 RFC §4.1 의
  `rg` grep 결과를 부록으로 첨부.
- **H3 confirmed**: SDK 가 외부 opam dependency 라 직접 patch 불가
  → cascade transport layer 에 *openai_compat 전용 chunk parser shim*
  을 추가하여 OAS hook chain 에 직접 연결. SDK upgrade path 와 충돌하지
  않는 *layer-above* fix.

Fix 자체는 **production-impacting**. 다음 안전망 적용:
- `feature/rfc-0095-openai-compat-streaming` 브랜치 + Draft PR + sangsu /
  imseonghan / jobsian_purist 등 *runpod_mtp cascade 사용 7 keeper*
  canary observation.
- Rollback path: cascade.toml 에서 `streaming = false` per-model override
  를 1 줄 flip 으로 비활성 가능하도록.

## 7. Phase 2 — Regression test

- `test/test_cascade_streaming_wire_up.ml` (신규): mock openai-compat
  endpoint 를 띄우고 sangsu-like keeper turn 1 회 실행 → metric
  counter `provider="openai_compat"` first_chunk_count > 0 + 라벨
  누락 bucket count = 0 확인.
- TLA+ spec (선택): `liveness_observer_opt = Some` → streaming
  activation 이 invariant 가 되는 spec 1 개. *Phase 1 과 별개로
  진행 가능*; 본 RFC 미포함.

## 8. Expected verification post-fix

| Metric | Before (2026-05-17 measured) | After (expected) |
|---|---|---|
| `masc_llm_provider_streaming_first_chunk_seconds_count{provider="openai_compat"}` | 0 | > 0 within 5 min of sangsu activity |
| `masc_llm_provider_streaming_inter_chunk_seconds_count{provider="openai_compat"}` | 0 | hundreds–thousands per turn |
| sangsu user-perceived TTFR (Time To First Response) | ~5 s (sync wait until full response built) | ~100–300 ms (SSE first chunk) |

## 9. Out of scope

- llama-server `--np 1 → N` slot 확장 (MTP 제약 — `--np 1` mandatory).
  별도 RFC 후보.
- Agent SDK upstream patch (외부 opam dep, version-pinned). 본 RFC 는
  *masc-mcp 측 wire-up* 만 다룬다.
- glm provider streaming 성능 튜닝 — 이미 정상 동작.
- Dashboard 가 user 에게 streaming SSE 를 직접 노출하는 UX (RFC-0033
  worktree status SSE 와 무관, 별도 영역).
- llama-server 자동 launchd 등록 (운영 영역).

## 10. Open questions

1. `Cascade_attempt_liveness_config.current_mode ()` 의 default 값과
   env override (`MASC_CASCADE_LIVENESS_MODE` 류) 존재 여부. Phase 0
   에서 production process 의 *실제* mode 측정 필요 — `Off` 라면
   가설이 무너지고 다른 진단 경로 필요.
2. Phase 0 의 trace log 가 production 트래픽에 가시적 overhead 를
   주는가 (per-turn 1 line debug emit 의 cost). 사전 측정 후 trace
   merge 결정.
3. Fix 가 H3 (SDK shim) 으로 떨어지면 SDK 버전 lock 영향 — `opam
   upgrade` 시 shim 이 stale 되지 않도록 SDK behavior 의 invariant
   contract 가 필요. Phase 1 시점에 재평가.
4. cascade.toml 의 `streaming = true` 플래그가 *capability 선언* 인지
   *호출 명시* 인지 — 현재 의미가 *capability 선언* 으로만 활용된다면
   별도 `request_stream = true` 같은 명시적 필드 추가가 더 정직할 수
   있다. RFC-0058 (declarative cascade config) 의 schema 와 cross-ref.

## 11. References

- Evidence dump timestamp: 2026-05-17 KST, masc-mcp uptime 31 분 단계
  Prometheus metric snapshot.
- RFC-0047 (OAS adapter decomposition) — file-rename scope, 본 RFC 와
  직교.
- RFC-0045 (SDK turn boundary alignment) — Agent SDK ↔ keeper FSM 경계
  영역; H1/H3 fix 시 SDK contract 영향 평가의 출발점.
- RFC-0033 (Worktree Status SSE) — *dashboard* SSE 영역, 본 RFC 와 무관
  하지만 SSE 키워드 검색 시 collision 후보로 명시.
- RFC-0058 (Declarative cascade config) — `streaming = true` 플래그의
  schema-level 의미 정의 위치; §10 question 4 cross-ref.
- `feedback_lint_string_classifier_is_workaround_not_fundamental` —
  symptom-suppression 거부 원칙. 본 RFC 는 *근본 wire-up* 추구이며,
  metric label "" 을 lint 로 차단하는 식의 우회는 반려한다.
- llama.cpp PR #22673 (Multi-Token Prediction, merged 2026-05-16) —
  로컬 35B-A3B 검증 environment.
