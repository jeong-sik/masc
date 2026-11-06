---
rfc: "0508"
title: "blob 마커는 답 지문을 싣지 않고, 답의 정체성은 저장된 blob 에서 다시 계산한다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["0499"]
implementation_prs: []
---

# RFC-0508 — blob 마커는 답 지문을 싣지 않는다

## 0. 요약

저장된 도구 결과는 모델에게 `[masc:blob sha256=<산출물> bytes=… mime=… answer_sha256=<답 지문> preview=…]` 한 줄로 간다. Keeper 가 둘째 해시를 `keeper_artifact_read` 에 넣어 실패한다(#49396). 마커가 지문을 싣지 않게 한다. 답의 정체성은 지금도 저장된 blob 에서 다시 계산해 확인하므로, 선언 없이 그 계산만 쓴다.

## 1. 문제

- 11-01 ~ 11-06T13:30Z 의 `keeper_artifact_read` 17,299번 중 299번(1.73%)이 `artifact does not exist` 로 끝났다(#49396, 재는 법은 #49286 `docs/evidence/artifact-read-misses-2026-11/`).
- 원본 기록에 해시가 남은 14개 중 13개가 직전 결과 마커의 `answer_sha256=` 값이었다. 실패 뒤 10분 안에 다른 해시로 읽기에 성공한 것은 61% 다.
- 모델은 `answer_sha256=` 를 쓸 곳이 없다. 그 값은 MASC 가 같은 답의 반복 호출을 알아보는 데만 쓴다.

없음 거절이 맞는 필드를 알려 주는 일은 #49420 이 한다. 이 RFC 는 혼동의 원인을 없앤다.

## 2. 지금 모습 (origin/main d523427a2ec)

- 쓰는 쪽: `Tool_projection.semantic_answer_fingerprint` 가 도구의 answer reader 를 살아 있는 결과에 돌려 지문을 만든다. reader 가 답을 내지 않으면 지문도 없다. `Tool_output.with_answer_fingerprint` 가 `artifact_ref.answer_fingerprint` 에 넣고, `encode_for_agent_core` 가 마커에 `answer_sha256=` 로 쓴다.
- 마커 글은 저장되는 글이면서 모델에게 가는 글이다. `encode_for_agent_core` 를 부르는 곳이 lib 에 12곳 있다. 모델에게 보낼 때만 빼는 한 자리가 없다.
- 읽는 쪽: `Keeper_tool_answer.verified_stored_answer` 는 선언(`answer_fingerprint = Some declared`)이 있을 때만 blob 을 읽는다. 길이를 맞춰 보고, 같은 reader 를 저장된 내용에 돌려 지문을 다시 계산한다. 두 값이 같을 때만 답을 돌려준다. `Keeper_tool_progress_identity.output_evidence` 는 답이 없으면 blob 주소를 정체성으로 쓴다.
- journal: `keeper_tool_execution_journal_json.ml` 이 참조와 함께 `answer_fingerprint` 를 필드로 저장한다. 필드 목록은 엄격하다(`["reference"; "answer_fingerprint"]`).
- 디코더: `decode_from_agent_core` 는 두 형식(토큰 있음·없음)을 읽는다. 토큰 값은 sha256 hex 로 검사한다.
- 대시보드: `dashboard/src/lib/tool-blob-marker.ts` 가 토큰을 선택 항목으로 읽어 `answerSha256` 에 담는다. 이 값을 쓰는 화면은 없다.

선언은 같은 reader 의 같은 계산을 쓸 때 한 번, 읽을 때 한 번 해서 견준다. blob 은 내용 주소라서, 읽을 때의 계산은 쓸 때 저장한 바로 그 바이트를 본다.

## 3. 결정

- D1. `encode_for_agent_core` 는 `answer_sha256=` 를 쓰지 않는다. 새 마커는 `[masc:blob sha256=… bytes=… mime=… preview=…]` 다.
- D2. `verified_stored_answer` 는 선언 없이 동작한다. 도구가 답을 읽는 도구(`Reads_answer`)이면 blob 을 읽고 길이를 맞춰 보고 reader 를 돌린다. 답이 나오면 그 답을 돌려준다. 선언과 견주는 단계는 없다.
- D3. 쓰는 쪽의 지문은 죽은 개념이 되므로 지운다: `artifact_ref.answer_fingerprint`, `Tool_output.with_answer_fingerprint`, `Tool_projection.semantic_answer_fingerprint`, `?answer_fingerprint` 인자(`Tool_projection`, `Tool_bridge`).
- D4. 디코더는 옛 마커의 `answer_sha256=<sha256 hex>` 토큰을 지금처럼 검사하고 값은 버린다. 옛 마커는 이미 히스토리·trace·Lane Add-on 기록 같은 스캔 범위 저장소에 있다. 토큰 형식을 디코더에서 지우면 그 마커가 모두 `Invalid_marker` 가 된다. tool blob 스캔은 코덱이 알아본 참조가 깨져 있으면 지우기 전에 멈추므로(`tool_blob_maintenance.mli` 29줄), 옛 기록이 지워질 때까지 스캔이 끝나지 않는다.
- D5. 대시보드 파서는 토큰을 계속 선택 항목으로 읽되, 값을 결과에 담지 않는다. 지금 `answerSha256` 을 읽는 곳은 파서와 그 시험뿐이라 화면은 바뀌지 않는다.

## 4. 다른 방법과 비교

| 방법 | 장점 | 단점 |
|---|---|---|
| **마커에서 빼고 다시 계산 (이 RFC)** | 혼동의 원인이 없어진다. 마커가 약 79바이트 짧아진다. 같은 계산을 두 번 하지 않는다 | 디코더가 옛 토큰을 읽고 버리는 자리가 남는다. 생산자가 지문을 잘못 찍은 경우를 알아채던 비교가 없어진다 |
| 디코더에서도 토큰을 지움(hard cut) | 옛 형식을 읽는 코드가 없다 | 옛 마커가 모두 깨진 마커가 되어 tool blob 스캔이 멈춘다. 히스토리 투영도 바뀐다 |
| 거절 문구만 고침(#49420) | 바로 할 수 있다. 실패한 호출에만 바이트가 붙는다 | 실패는 계속 생긴다. 한 번 실패한 뒤에야 알려 준다 |
| `keeper_artifact_read` 가 지문도 받음 | 모델이 무엇을 넣어도 읽힌다 | 지문 → 매니페스트 색인이라는 새 저장 상태가 필요하다 |
| 도구 설명에 문장을 더함 | 코드 변경이 없다 | 모든 Keeper 의 모든 요청에 바이트가 붙는다 |

"생산자가 지문을 잘못 찍은 경우"는 지금 거절되고 답 대신 blob 주소로 떨어진다. 이 비교가 실제로 무엇을 잡은 기록은 찾지 못했다. 이 RFC 뒤에는 읽을 때의 계산이 유일한 값이라 어긋날 상대가 없다.

## 5. 바뀌는 동작

- 새 마커의 정체성: 지금과 같다. 지금도 선언이 있으면 읽을 때 계산한 값이 정체성이다.
- 옛 마커(선언 있음): 지금과 같다. 토큰 값은 버리고 같은 계산을 한다.
- #42083 전의 옛 마커(선언 없음, 답을 읽는 도구): 지금은 blob 주소가 정체성이다. 이 RFC 뒤에는 답이 정체성이 된다. 영수증만 다른 같은 답이 같은 정체성으로 묶인다. #42083 이 새 마커에서 노린 동작이다.
- 모델 입력: 이미 지난 결과를 마커로 다시 그리는 자리(`Keeper_model_input_demotion` 등)는 새 형식으로 그린다. 그 Keeper 의 다음 요청은 해당 줄에서 캐시가 한 번 어긋난다.
- 바이트: 마커 하나에서 ` answer_sha256=` 15바이트와 hex 64바이트, 합쳐 79바이트가 빠진다. 요청 하나에 마커가 몇 개 실리는지는 재지 않았다.

## 6. 구현 순서

한 PR 로 낸다. 쓰는 쪽과 읽는 쪽을 나누면 그 사이 배포에서 선언 없는 마커를 읽는 쪽이 blob 주소로 떨어진다.

- `tool_output.ml`·`.mli`: D1, D3, D4
- `keeper_tool_answer.ml`·`.mli`: D2
- `tool_projection.ml`·`.mli`, `tool_bridge.ml`·`.mli`: D3
- `keeper_tool_execution_journal_json.ml`: Q1 의 결정대로
- `dashboard/src/lib/tool-blob-marker.ts`: D5
- 시험: 아래 7장

## 7. 검증

- `test_keeper_tool_progress_identity`:
  - "receipt-only change preserves semantic identity" 는 선언 없이도 통과해야 한다.
  - "different blob cannot assert another answer" 는 바꾼다. 선언이 없으니 주장할 수단이 없다. 대신 "다른 blob 의 마커는 그 blob 의 답을 정체성으로 쓴다" 를 본다.
- 디코더: 토큰이 있는 옛 마커와 없는 마커가 같은 `artifact_ref` 로 풀린다. 토큰 값이 sha256 hex 가 아니면 지금처럼 `Invalid_marker` 다.
- 배포 뒤: #49286 의 측정 스크립트로 `artifact does not exist` 실패 중 입력이 답 지문인 것의 수를 다시 잰다. 새 마커만 본 Keeper 에서는 0 이어야 한다.

## 8. 정할 것

- Q1. journal 의 `answer_fingerprint` 필드.
  - (a) 필드를 지운다. 읽는 쪽은 필드가 있는 옛 행도 받아들이고 값을 버린다. 마커 디코더(D4)와 같은 판단이다.
  - (b) hard cut. 읽는 쪽은 필드 없는 모양만 받는다. 배포 때 열린 실행 journal 을 지우고 설치한다. 그때 이어 가던 native 실행은 이어 가지 못한다.
  - 추천은 (a) 다. journal 은 끝나지 않은 실행을 재개할 때 읽는 기록이라, 지우면 재개가 끊긴다.
- Q2. D4 의 토큰 값 검사를 남길지. 남기면 깨진 옛 토큰은 지금처럼 `Invalid_marker` 다. 지우면 아무 글자나 받아들인다. 추천은 남기는 것이다.
