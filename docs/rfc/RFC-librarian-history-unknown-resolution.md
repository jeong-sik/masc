---
title: "결과를 찾을 수 없는 Librarian 원본의 적용을 막고 새 판정을 잇는다"
status: Draft
created: 2026-11-10
related: ["0500", "librarian-history-settles-finished-originals"]
---

# 결과를 찾을 수 없는 Librarian 원본 복구

이슈: #50828. 이 초안은 history resolution의 소스 구현 계약을 정리한다. 구현·시험 실행·배포·실제 운영 복구는 별도 증거다. 이 문서만으로 어느 서버에 배포됐거나 원본을 처리했다고 주장하지 않는다.

## 문제

Librarian이 전송 의도를 보존한 뒤 원래 worker 요청과 host 결과를 찾지 못하면 `missing_after_dispatch`로 남는다. 원래 요청이 실행되지 않았다는 뜻은 아니다. 기존 catch-up은 원 결과를 다시 관측하며, 일치하는 host proof가 있으면 terminal publication을 복원한다. 결과 증거까지 없으면 이 경로는 새 호출을 허가하지 않는다.

RFC-0500은 host가 `interrupted`라고 판정한 원본을 다룬다. 이 문서는 그런 종단 판정조차 없는 원본을 다룬다. 시간이나 재시도 횟수는 이 차이를 없애지 못한다.

## 운영자가 허가하는 동작

정확한 history 원본 하나의 향후 Memory 적용을 막고, 같은 미반영 source 범위를 현재 Memory로 새로 판단한다. 원래 RPC를 다시 보내지 않는다. 원문, 원본의 불명확한 실행 증거, 기존 Memory, atom·official·external cursor는 이 결정으로 삭제하거나 전진시키지 않는다.

별도의 history resolution 기록에 물리 owner, scope, 원 요청 ID와 digest, 원본 기록의 불변 사본 또는 보존된 동등 증거, actor와 사유를 남긴다. 관측과 적용 요청은 workspace와 원본, 현재 Memory·cursor의 관측에 결속한다. 현재 상태가 달라졌으면 운영자 요청을 새 상태로 바꾸어 재시도하지 않고 거절한다.

원본이 이후 worker 결과를 돌려주더라도 이 적용 차단은 유지된다. 현재 owner progress가 바뀌었다는 이유로 기록을 없는 것으로 취급하지 않는다. 원래 결과가 실패했다거나 실행되지 않았다고 기록하지 않는다.

현재 구현의 대상은 `Dispatch_pending(Some(Absent _))`인 원본이다. Gate 준비·replacement가 없고, host Exact record와 완료 proof가 없으며, 범위 receipt와 owner·Memory·cursor 관측을 확인할 수 있어야 한다. host 실행이 open 또는 terminal로 남았으면 먼저 그 결과를 재관측한다. `outcome_unknown`이나 손상된 증거를 absence로 바꾸지 않는다.

## 적용과의 경쟁

차단 publication과 실제 Memory publication은 같은 source 잠금 및 Memory 잠금 경계를 사용한다. Memory 잠금 안에서 owner·epoch를 다시 확인한다. Store의 기존 scope 잠금 안에서 원본 비교와 resolution publication을 묶는다. 잠금을 유지하지 않는 이전 anchor만으로 변경을 승인하지 않는다.

원래 Memory 적용이 먼저 확인됐다면 차단 요청을 거절한다. 적용 차단이 먼저 확인됐다면 늦은 답은 Memory를 바꾸지 못한다. 실제·부분 range receipt, 읽을 수 없는 기록, 변경된 owner, Gate나 commit 진행 등 판단할 수 없는 상태는 계속 막는다.

차단 저장이 불확실하거나 읽히지 않으면 새 판정을 허가하지 않는다. 저장 오류가 무쓰기를 증명하지 않으므로 같은 쓰기를 자동 반복하지 않는다. 정확한 원본의 resolution을 다시 읽어 확인한다.

## 새 판정

원래 포착한 미반영 범위는 보존한다. 그 범위를 현재 Memory 기준으로 준비해 새 ID의 요청으로 만든다. 그 뒤에 쌓인 다른 unread 범위는 다음 일반 pass가 읽는다.

원본의 atom 범위는 trace·history 시작 경계·시작과 끝 atom으로, official 범위는 시작 경계·선택한 turn 집합으로 결속한다. HTTP는 이 중 안전한 범위 요약만 공개한다. health의 현재 gap·unread 범위는 이 원본의 선택 범위를 대신하지 않으며 폐기나 cursor 전진의 근거가 아니다.

새 ID와 전체 준비 내용 또는 이를 복원할 불변 본문의 digest를 intent로 먼저 보존한다. 같은 child와 본문을 확인하고 연결을 ACK한 뒤에만 실행할 수 있다. 재시작은 같은 intent와 ID를 복원하며 새 ID를 계속 만들지 않는다. body·child·intent가 다르거나 일부 publication이 불확실하면 멈춘다.

옛 원본은 unresolved evidence로 남긴다. 본문을 제거하는 settle/archive나 입력의 ACK·cursor를 전진시키는 `settle_refused`에 넣지 않는다. 새 판정의 실제 Memory receipt를 확인한 뒤 기존 consumer가 입력을 ACK하고 cursor를 전진시킨다.

