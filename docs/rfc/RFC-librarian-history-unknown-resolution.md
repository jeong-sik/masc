---
title: "결과를 찾을 수 없는 Librarian 원본의 적용을 막고 새 판정을 잇는다"
status: Draft
created: 2026-11-10
related: ["0500", "librarian-history-settles-finished-originals"]
---

# 결과를 찾을 수 없는 Librarian 원본 복구

이슈: #50828. 이 문서는 구현할 계약의 초안이다. 실제 원본의 결과를 폐기하거나 서버에서 복구를 수행한 기록이 아니다.

## 문제

Librarian이 전송 의도를 보존한 뒤 원래 worker 요청과 host 결과를 찾지 못하면 `missing_after_dispatch`로 남는다. 원래 요청이 실행되지 않았다는 뜻은 아니다. 기존 catch-up은 원 결과를 다시 관측하며, 일치하는 host proof가 있으면 terminal publication을 복원한다. 결과 증거까지 없으면 이 경로는 새 호출을 허가하지 않는다.

RFC-0500은 host가 `interrupted`라고 판정한 원본을 다룬다. 이 문서는 그런 종단 판정조차 없는 원본을 다룬다. 시간이나 재시도 횟수는 이 차이를 없애지 못한다.

## 운영자가 허가하는 동작

정확한 history 원본 하나의 향후 Memory 적용을 막고, 같은 미반영 source 범위를 현재 Memory로 새로 판단한다. 원래 RPC를 다시 보내지 않는다. 원문, 원본의 불명확한 실행 증거, 기존 Memory, atom·official·external cursor는 이 결정으로 삭제하거나 전진시키지 않는다.

별도의 history resolution 기록에 물리 owner, scope, 원 요청 ID와 digest, 원본 기록의 불변 사본 또는 보존된 동등 증거, actor와 사유를 남긴다. 관측과 적용 요청은 workspace와 원본, 현재 Memory·cursor의 관측에 결속한다. 현재 상태가 달라졌으면 운영자 요청을 새 상태로 바꾸어 재시도하지 않고 거절한다.

원본이 이후 worker 결과를 돌려주더라도 이 적용 차단은 유지된다. 현재 owner progress가 바뀌었다는 이유로 기록을 없는 것으로 취급하지 않는다. 원래 결과가 실패했다거나 실행되지 않았다고 기록하지 않는다.

## 적용과의 경쟁

차단 publication과 실제 Memory publication은 같은 source 잠금 및 Memory 잠금 경계를 사용한다. Memory 잠금 안에서 owner·epoch를 다시 확인한다. Store의 기존 scope 잠금 안에서 원본 비교와 resolution publication을 묶는다. 잠금을 유지하지 않는 이전 anchor만으로 변경을 승인하지 않는다.

원래 Memory 적용이 먼저 확인됐다면 차단 요청을 거절한다. 적용 차단이 먼저 확인됐다면 늦은 답은 Memory를 바꾸지 못한다. 실제·부분 range receipt, 불독가한 기록, 변경된 owner, Gate나 commit 진행 등 판단할 수 없는 상태는 계속 막는다.

차단 저장이 불확실하거나 읽히지 않으면 새 판정을 허가하지 않는다. 저장 오류가 무쓰기를 증명하지 않으므로 같은 쓰기를 자동 반복하지 않는다. 정확한 원본의 resolution을 다시 읽어 확인한다.

## 새 판정

원래 포착한 미반영 범위는 보존한다. 그 범위를 현재 Memory 기준으로 준비해 새 ID의 요청으로 만든다. 그 뒤에 쌓인 다른 unread 범위는 다음 일반 pass가 읽는다.

새 ID와 전체 준비 내용 또는 이를 복원할 불변 본문의 digest를 intent로 먼저 보존한다. 같은 child와 본문을 확인하고 연결을 ACK한 뒤에만 실행할 수 있다. 재시작은 같은 intent와 ID를 복원하며 새 ID를 계속 만들지 않는다. body·child·intent가 다르거나 일부 publication이 불확실하면 멈춘다.

옛 원본은 unresolved evidence로 남긴다. 본문을 제거하는 settle/archive나 입력의 ACK·cursor를 전진시키는 `settle_refused`에 넣지 않는다. 새 판정의 실제 Memory receipt를 확인한 뒤 기존 consumer가 입력을 ACK하고 cursor를 전진시킨다.

## API와 관측

기존 CanAdmin·expected workspace 계약을 따른다. GET은 정확한 원본의 관측과 적용 조건을 돌려준다. 순수 관측에 복구 publication을 섞지 않는다. POST는 관측한 expected 값을 확인하고 actor·사유를 기록한다.

적용 차단 저장, 후속 intent/child의 확인, worker 예약, Memory 반영은 별개 결과다. `submitted`, `applied`, worker의 응답, 주의 행의 부재 중 하나만으로 메모리 복구 완료를 주장하지 않는다. API 필드와 endpoint는 공개 `.mli` 및 strict codec이 고정된 뒤 문서화한다.

## 검증 범위

실제 저장소에서 차단이 먼저인 경쟁과 Memory 적용이 먼저인 경쟁, 불확실한 차단 publication, 늦은 답과 재시작의 동일 child 복원을 확인한다. 외부 source와 cursor가 바뀐 경우, 잘못된 workspace·원본·권한도 거절한다. 분기표나 UI 문구를 그대로 반복하는 테스트는 추가하지 않는다.

## 구현 단위

1. history 전용 resolution 기록, 비교·저장 경계, 실제 원본 적용 지점의 차단 검사.
2. 보존된 정확한 source 범위의 새 판정 intent/child 연결, authenticated HTTP 진입점과 운영 안내.

전역 request-progress FSM, worker volume, 모델 배정, 사용자 UI 설정은 이 복구를 위해 바꾸지 않는다.
