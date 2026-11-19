---
rfc: "0387"
title: "Goal 성공 조건과 완료 검증"
status: Implemented
created: 2026-08-19
updated: 2026-11-18
author: agent-16 + kimi
supersedes: []
superseded_by: null
related: ["0361", "0407", "0489", "a-goal-states-its-measure-as-a-typed-value"]
---

# RFC-0387 — Goal 성공 조건과 완료 검증

## 0. 요약

Goal을 만들 때 완료 판단에 쓸 조건을 선언한다. Verifier는 그 조건의 타당성과
실제 완료 여부를 각각 판정한다. 완료가 증명되면 운영자가 해당 판정을 확인한다.

## 1. 원칙

검증 요청은 모델 호출 전에 기록한다. 판정은 검증한 성공 조건의 revision과
요청에 결속된다. 저장소를 읽을 수 없으면 알려진 판정으로 취급하지 않으며,
복구 사본으로 상태 변경을 승인하지 않는다.

## 2. B1 — 생성 입력

새 Goal은 비어 있지 않은 제목, 타입이 있는 `measure`, 측정 절차인
`procedure`를 요구한다. `measure`는 개수, 수량과 한계, 참·거짓으로
확인할 수 있는 조건을 표현한다. 생성·수정의 구분은 Goal 저장소의
쓰기 잠금 안에서 판정한다. 수정에서 생략한 필드는 기존 값을 쓴다.
측정 입력의 형식은 [Goal 측정 RFC](RFC-a-goal-states-its-measure-as-a-typed-value.md)에 있다.

## 3. B2 — 성공 조건 검토

### 3.1 검토 기록

`Goal_criterion_review`가 성공 조건의 revision별 요청과 판정을 보관한다.
이 기록은 완료 판정을 담는 `Goal_verification`과 별도로 읽는다.

### 3.2 검토 요청

Goal을 저장한 뒤 현재 성공 조건의 revision에 대한 검토를 요청한다. 요청이 저장되면
`Goal_criterion_agent`가 조건의 실재성과 도달 가능성을 비동기로 심사한다.

### 3.3 판정의 쓰임

성공 조건에 대한 판정은 `criterion_review`로 보여 준다. 완료 요청의 접수는
Goal의 현재 phase와 완료 요청 자체의 조건으로 판단한다. 실재성이나 도달
가능성에 대한 판정으로 완료 요청을 막지 않는다.

## 4. B3 — 완료의 증명과 확인

### 4.1 상태 전이

| 요청 또는 판정 | 전이 |
| --- | --- |
| `request_complete` | `Executing → Verifying` |
| Verifier가 완료를 증명 | `Verifying → Awaiting_confirmation` |
| Verifier가 완료를 반증 | `Verifying → Executing` |
| 운영자가 증명을 확인 | `Awaiting_confirmation → Completed` |

Verifier가 처리할 proof 요청을 내구성 있게 저장한 뒤 `Verifying`으로 옮긴다.
반증의 사유와 근거도 완료 원장에 남긴다.

### 4.2 운영자 확인

확인은 현재 성공 조건의 revision, 증명 요청 ID, 검증 실행 ID를 지정한다.
현재 Goal과 증명 원장의 값이 일치할 때 운영자 신원과 확인 시각을 보관한다.

### 4.3 신원 바인딩

`record_proof_proven`과 `record_proof_refuted`는 공개 lifecycle 도구에서
호출할 수 없다. 완료 검증 레인이 자기 실행의 신원으로 판정을 기록한다.
`verification_run_id`는 그 실행의 판정과 관측 기록을 연결한다.

## 5. 완료 요청을 다시 보낼 때

`Verifying`에서 재요청하면 현재 성공 조건과 결속된 기록을 먼저 읽는다.
유효한 대기나 확정 판정을 재사용할 수 있다. 기존 요청을 확인할 수 없거나
다른 성공 조건의 기록만 남았으면 그 상태로 새 요청을 승인하지 않는다.

## 6. 관측

Goal 조회는 조건 검토(`criterion_review`)와 완료 검증(`verification`)을
별도 항목으로 표시한다. 이전 성공 조건의 완료 판정은 현재 조건의 증명으로 쓰지 않는다.

## 구현 요약

- #29152에서 생성 입력 검증과 검증 원장을 도입했다.
- #29221과 #29240에서 완료 요청과 독립 검증 레인을 연결했다.
- #34976에서 검증 뒤 운영자 확인을 추가했다.
- #50341에서 성공 조건 검토를 별도 원장과 비동기 심사로 구현했다.
- #52903에서 생성 입력을 타입이 있는 `measure`와 `procedure`로 바꿨다.