내구 intent의 단계는 `requested` → `fenced` → `child_intended` → `child_confirmed`다. 직렬 lane은 일반 history 처리보다 먼저 이 intent를 진행한다. 관측 변경이나 더 이상 적격이 아닌 원본은 `refused`로 남긴다. `child_confirmed`는 같은 child의 저장·연결 확인이며 Memory 완료가 아니다. 실제 child의 commit receipt를 직렬 lane에서 확인해 저장한 별도 `memory_commit`이 있어야 완료 관측을 공개한다. GET은 이 저장된 증거를 읽으며 receipt 복구나 epoch 초기화를 수행하지 않는다.

## API와 관측

GET과 POST는 모두 bearer의 `CanAdmin`을 요구한다.

```text
/api/v1/keepers/<keeper>/memory-history-originals/<request-id>/resolution
```

원본 ID는 canonical JSON 문자열 전체를 한 경로 구간으로 percent-encode 한 번만 한다. 서버는 구간을 나눈 뒤 한 번 decode한다. JSON 재포맷이나 이중 인코딩으로 다른 ID를 만들지 않는다.

POST schema는 `keeper.memory.history_original_resolution.request.v1`이며 필드는 정확히 `schema`, `expected_workspace`, `expected`, `reason`이다. workspace에는 실제 canonical `base_path`와 `masc_root`가 필수다. `expected`는 다음 네 필드의 strict guard다.

| 필드 | 계약 |
|---|---|
| `owner_record_sha256` | 관측한 원본 owner 기록의 SHA256 |
| `memory_revision` | 현재 Memory revision 또는 null |
| `memory_sha256` | 현재 Memory의 SHA256 또는 null; revision과 함께 존재하거나 함께 null |
| `cursors_sha256` | atom·official·external cursor 관측의 SHA256 |

운영자는 fresh GET의 `preview.expected` 전체를 보낸다. 원본이 과거 포착한 revision이나 health gap을 guard로 대신하지 않는다. 중복·누락·추가 필드는 거절하며 body의 actor·Keeper·request ID도 허용하지 않는다. actor는 인증된 서버 값, 대상은 경로 값이다. 잘못된 workspace는 내구 접수 전에 거절한다.

GET과 내구 접수 후 POST의 응답 schema는 `keeper.memory.history_original_resolution.v1`이다. GET은 `preview`, 공개 `intents`, 안전한 `fence`, `original_range`, `completion`을 제공한다. preview는 `eligible`일 때만 현재 expected를 제공한다. `already_fenced`이면 eligible=false와 기존 fence를 보이며 이를 새 guard로 가장하지 않는다. 원본 부재·관측 변경·이미 기록된 범위는 각각 typed 부적격이며, 읽기 불가·publication 미확인은 eligible=null이다. 원본·child 본문, 물리 경로, preimage는 공개하지 않는다.

HTTP는 `Work.submit`으로 intent만 내구 접수한다. 그 뒤 Librarian enabled/initialized 조건을 확인하고 `Queue_refresh.submit_durable`로 기존 직렬 lane을 예약한다. HTTP가 직접 fence나 Memory 실행을 호출하지 않는다. 예약 실패에도 `durable_acceptance=recorded`와 intent를 응답에 남긴다. `scheduling.kind=submitted|coalesced`는 202, disabled/invalid는 409, executor 미초기화·`ran_inline`·`dropped`·예약 실패는 503이다. POST의 completion은 항상 `not_observed`다.

접수가 불확실하면 503과 `durable_acceptance=unconfirmed`를 반환한다. 이를 무쓰기로 해석해 자동 재요청하지 않고 정확한 원본 GET의 intent·fence를 확인한다. GET은 작업 예약이나 복구 publication을 하지 않는다. 이후 `completion.kind=memory_committed`는 저장된 실제 Memory receipt의 관측이고, `not_observed`·`unavailable`은 완료가 아니다. 접수, 예약, fence, child 확인, worker 응답, 주의 행의 부재를 완료로 대신하지 않는다.

요청 예시와 운영 순서는 [Keeper 메모리 복구 안내](../guides/KEEPER-MEMORY-RECOVERY.md)를 따른다. 이 API의 배포·운영 실행은 별도로 확인해야 한다.

## 검증 범위

검증 대상은 실제 저장소에서 차단이 먼저인 경쟁과 Memory 적용이 먼저인 경쟁, 불확실한 publication, 늦은 답과 재시작의 동일 child 복원이다. 외부 source와 cursor가 바뀐 경우, 잘못된 workspace·원본·권한도 거절해야 한다. 분기표나 UI 문구를 그대로 반복하는 테스트는 추가하지 않는다. 이 절은 필요한 검증 범위이며 시험 실행 성공·배포·운영 복구 완료의 보고가 아니다.

## 구현 단위

1. history 전용 resolution 기록, 비교·저장 경계, 실제 원본 적용 지점의 차단 검사.
2. durable intent, 기존 직렬 lane의 차단·exact-range child 연결, 저장된 Memory 완료 관측.
3. strict authenticated HTTP 진입점과 운영 안내. 읽기는 공개 필드만 투영하고, 쓰기는 내구 접수와 lane 예약을 분리한다.

전역 request-progress FSM, worker volume, 모델 배정, 사용자 UI 설정은 이 복구를 위해 바꾸지 않는다.
