---
rfc: "0415"
title: 취소 판정의 주인은 운영자의 클릭 하나다 — 시스템 레인은 심사를 거절한다
status: Draft
created: 2026-09-04
author: Edgar A. Poe (edgar.a.poe)
supersedes: []
superseded_by: null
related: ["0407", "0361"]
---

## 0. 한 줄 요약

Completion 심사는 시스템 LLM 레인의 일이지만, Cancel 요청은 일이 존재를 멈추는
허락이므로 그 판정 권한은 운영자의 클릭 하나에만 있다. 이 문서는 그 권한 배분을
도구 서술의 산문에서 **값으로 옮긴다**: 순수 게이트가 계약을 정의하고(§4.1),
런타임이 게이트를 심사 개시 전에 물어보아 거절을 기록한다(§4.1), 운영자 증거
카드는 자기가 답하는 질문을 스스로 이름 짓고(§4.2), 동일한 커밋 경로의 승인
클릭 하나가 `Cancelled` 로 내린다(§4.2). 커밋 깔때기는 취소 청구의 승인에
운영자 서명을 다시 요구해 기각을 값으로 돌려준다(§4.3). 거절은 재시도도
자동 확정도 아니다(§5).

## 1. 문제 — 실측

출처가 없는 문장은 이 문서의 결함이다.

| 무엇 | 어디서 | 창 |
|---|---|---|
| 취소 청원의 권한 산문 | `keeper_task_cancel` 도구 서술 — "판정 권한은 운영자의 클릭" 이 코드 계약이 아니라 문장으로만 존재 | 2026-08 말부터 운용 |
| intent 필드의 부재→도입 | #33046 (main 병합, **미배포**): `AwaitingVerification { intent }` 가 판정기록 결함을 수리 — 판정 경로가 취소와 완료를 구분하게 된 것도 이 변경 | 2026-09-04 기준 main |
| 게이트 부재의 기준선 | `git blame ^6e4c9104` — 본 diff 이전 `lib/` 에 `system_review_allowed` 없음. 시스템 레인은 intent 와 무관하게 `AwaitingVerification` Task 를 처리했다 | clone-probe 작업 나무 |
| 실측 사례 | task-1303 (규칙 이전 취소 청원): cancel 판정 경로 전체가 #33046 배포에 매달려 대기 — 권한 산문이 실제 의사결정을 못 지탱한 증거 | 2026-09-03..04 |

구조적 결함: 시스템 레인이 취소 청원을 completion 과 같은 심사로 흡수할 수
있었고, keeper 의 **자기 취소 요청**을 시스템 LLM 판정으로 세탁하는 길이
값 수준에서 막혀 있지 않았다.

## 2. 왜 지금인가

#33046 이 intent 필드를 주면서 게이트가 쓸 재료가 생겼다. 배포 전에 계약을
코드와 테스트로 못 박지 않으면, 배포 후 시스템 레인의 취소 심사가 새 기능처럼
굳는다 — 산문과 동작이 갈라진 채로.

## 4. 설계

### 4.1 순수 게이트와 그 이

```ocaml
let system_review_allowed = function
  | Masc_domain.Complete_task -> true
  | Masc_domain.Cancel_task -> false
```

- 게이트는 순수 함수다 — 런타임 없이 계약을 테스트할 수 있다.
- 런타임 경로(`process_task_once`)는 심사 개시 **전에** 게이트를 물어본다.
  거절은 `Not_reviewed { gate = "operator_routing" }` 로 기록된다 — 침묵이
  아니다. deferred(재시도)도 아니고 자동 확정도 아니다(§5).
- 세탁 방지: keeper 가 자기 cancel 청원의 거절을 받아도, 그 거절이 시스템
  LLM 판정으로 둔갑할 경로가 없다.

### 4.2 운영자의 원클릭

