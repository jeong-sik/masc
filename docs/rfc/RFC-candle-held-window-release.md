---
rfc: "candle-held-window-release"
title: "보류된 Candle 지급 창을 운영자 근거로 풀거나 닫는다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: sangsu
related: ["goal-candle-ledger"]
---

# RFC: 보류된 Candle 지급 창을 운영자 근거로 풀거나 닫는다

이슈 #49172 와 task-3288 을 다룬다. 보류(`candidate_window_held`)에 들어간 지급에는 나오는 길이 없다.

## 1. 관찰한 현재 동작

모두 `origin/main` e1001bccf3 에서 직접 읽은 것이다.

- 쓰는 곳: `lib/candle_runtime/candle_candidates.ml` 의 `write_candidates`. 후보 창 관측에 `Same_second` 또는 `Reversed_window` 가 있으면 `Candidate_window_held` 를 쓴다. 이 두 가지는 Task 완료와 Goal 생성·확정의 선후를 시각으로 정할 수 없다는 뜻이다. 감정(appraiser) 결과 모름과는 다른 경로다.
- 한 번 쓰이면 `prepare` 는 `Held_window` 만 돌려준다.
- `lib/candle/candle_payout.ml` 의 `validate_settlement_under` 는 보류가 있으면 `Paid`·`Unattributed`·`Payout_failed` 를 모두 거절한다. `validate_under` 는 `Payout_owed`·`Candidates`·`Candidates_fenced` 도 거절한다.
- 보류를 닫는 이벤트는 없다. goal-candle-ledger RFC 도 이를 한계로 적었다("보류를 해제하거나 운영자 근거를 받아 재판정하는 명령과 화면이 없다").

따라서 보류된 지급은 원장 규칙상 영구히 열린 채 남는다. 이슈 본문의 재현 3단계(감정 결과 모름 → 보류)는 위 코드와 다르다. a46df693 의 보류 행(`tasks`)을 읽어 실제 원인을 확인해야 한다. 이 문서를 쓰는 레인은 원장 파일을 읽지 못했으므로 **미확인**이다.

## 2. 단순 재시도는 답이 아니다

보류의 원인은 이미 기록된 Task 완료 시각이다. 시각은 바뀌지 않으므로 보류를 풀고 다시 관측하면 같은 이유로 다시 보류된다. 풀려면 시각이 못 정한 선후를 누군가 정해 줘야 한다.

## 3. 제안

새 원장 이벤트 `candidate_window_resolved` 를 더한다.

| 필드 | 뜻 |
| --- | --- |
| `goal_id`, `request_id`, `verification_run_id` | 열린 지급 의무와 같아야 한다 |
| `held_at` | 닫는 보류 행의 시각. 다른 보류를 닫지 못하게 한다 |
| `resolution` | 아래 둘 중 하나 |
| `operator` | 서버가 확인한 관리자 신원 |
| `reason` | 비어 있지 않은 근거 문장 |

`resolution`:

- `Close_unattributed`: 선후를 정하지 못한 채 지급 없이 닫는다. 기존 `Unattributed` 와 같은 효과로 읽는다. 가장 보수적이다.
- `Order_ruled`: 운영자가 Task 별로 "확정 전 완료 / 확정 후 완료"를 정한다. 그 정한 값으로 `Candidates` 를 만든다.

검증 규칙:

- `validate_under` 는 열린 의무에 맞는 보류가 있을 때만 이 이벤트를 받는다.
- 이벤트가 쓰이면 `held_window_of` 는 `None` 을 돌려준다. 이후 흐름은 `Close_unattributed` 면 `Unattributed`, `Order_ruled` 면 후보 기록으로 이어진다.
- 이전 reader 는 이 행을 해석하지 못한다. goal-candle-ledger RFC 의 형식 변경 규칙(모든 writer 정지 후 reader/writer 동시 갱신)을 따른다.

진입점은 관리자 전용 명령 하나다. 모델 호출이나 지급 재시도를 하지 않는다.

## 4. 결정이 필요한 것

- `Order_ruled` 를 처음부터 넣을지, `Close_unattributed` 만 먼저 넣을지. 후자는 구현이 작고 틀릴 여지가 적다. 다만 이미 일한 Keeper 가 받을 몫을 영구히 포기한다.
- 이 결정과 Candle 지급 정책(task-3289)의 관계는 운영자가 정한다.

## 5. 검증 계획

- 단위: 맞는 보류에만 이벤트가 받아들여지고, 다른 Goal·다른 `held_at` 은 거절된다.
- 단위: 해소 뒤 `held_window_of` 가 `None` 이고 `Unattributed` 로 닫을 수 있다.
- 단위: 해소 이벤트가 없는 기존 원장 행의 재생이 달라지지 않는다.
- 운영: a46df693 이 `Paid` 또는 `Unattributed` 로 끝난 원장 줄을 #49172 에 남긴다. 이 항목은 구현 병합과 운영자 실행이 모두 끝나야 채워진다.
