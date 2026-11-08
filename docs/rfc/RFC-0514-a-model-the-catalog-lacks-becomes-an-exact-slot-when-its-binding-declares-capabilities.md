---
rfc: "0514"
title: "카탈로그에 행이 없는 모델도 바인딩이 능력을 적으면 exact 슬롯이 된다"
status: Draft
created: 2026-11-08
updated: 2026-11-08
author: claude
supersedes: []
superseded_by: null
related: ["runtime-two-layers"]
---

# RFC-0514 — 카탈로그에 행이 없는 모델도 바인딩이 능력을 적으면 exact 슬롯이 된다

## 0. 요약

- 운영자가 Tinker에서 학습한 LoRA 체크포인트로 Lane Add-on의 exact 출력을 받으려 한다.
  체크포인트 이름은 `tinker://<run-id>:train:0/sampler_weights/<name>` 모양이다.
  이름은 계정마다 다르고, 체크포인트는 만료된다.
  그래서 공개 카탈로그(`packages/agent_core/models.toml`)에 행으로 적을 수 없다.
- 지금 exact 슬롯은 (provider, model id)가 카탈로그 모델 행과 같아야 붙는다.
  행이 없으면 부팅 때 레지스트리에서 빠진다.
- Keeper 턴은 이미 다른 규칙을 쓴다.
  [RFC-runtime-two-layers](RFC-runtime-two-layers.md) 「우리가 안 싣는 모델」은 카탈로그가 모르는 모델의 능력 표를 배포가 선언한다고 정했다.
- 이 RFC는 그 규칙을 exact 출력까지 넓힌다. 두 곳을 고친다.
  1. MASC adapter: 모델 행 없이 provider 기본값(preset)만 답하면 바인딩의 능력 표를 전부 읽는다. 지금은 네 칸만 읽는다.
  2. agent_core exact resolver: 모델 행이 없어도 바인딩이 능력을 선언했으면 provider 행에 묶는다.
- 새 카탈로그 필드, 이름 접두어 규칙, 호환 코드, 새 거절 사유는 없다.
  능력 표가 없는 행 없는 모델은 지금처럼 거절된다.

## 1. 지금

줄 번호는 main `fe6cd3cc0bd2` 기준이다.

### 1.1 exact 슬롯은 카탈로그 모델 행에만 붙는다

- `Exact_output_catalog_binding.resolve_exact`
  (`packages/agent_core/lib/llm_provider/exact_output_catalog_binding.ml:137-158`)는 provider 행을 id로 찾는다.
  그다음 그 provider의 모델 행을 model id로 찾는다. 행이 없으면 `Model_missing`이다.
- resolver는 `Model_missing`을 `reject Target_model`로 바꾼다(`exact_output_resolver.ml:721`).
  MASC 레지스트리는 그 슬롯을 `Target_not_in_catalog`로 뺀다.
- 바인딩이 능력을 선언해도 결과는 같다.
  선언(`model_capabilities_override`)은 행을 찾은 뒤에만 읽힌다(`exact_output_resolver.ml:759-765`).

### 1.2 행 없는 모델의 능력 표는 네 칸만 읽힌다

- adapter는 먼저 카탈로그 답을 구한다(`lib/runtime/runtime_adapter.ml:722-725`).
- provider 행에 `capabilities_base`가 있으면 모델 행이 없어도 답은 그 preset이다
  (`packages/agent_core/lib/llm_provider/capabilities.ml:546-568`, `catalog_snapshot.ml:41-45`).
- 답이 있으면 `declared_capabilities_override_of_model_spec`(`runtime_adapter.ml:405-442`)는 능력 표에서 네 칸만 덮는다.
  `max-output-tokens`, `thinking-control-format`, `accepted-reasoning-efforts`, `reasoning-streaming-format`이다.
  나머지 칸은 preset 값이 남는다. `max_context_tokens`도 preset 값인 `None`이다.
