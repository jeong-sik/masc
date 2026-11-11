# Goal 성공 기준 검토

Goal을 만들거나 성공 기준을 바꾸면 별도 Verifier가 그 기준의 실재성과 도달
가능성을 검토한다. 현재 목표치를 달성했는지는 묻지 않는다. 이 구현은
[constitution.xml의 B2](../constitution.xml)를 연결하며, 완료 증명과 사람의
최종 확인(B3)은 기존 절차를 따른다.

## 사용 흐름

`masc_goal_upsert`는 Goal을 먼저 저장한 뒤 해당 성공 기준 revision의 검토를
요청한다. 호출은 모델의 응답을 기다리지 않는다. 저장과 요청 사이에 중단되면
서버가 다음 백그라운드 순회에서 누락된 요청을 복구한다. 검토 저장소를 읽지 못한 경우는
Goal 생성 실패나 기준 부적합으로 바꾸지 않고 `unavailable`로 표시한다.

서버 시작 시 검토 레인을 설치하고 요청을 깨운다. 레인은 기존 Task 판정과
같은 review slot을 사용한다. Goal이 Paused, Blocked 또는 종단 단계에 있으면
새 모델 호출을 시작하지 않는다. 실제 reviewer가 관측한 판정은 원본과 함께
저장한 뒤 현재 성공 기준과 대조하여 반영한다.

검토 결과는 `masc_goal_upsert`, `masc_goal_list`, Dashboard Goal 트리·상세,
TUI Planning 상세의 `criterion_review`로 읽는다.

`masc_goal_list`의 전체 행(`detailed=true` 또는 `goal_id`로 읽은 행)의
`criterion_review`는 `state`, `request_id`,
`criterion_revision`, `reason`, `detail`, `authority`만 담는다. reviewer의
구조화된 결과(`review`)와 도구 관측(`tools`)은 원장에 남고, 전체 투영
(`Goal_criterion_review.projector`)에만 실린다.

| 상태 | 의미 |
|---|---|
| `unchecked` | 현재 성공 기준의 검토 요청이 아직 기록되지 않음 |
| `pending` | 요청을 기록했고 검토 준비 또는 실행을 기다림 |
| `execution_pending` | 호출 의도를 저장했고 원래 실행의 응답을 기다림 |
| `execution_unknown` | 실행 결과를 확정할 수 없어 원본을 보존함 |
| `judgment_pending` | 실제 응답을 저장했고 현재 기준에 반영하기를 기다림 |
| `viable` | 구체적인 이유와 함께 실재하며 도달 가능한 기준으로 판정함 |
| `needs_revision` | 실제 판정 이유에 따라 기준을 보완해야 함 |
| `deferred` | 판정 가능한 응답을 얻지 못함 |
| `superseded` | 응답의 기준 revision이 현재 기준과 달라 현재 판정으로 쓰지 않음 |
| `unavailable` | 권위 있는 검토 기록을 읽을 수 없음 |

이 상태는 Goal phase와 별개다. `viable`은 완료 증명이 아니며,
`needs_revision`은 Goal을 자동 취소하거나 Task 실행을 차단하지 않는다.
기준이 바뀌면 이전 판정을 새 기준으로 가져오지 않는다.

## 원본과 재시도

`Goal_criterion_review`가 `goal_criterion_reviews.json`의 요청 이력을 소유한다.
요청에는 Goal id, request id, 전체 성공 기준과 revision, actor, 시각, 이전
요청 연결이 들어간다. 호출 전 prompt·system prompt·조회 도구 binding을
저장하고, 응답 후 실제 구조화된 판정과 도구 관측을 저장한다. 원본과 현재
기준을 대조한 CAS가 성공해야 판정이 현재 관측으로 보인다.

일반 텍스트, 이유가 빈 응답, provider 부재를 기준 부적합 판정으로 바꾸지
않는다. 확정된 비판정 응답은 명시적인 upsert나 저장된 provider 재시도 조건에
따라 새 요청으로 이어질 수 있다. 이전 요청은 지우지 않는다. 실행 결과가
불명확한 요청은 자동 재실행하지 않는다.

답변을 이미 관측했는데 원장 쓰기만 실패하면 프로세스의 보관함에 같은 답변을
남긴다. 다음 백그라운드 순회는 모델 호출 없이 그 답변의 저장과 반영을 다시
시도한다. 저장 전에 프로세스까지 잃으면 보관함은 복구할 수 없다. 새 서버는
남아 있는 호출 의도를 `execution_unknown`으로 남기며 이를 재실행하지 않는다.

검토 도구는 기존 Goal proof의 읽기 전용 조회 표면을 사용한다. 입력 문서의
지시를 권위로 삼지 않으며 Goal이나 자료를 수정하지 않는다. 실행 엔진은
`Task.Anti_rationalization.run_retained`이고 prompt는
[`config/prompts/goal_criterion_review.md`](../../config/prompts/goal_criterion_review.md)다.

## 검증 경계

저장·CAS·실제 reviewer hook fixture, API·Dashboard 수신, TUI decoder는 각각
다른 증거다. fixture의 판정은 실 provider의 응답이나 배포된 서버의 동작을
증명하지 않는다. PR의 검증 내역에서 실행한 범위를 구분한다.
