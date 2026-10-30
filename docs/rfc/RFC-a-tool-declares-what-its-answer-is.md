---
rfc: "a-tool-declares-what-its-answer-is"
title: "도구가 자기 출력에서 답을 읽는 법을 정하고, 반복 감지는 그 답만 비교한다"
status: Implemented
created: 2026-10-07
updated: 2026-10-08
author: claude
supersedes: []
superseded_by: null
related: ["a-request-carries-what-the-librarian-has-not-read", "durable-tool-result-markers"]
---

# RFC: 도구가 자기 출력에서 답을 읽는 법을 정한다

- 상태: 구현됨. D1~D3 은 #41398 로 main 에 들어갔다. 구현과 이 문서의 차이는 §9 에 적었다.
- 근거: `docs/evidence/tool-answer-identity-20261006/`. 라이브 base path 를 읽기만 한 측정이고, 명령은 그 README 에 있다.
- 이슈: #41377.

## 0. 요약

Keeper 의 반복 감지는 입력과 출력이 모두 같은 호출이 턴 안에서 세 번 나오면 턴을 멈춘다. 출력이 같다는 것이 "세상이 그대로다"의 증거이기 때문이다.

그런데 도구 응답에 호출마다 바뀌는 영수증 값이 들어 있으면, 아무것도 바뀌지 않아도 출력이 매번 다르다. 그러면 반복 감지는 영영 발동하지 않는다. 지금까지 두 번 이렇게 됐다.

| 날짜 | 도구 | 바뀐 값 | 고친 방법 |
|---|---|---|---|
| 2026-08-24 | `Execute` | `execution_time_ms` | 반복 감지가 모든 JSON 출력에서 그 필드 이름을 빼고 해시한다(`measurement_field`) |
| 2026-10-05 | `keeper_memory_write` | `recorded_at`, `revision` | 고침 없이 두 턴이 루프를 돌았다 |

두 번째 경우에 sangsu 의 두 턴이 쓰기 12가지를 합쳐 1,861번 되풀이했고, 그 두 턴이 토큰 약 12억 8천만 개를 썼다(`RFC-a-request-carries-what-the-librarian-has-not-read` §2.2).

첫 번째 고침은 반복 감지가 도구 하나의 필드 이름을 아는 방식이다. 세 번째 도구가 생기면 또 이름을 더해야 한다. 이 RFC 는 그 판단을 도구에게 옮긴다. 도구마다 "내 출력에서 답은 이 부분이다"를 읽는 함수를 정하고, 반복 감지는 그 답만 비교한다.

## 1. 결정

| # | 물음 | 결정 |
|---|---|---|
| D1 | 답은 누가 어디에 정하나 | Keeper 도구의 핸들러 variant(`Keeper_tool_descriptor.runtime_handler`)마다 답을 읽는 법을 빠짐없는 `match` 로 정한다. "출력 전체"도 그중 하나로 이름 붙여 고른다 |
| D2 | 반복 감지는 무엇을 비교하나 | 지문을 계산하는 다섯 곳이 모두 같은 함수로 답을 읽고, 답의 지문을 비교한다. 답을 읽지 못한 출력은 지금처럼 출력 전체의 지문이다 |
| D3 | 지금 두 도구는 어떻게 되나 | `Execute` 와 `keeper_memory_write` 가 답을 읽는 법을 정하고, 반복 감지 안의 `measurement_field` 는 지운다 |

## 2. 무슨 일이 났나

- sangsu 의 두 루프 턴(atom 2077..4463)에서 `keeper_memory_write` 가 2,355번 불렸다. 입력은 494가지였다. 482가지는 한 번씩, 12가지는 각각 156번이나 157번 쓰였다(`memory-write-receipts.json`).
- 12가지 모두 응답이 매번 달랐다. 두 번째부터는 아무것도 새로 만들지 않았다(`identity_disposition: "reobserved"`). 다시 관찰한 응답 둘 사이에 다른 키는 `recorded_at` 과 `revision` 뿐이었다.
- 입력만 보는 축(같은 입력 5번 연속)도 피했다. 모델이 메모 12가지를 돌아가며 써서, 같은 입력이 연달아 온 적이 없다.
- 다른 도구는 아직 이렇게 되지 않았다. 호출 기록에 지문이 남은 약 16시간(10-06 00:17Z 부터) 동안, 같은 턴에 같은 입력으로 3번 넘게 불렸는데 출력이 한 번도 같지 않았던 묶음은 11개였다. 9개는 바뀐 키가 상태 값이었다(DOS 에뮬레이터, 보드 스냅숏, 파일 내용, `Execute` 출력). 2개는 JSON 이 아니어서 바뀐 키를 알 수 없다(`ledger-scan.json`).