- 증거 카드(`operator_evidence_json`)는 `intent` 필드로 자기가 답하는 질문을
  이름 짓는다 — completion 인지 cancellation 인지. 그 값은 **Task status** 에서
  읽는다(#33046 와 같은 원천, 한 필드 한 소유자). 카드가 질문을 숨기면 운영자는
  무엇에 클릭하는지 모른 채 클릭한다.
- 승인 커밋은 completion 과 **같은 경로**(`commit_operator_verdict`)를 지나
  `Cancelled` 로 내린다. 권한 주체는 `Human_operator` — 시스템 레인은 사이에
  없다.

### 4.3 커밋 깔때기의 이중 잠금

- 심사 입구의 게이트(§4.1)만으로는 부족하다 — 판정 기록의 최종 수령인은
  커밋 깔때기이고, 거기서 권한을 **다시** 물어본다. `decide_verdict` 는
  intent=Cancel_task 인 청구에 대한 시스템 서명의 `Verdict_approved` 를
  `Verdict_cancel_requires_operator` 로 기각한다. 입구를 우회한 호출이
  있어도 출구가 문을 지킨다.
- 두 직렬화 맵(`workspace_task_transitions.ml`)은 그 기각을
  `Task InvalidState` 로 번역한다 — 도구 표면의 호출자도 같은 문장을 본다.
- §4.2 의 원클릭과 같은 경로에서 권한 주체를 재확인하는 것 — 입구와 출구의
  권한 판정이 갈라질 여지를 형(type)으로 제거한다. 거절된 기각은
  `InvalidState` 이지 세탁도 재시도도 아니다(§5).

## 5. stay_pending

거절을 받은 취소 청원의 Task 는 `AwaitingVerification` 에 머문다 — 그 뒤에서
기다리는 타이머는 없다. 운영자의 클릭이 유일한 출구다. "기다림의 부채"를
시스템이 대신 갚지 않는다.

## 6. 증명

§6.2 = §4.2 원클릭 계약의 증명(증거 카드 intent + 승인 → Cancelled).
§6.3 = §4.1 게이트 계약의 증명(순수 함수 단언). §6.4 = §4.3 깔때기 계약의
증명(시스템 서명 기각 + 운영자 회귀). 이 문서의 테스트 인용 규약이다.

| 무엇을 | 어디서 | 결과 |
|---|---|---|
| §4.1 게이트 계약 | `test_verification.ml` `test_cancel_intent_is_refused_by_system_review` | Complete=true, Cancel=false |
| §4.2 원클릭 폐쇄 | `test_workspace.ml` `test_operator_one_click_cancels_a_cancel_claim` | 카드 intent=cancellation + approve 1클릭 → `Cancelled` 착지 |
| §4.3 깔때기 이중 잠금 | `test_workspace_task_lifecycle.ml` `test_system_approval_of_cancel_claim_is_refused` · `test_operator_approval_still_cancels_a_cancel_claim` | 시스템 서명 × 취소 청구 = `Verdict_cancel_requires_operator`, 운영자 서명 = `Cancelled` (슈트 녹색) |
| 클린룸 전체 | `evidence/cleanroom_rebuild.log` (2026-09-04) | `rm -rf _build` 후 `-j1` 재건: test_verification 60검사·test_workspace 86검사, 직접 exe·별칭 양 경로 전부 녹색 |

교훈 각주: 이 증명 chain 의 첫 판독에서 별칭 경로 EXIT=1 이 "테스트 실패"로
보였으나 실은 dune 증분 장부 부패였다(재시작·SIGKILL 의 산물). EXIT 해석 전
클린 리빌드가 변별 증거다 — `evidence/README.md` 참조.

## 7. 거절한 대안

- **시스템 LLM이 취소도 심사하고 운영자에게 권고만**: 권한의 주인이
  뒤바뀐다. keeper 의 자기 취소 요청을 시스템이 승인하는 길이 열린다(세탁).
- **타이머로 자동 취소**: 침묵이 판정이 된다. 기다림의 부채는 부채로 남고,
  진짜 원인(운영자 주의)은 지불되지 않은 채 소멸 시킨다.
- **게이트를 도구 서술 산문에만 유지**: 현 상태다. 계약은 문서가 아니라
  코드에 있어야 테스트가 지킨다.

## 8. 관계

- #33046 — intent 필드(미배포). 이 RFC 의 전제이며 배포 후 §6 테스트가
  그 위에서 도는 첫 계약이 된다.
- RFC-0407 — 판정자는 스냅샷을 읽는다. 이 문서는 그 판정자의 **권한 경계**를
  긋는다.
- RFC-0361 D7(b) — 고정 신원 원칙. 권한 주체의 명시적 기록은 그 계열이다.
- task-1306 — 이 게이트·원클릭·테스트를 실은 작업 나무.

관련: #33046, task-1306, task-1303(사례), RFC-0407, RFC-0361.