- 능력 표 전체를 읽는 갈래(`runtime_adapter.ml:443-500`)는 카탈로그 답이 없을 때만 돈다.
  provider까지 카탈로그에 없을 때다.
- Tinker 체크포인트가 이 경우에 걸린다.
  - `tinker` provider 행은 `capabilities_base = "openai_chat"`이다(`models.toml:3023-3029`).
  - 이 preset은 JSON mode와 native schema를 켠다(`capability_profile.ml:427`).
  - Inkling 2 Small 모델 행은 둘 다 끈다(`models.toml:2342-2363`).
  - 체크포인트 바인딩에 `supports-response-format-json = false`를 적어도 읽히지 않는다.
- 부팅 검사 `missing_runtime_model_capabilities`(`lib/runtime/runtime.ml:297-322`)도 preset을 답으로 센다.
  그래서 preset이 있는 provider 아래에서는 능력 표 없는 모델도 부팅을 통과한다.
  RFC-runtime-two-layers 186행의 "표가 없으면 부팅 때 잡는다"는 preset 없는 provider에서만 맞다.

### 1.3 exact는 행 없는 슬롯을 창 크기로 미리 막지 않는다

- 보내기 전 창 검사는 모델 행에 `serving_constraint`가 있을 때만 돈다
  (`exact_output_flow_admission.ml:216-233`). 이 값은 카탈로그 행에서만 온다.
- 그래서 행 없는 슬롯의 창은 두 곳에서만 읽힌다.
  대상 지문(`exact_output_catalog_binding.ml:218`)과 `Provider_config.max_context`(`exact_output_resolver.ml:811`)다.
- 창을 넘는 요청은 endpoint가 HTTP 400으로 돌려주고, 슬롯 순회가 다음 슬롯으로 넘어간다.
  이 RFC는 이 동작을 바꾸지 않는다.

## 2. 바꿈

### 2.1 adapter: 행이 답했는지 preset만 답했는지 나눈다

- agent_core request policy가 카탈로그 답의 출처를 닫힌 합타입으로 돌려준다.
  모델 행이 답함, provider preset만 답함, 답 없음의 세 갈래다.
  지금은 `model_capabilities : capabilities option` 하나라서 앞의 두 갈래를 구별할 수 없다.