## 3. 지금 구조

- 반복 감지는 두 축이다(`keeper_agent_run.ml`).
  - 정확 축: 입력 지문과 출력 지문이 같은 호출이 턴 안에서 3번(`repeated_tool_call_yield_threshold`). 붙어 있지 않아도 센다.
  - 입력 축: 같은 입력이 5번 연달아(`repeated_tool_call_input_yield_threshold`). 출력은 보지 않는다. 도구가 `Progress` 를 선언한 호출은 이 축에서 빠진다.
- 지문은 `Keeper_tool_progress_identity.digest_tool_io ~tool_name ~input ~output_text` 가 만든다. 출력이 JSON 이면 모든 깊이에서 `execution_time_ms` 를 빼고 해시한다. 결과는 `{tool_name; input; output_text}` 를 키로 하는 메모(`Io_memo`)에 남는다.
- 지문을 계산하는 곳은 다섯이다.
  - 실행 중: post-tool hook(`keeper_run_tools_hooks.ml`), agent-core hook(`keeper_hooks_agent_core.ml`), MCP 호출 기록(`mcp_server_eio_call_tool.ml`).
  - 공식 클라이언트 호스트의 자기 반복 중단(`keeper_official_client_host.ml` 의 `dynamic_tool_fingerprint`, 기준 3). 모델이 본 것을 해시한다.
  - 이력: `digest_history_pairs`. 체크포인트의 ToolResult 본문에서 다시 계산한다.