- adapter는 세 갈래를 `match`로 다룬다.
  - 모델 행이 답함: 지금과 같다. 행을 지키고 네 칸만 덮는다.
  - preset만 답함: 바탕은 preset이다. 바인딩이 적은 값은 모두 바탕을 덮는다.
    `[models.X]`의 `max-context`, `tools-support`, `streaming`, `thinking-support`와 능력 표의 모든 칸이다.
    적지 않은 칸은 preset 값이 남는다(#37435와 같은 규칙).
    `tools-support`와 `streaming`은 적지 않아도 preset을 덮는다. 파서가 적지 않은 줄을 각각 `false`와 `true`로 채워서 늘 값이 있다.
    미디어 입력 칸만은 적지 않으면 `false`다. 「답 없음」 갈래와 같은 규칙이다.
  - 답 없음: 지금과 같다.
- 이 규칙은 Keeper 턴에도 그대로 적용된다.
  한 바인딩은 Keeper 턴과 exact에 같은 능력으로 답한다.
  resolver도 같은 원칙을 따른다(`exact_output_resolver.ml:736-740` 주석).
- 2026-11-08 라이브 설정에서 카탈로그 provider 아래 행 없는 바인딩은 2개다. 둘 다 능력 표가 있다.
  - `supports_named_tool_choice`가 preset의 `true`에서 운영자가 적은 `false`로 바뀐다.
  - `max_context_tokens`가 `None`에서 적은 창으로 바뀐다.
    Keeper 창은 지금도 그 값이다(`runtime_adapter.ml:625-648`).
  - 나머지 칸은 적은 값과 preset 값이 같다.

### 2.2 resolver: 능력을 선언한 바인딩은 행 없이 묶인다

- resolver fold(`exact_output_resolver.ml:714-722`)는 `Model_missing`을 두 갈래로 나눈다.
  - 대상이 `Binding_wire`이고 바인딩에 `model_capabilities_override = Some caps`가 있으면 provider 행에 묶는다. 능력은 `caps`다.
  - 그 밖은 지금처럼 `reject Target_model`이다. `Catalog_provider_wire` 대상과 선언 없는 바인딩이 여기에 든다.
- fold가 넘기는 `(target, provider, model)`의 세 번째 값을 닫힌 합타입으로 바꾼다.
  모델 행으로 묶임(`model_entry`)과 바인딩 선언으로 묶임(`capabilities`)이다.
  뒤 fold의 `match`가 두 갈래를 다 다룬다.
- 바인딩 선언으로 묶인 대상은 아래 값을 쓴다.
  - 능력: 바인딩 선언이다. `Binding_wire` 갈래가 이미 이렇게 읽는다(`:759-760`).
  - Anthropic thinking 정책: 모델 행 정책이 없다. 바인딩의 `model_anthropic_thinking_control_override`만 읽는다.
  - 지문: 대상 지문은 이미 `functional_capability_projection capabilities`를 담는다(`:856-858`).
    선언이 바뀌면 지문도 바뀐다.
- 카탈로그 증거(`canonical_catalog_evidence`, `:474-565`)는 바꾸지 않는다.
  증거를 읽는 곳은 측정 영수증뿐이다(`exact_output_measurement_receipt.ml`).
  측정은 serving constraint가 있는 행에서만 돈다.
- agent_core에는 MASC 이름도 Tinker 이름도 들어가지 않는다.
  더하는 규칙은 하나다. 바인딩 wire가 선언한 능력은 카탈로그가 모르는 모델에 답한다.

### 2.3 운영자가 적는 모양

체크포인트를 학습한 기본 모델 행의 값을 옮겨 적는다. 아래는 Inkling 2 Small 체크포인트의 예다.

```toml
[models.librarian-checkpoint]
api-name = "tinker://<run-id>:train:0/sampler_weights/<name>"
max-context = 262144            # 학습한 base ID의 창
tools-support = true
thinking-support = true
streaming = true
reasoning-effort = "low"

[models.librarian-checkpoint.capabilities]
accepted-reasoning-efforts = ["minimal", "low", "medium", "high", "xhigh"]
thinking-control-format = "reasoning-effort-default-on"
reasoning-streaming-format = "delta:reasoning_content"
supports-response-format-json = false
supports-structured-output = false

[tinker.librarian-checkpoint]
```

- 슬롯 목록에는 `"tinker.librarian-checkpoint"`를 넣는다. 되돌릴 때는 슬롯 목록만 고친다.
- 요청의 출력 상한은 레인의 `max_output_tokens`가 정한다(`lib/runtime/runtime_exact_output_registry.ml:684-689`).
  레인 값이 없으면 요청에 출력 상한이 실리지 않고, endpoint 기본값이 상한이 된다.
  능력 표의 `max-output-tokens`는 넘는 요청 값을 깎는 데만 쓴다(`backend_openai_request.ml:228-247`).

### 2.4 왜 이 길인가

| 길 | 장점 | 단점 |
| --- | --- | --- |
| 공개 카탈로그에 체크포인트 행 | 코드를 안 바꾼다 | 계정 값이 공개 저장소에 들어간다. 학습할 때마다 행이 늘고, 체크포인트가 만료된다 |
| `AGENT_CORE_MODEL_CATALOG` 파일 | 코드를 안 바꾼다 | 내장 카탈로그를 통째로 바꾼다. 바이너리를 올려도 그 파일의 행은 낡은 채 남는다(RFC-runtime-two-layers) |
| 이름 접두어(`tinker://` → 기본 모델 행) | 운영자가 적을 것이 없다 | 문자열 분류기다. 체크포인트 이름만으로는 기본 모델을 알 수 없다 |
| 운영자 카탈로그 덧붙임 파일 | 행 모양을 그대로 쓴다 | 설정 면과 병합 규칙이 새로 생긴다. 한 모델에 바인딩 선언과 덧붙인 행, 두 답이 생긴다 |
| 이 RFC: exact도 바인딩 선언을 읽는다 | 새 키가 없다. 한 바인딩이 Keeper 턴과 exact에 같은 능력으로 답한다 | 운영자가 기본 모델 행의 값을 바인딩에 다시 적는다. 적지 않은 칸은 preset 값을 따른다 |

- 마지막 단점의 결과는 이렇다.
  운영자가 `supports-response-format-json = false`를 빠뜨리면 exact 요청에 `response_format`이 실린다.
  endpoint가 그 요청을 거절하면 그 슬롯이 실패하고, 순회가 다음 슬롯으로 넘어간다.
  실패는 exact 요청 저장소와 서버 로그에 남는다.
- exact에서만 칸마다 선언을 강제하는 길도 봤다.
  그러면 같은 바인딩이 Keeper 턴에서는 preset 값으로 돌고, exact에서는 거절된다.
  한 바인딩의 답이 둘이 되므로 이 길은 택하지 않는다.

## 3. 그대로인 것

- 카탈로그 모델 행이 있는 바인딩. 행이 답하고 바인딩은 네 칸만 덮는다.
- provider가 카탈로그에 없는 바인딩(설치 마법사가 만든 provider 등).
  exact에서는 지금처럼 `Target_provider`로 빠지고, Keeper 턴의 「답 없음」 갈래도 그대로다.
- 보내기 전 창 검사. serving constraint가 있는 행에서만 돈다.
- 부팅 검사 `missing_runtime_model_capabilities`.
  preset이 있는 provider 아래에서 표 없는 모델은 Keeper 턴에서 preset으로 돈다. exact에서는 선언이 없으니 빠진다.
- 슬롯 순회, 레인 설정 모양, 카탈로그 증거 모양.

## 4. 구현 층

이 RFC를 맨 아래에 두고 gh stack 하나로 쌓는다.

| 층 | 내용 |
| --- | --- |
| 1 | 이 RFC |
| 2 | request policy가 답의 출처를 돌려주고, adapter가 preset만 답한 모델의 표를 전부 읽는다(§2.1). PR 본문에 라이브 행 없는 바인딩의 능력 변화를 싣는다 |
| 3 | exact resolver가 선언한 바인딩을 행 없이 묶는다(§2.2). 기능 시험(§5)과 낡는 글 고침을 같이 싣는다 |

3층에서 고칠 글:

- `docs/guides/tinker-integration.md`의 exact 절(71행)과 체크포인트 절(77행)
- `config/runtime.toml` Tinker 예시 주석(577-584행)
- `packages/agent_core/test/test_provider_config.ml:1950-1953` 주석
- `lib/runtime/runtime.ml:2146` 로그 문구. 모델 행이 없을 때 능력 표를 적는 길을 알려 준다
- RFC-runtime-two-layers 186행. preset이 있는 provider에서는 부팅 검사가 표 없는 모델을 잡지 않는다고 고친다

## 5. 시험

- 기능 시험 하나를 3층에 둔다. runtime.toml 문자열로 exact 레지스트리를 만든다.
  - provider 행만 있고 모델 행이 없는 모델에 능력 표를 적은 바인딩은 슬롯이 된다.
    슬롯 능력에는 적은 창과 `supports_response_format_json = false`가 있다.
  - 같은 모델에 능력 표가 없는 바인딩은 `Target_not_in_catalog`로 빠진다.
- 확인은 PR CI의 타입 검사·시험과 현재 head 독립 리뷰로 한다.
- 설치 뒤에는 두 가지를 본다.
  - 부팅 로그에 체크포인트 슬롯의 `Target_not_in_catalog`가 없다.
  - 그 슬롯이 보낸 첫 admission 요청 본문에 `response_format`이 없다.