- 자율 턴은 시작할 때 호출 기록의 최근 200행을 읽어 시드에 더한다(`keeper_run_tools_setup.ml`, #41234). 이력에 이미 있는 `tool_use_id` 의 행은 뺀다.

## 4. 설계

### 4.1 D1 — 핸들러마다 답을 읽는 법

- `runtime_handler` 를 받아 답 읽기를 돌려주는 함수를 하나 둔다. 빠짐없는 `match` 이고 `_ ->` 가 없다. 새 핸들러를 더하면 컴파일러가 답 읽기를 정하라고 막는다.
- 답 읽기는 둘 중 하나다.
  - `Whole_output`: 출력 전체가 답이다. 지금과 같은 지문이다.
  - 출력 원문에서 답을 읽는 순수 함수: 같은 질문에 같은 답인지 가르는 부분만 고른다. 영수증 정보(시각, 저장소 버전, 실행 시간)는 고르지 않는다.
- 답을 읽는 함수는 그 출력을 만드는 도구 모듈에 둔다. 출력 모양을 바꾸는 사람이 같은 자리에서 답 읽기도 고친다. 출력과 답 읽기를 같이 시험하는 테스트가 둘을 묶는다.
- Keeper 도구 목록 밖의 도구(외부 MCP 도구 등)는 핸들러가 없다. 이름으로 찾았을 때 없다는 것을 이름 붙인 경우로 받고, 출력 전체를 쓴다.
- 모델이 읽는 출력은 바꾸지 않는다. 답 읽기는 반복 감지만 쓴다.

### 4.2 D2 — 다섯 곳이 같은 답을 본다

- `digest_tool_io` 가 도구 이름으로 핸들러를 찾고, 답 읽기를 출력 원문에 적용한다. 답을 읽으면 출력 지문은 답의 지문이다. 읽지 못하면(실패 결과처럼 모양이 다른 원문) 출력 전체의 지문이다.
- 답은 `(tool_name, output_text)` 만으로 정해진다. 그래서 다음이 따라온다.
  - 메모 키(`{tool_name; input; output_text}`)는 그대로 맞다. 누가 먼저 계산해도 같은 답이 나온다.
  - 이력에서 다시 계산해도 실행 중과 같은 지문이 나온다. 재시작 앞뒤의 같은 호출이 맞는다.
  - 공식 클라이언트 호스트의 지문도 텍스트 결과에는 같은 답 읽기를 쓴다. 블록 결과(이미지 등)는 지금처럼 모델이 본 것 전체다.
- 반복 감지의 두 축과 숫자는 바꾸지 않는다.

### 4.3 D3 — 지금 두 도구

- `Execute`: 답은 성공 응답에서 실행 시간(`execution_time_ms`)을 뺀 나머지다. 종료 상태, 출력, 실행 위치, 시간 초과 표시 같은 필드는 모두 답에 남는다(`keeper_tool_execute_runtime.ml` 의 성공 응답). 그 한 필드를 빼는 일은 이 응답을 만드는 `Execute` 모듈이 자기 출력에만 한다. 반복 감지가 모든 도구에 거는 지금과 다르다.
- 그러면 `measurement_field` 와 `drop_measurement` 는 반복 감지에서 지운다. 지금 출력에 `execution_time_ms` 를 최상위 키로 싣는 곳은 `Execute` 성공 응답뿐이다. 실패 응답은 다리(`tool_bridge.ml`)가 문자열 뒤에 `failure_class` 를 붙이거나 다른 JSON 으로 감싸서 내보낸다. 10-01~06 호출 기록에서 그 키가 최상위에 있는 출력은 `Execute` 78,904건뿐이었다. `keeper_artifact_read` 등 2,771건은 저장된 본문 문자열 안에 그 글자가 있을 뿐이라, 지금의 이름 빼기도 닿지 않는다. 그래서 다른 도구의 지문은 바뀌지 않는다.
- `keeper_memory_write`: 답은 영수증 키 한 목록(`Write_receipt_key.answer`)에 이름이 있는 필드다. 일반 쓰기는 `memory_id`, `identity_disposition`, `outcome` 등이, source-bound 쓰기는 `source_path`, `source_sha256` 이 그 목록에 있어 같은 필터로 답에 남는다. `revision`, `recorded_at`, 건수, 설명 문장은 목록에 없다. 모양이 다른 별도 답을 두지 않고 한 목록을 거르는 이유는, 영수증을 쓰는 곳과 답을 읽는 곳이 같은 키 이름을 쓰게 하려는 것이다. source-bound 다시 쓰기는 실제 변경이다(`test_source_bound_rewrite_renews_first_seen`).
- 나머지 핸들러는 모두 `Whole_output` 을 이름으로 고른다. 지문은 지금과 같다.
- 이름 빼기를 시험하던 테스트(`test_keeper_tool_progress_identity.ml` 의 "measurement does not name identity", "nested measurement is dropped too")는 `Execute` 의 답 읽기로 같은 결과를 내도록 다시 쓴다. "nested" 경우는 테스트 fixture 에만 있는 모양이라 지운다.

### 4.4 남는 틈

- 배포 경계. 배포 전에 쓴 호출 기록 행에는 옛 지문이 있다. 배포 직후 한 사이클 동안, 기록 행으로만 시드되는 `Execute`·`keeper_memory_write` 호출은 새 지문과 맞지 않는다. 한 번뿐이다.
- 강등된 이력 본문. 이력 본문이 blob 마커로 바뀌면 다시 계산한 지문은 저장된 본문의 정체가 되어 실행 중 지문과 다르다. 이 틈은 지금도 있다(`RFC-durable-tool-result-markers`). 이 RFC 가 넓히지도 좁히지도 않는다.

## 5. 하지 않는 것

- 반복 감지의 축과 숫자를 바꾸지 않는다.
- 반복 감지 안에 도구별 필드 이름을 두지 않는다. 답을 고르는 일은 그 출력을 만드는 도구가 한다.
- 모델이 읽는 출력을 바꾸지 않는다.
- `Whole_output` 을 고른 도구의 지문을 바꾸지 않는다.

## 6. 검증

| 대상 | 테스트 | 라이브에서 볼 값 |
|---|---|---|
| D1 | 답 읽기 함수가 모든 `runtime_handler` 를 `_ ->` 없이 다룬다(컴파일). 답을 읽는 도구마다, 출력을 만들고 그 출력에서 답을 읽는 왕복 테스트 | — |
| D2 | 영수증만 다른 두 출력의 지문이 같다. 답이 다르면 지문이 다르다. 이력 본문에서 다시 계산한 지문이 실행 중 지문과 같다. 메모에 먼저 들어간 쪽과 무관하게 같다 | — |
| D3 | `Execute`: 출력이 같고 실행 시간만 다른 호출 셋이 정확 축에서 멈춘다(8/24 경우, `measurement_field` 없이). `keeper_memory_write`: 같은 쓰기 셋이 정확 축에서 멈춘다. source-bound 다시 쓰기는 다른 답이다 | `Repeated_tool_call` yield 가운데 `keeper_memory_write`·`Execute` 의 수 |
| 전체 | — | `evasion.py` 를 돌려, 같은 입력·매번 다른 출력 묶음의 바뀐 키가 영수증 값인 도구를 찾는다. 찾으면 그 도구의 답 읽기를 고친다 |

## 7. 확신도

- 높음: 두 사례의 원인(응답 비교, 코드 주석, 테스트 이름이 같은 말을 한다).
- 높음: 답이 원문만으로 정해지면 다섯 곳·이력·메모가 같은 지문을 본다는 것. 순수 함수의 성질이다.
- 중간: 다른 도구가 아직 이 문제를 갖지 않았다는 것. 지문이 남은 기록이 약 16시간뿐이다.

## 8. 열어 둔 물음

- 답을 읽는 함수는 모델이 보는 원문을 다시 파싱한다. 대가로 출력과 답 읽기를 같은 모듈에 두고 왕복 테스트로 묶는다.
- 답 읽기를 핸들러 variant 로 고르면, 한 variant 를 여러 도구가 나눠 쓰는 경우(board, voice, task 같은 cluster 도구는 `internal_name` 이 다르고 핸들러가 같다, `keeper_tool_descriptor.ml` 의 `cluster_descriptor_*`) 그중 한 도구만 영수증 필드를 얻어도 컴파일러가 결정을 요구하지 않는다. 지금 답을 읽는 핸들러(`Tool_execute`, `Tool_memory_write`)는 도구 하나씩이고 나눠 쓰는 variant 는 모두 `Whole_output` 이라 아직 틀린 곳은 없다. 읽는 법을 도구(descriptor) 단위로 묶을지는 정해야 한다.
- 호출 기록 시드(`seed_tool_calls_from_ledger`)는 최근 200행을 `keeper_turn_id` 와 상관없이 읽고, 정확 축은 시드에 있는 같은 지문을 턴 경계 없이 센다. 답만 비교하면 서로 다른 세 턴에서 한 번씩 한 정당한 같은 쓰기도 세 번으로 세어져 정확 축이 멈출 수 있다. 시드가 여러 사이클에 걸친 반복(`keeper_run_tools_setup.ml` 주석)을 잡으려고 일부러 턴 경계를 넘는 것이라 이 RFC 는 그 범위를 바꾸지 않았다. 멈춘 뒤 한 번 재개하는 비용을 받아들일지, 시드를 턴으로 좁힐지는 측정이 필요하다.

## 9. 구현 현황

#41398 이 §4 의 설계대로 들어갔다. `Keeper_tool_answer`(`reader`, `resolve`, `answer`)가 모든 `runtime_handler` 를 `_ ->` 없이 다루고, `Keeper_tool_progress_identity` 와 공식 클라이언트 호스트의 `dynamic_tool_fingerprint` 가 `Keeper_tool_answer.answer` 를 쓴다. `measurement_field` 는 반복 감지에서 사라졌다.

설계와 다른 점은 둘이다.

- `keeper_memory_write` 의 답은 `ok`, `error_kind`, `effect_disposition`, `detail`, `outcome`, `store`, `memory_id`, `identity_disposition`, `basis`, `supersedes` 계열, `source_path`, `source_sha256`, `missing_premise_ids`, `removed_memory_ids`, `support_invalidations` 이다. 실패 응답도 `ok` 가 있으면 같은 필터를 탄다. §4.3 은 대표 필드만 적었다.
- 목록에 없는 새 필드는 답에서 빠진다. 그 필드가 실제 변경을 담으면 서로 다른 결과가 같은 답으로 판정되어 반복 감지가 작업을 일찍 멈출 수 있다. 구현 주석은 이를 재개 비용으로 설명한다(`keeper_tool_memory_runtime.ml`).
