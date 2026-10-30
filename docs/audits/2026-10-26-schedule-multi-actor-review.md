# 예약 Job: 다중 모델·다중 사용자 적대적 리뷰

대상 PR: [#46092](https://github.com/jeong-sik/masc/pull/46092).
리뷰 시작 head `1f94a288afdfb890f3a4f1e15a031c44261b9c5d`, API base
`8e2abe4fa6684462abbea32758e936075c63de9f`, REST stack `null`.
전체 diff 식별자 `77c651f34f6d105b49c8862bc904e2e946fb045b99e119e10911830b81e267fb`.
수정 전 head에 대한 판정은 **FAIL: 새 P2 하나**였다. 아래 수리는 그 판정을 이월하지 않고
재검토한다. [전체 행동 감사](2026-10-26-scheduled-job-behavior-audit.md)의 제품 전체 non-PASS는 유지한다.

## 검토 주체와 한계

- 주 작업 세션: 생산 소스와 producer 의미를 직접 확인하고 발견된 표시 오류를 수정했다.
- `schedule_adversarial`: 독립 세션, 백엔드 권한·동시 수정·실패 정산 경로를 검토했다.
- `schedule_multimodel_review`: `fork_turns=none`, 요청 모델 `gpt-6-astra`, reasoning `high`로
  별도 생성했다. 전체 19개 변경 파일과 문맥을 읽고 아래 P2를 발견했다.
  모델 선택은 orchestration 요청 메타데이터이며 별도의 provider 응답 attestation은 없다.

서로 다른 리뷰 주체를 사용한 것은 실제 여러 provider로 예약을 실행했다는 뜻이 아니다.
다중 모델 runtime/failover, 실제 두 사용자 동시 도구 호출, 설치된 TUI 실행은 이번에도 미확인이다.
독립 리뷰어들은 테스트를 다시 실행하지 않았고 소스를 검토했다.
공유 workspace의 operator/creator/recipient 권한은 사용자별 private tenant 격리와 별개다.

## 새로 발견해 수정한 P2: 취소 후 잔류를 취소 완료로 표시

1. 반복 예약은 A를 대상으로 생성되지만 실제 회차가 B에게 인계된다.
2. operator가 정의를 취소한다. 현재 cancellation withdrawal은 A만 검색한다.
3. B에는 pending occurrence가 남을 수 있다.
4. [dashboard producer](../../lib/server/server_dashboard_schedule_projection.ml)는
   `Pending_at (owner, source)`이며 정의가 Cancelled이면 `retained_terminal_wake`를 반환한다.
5. 새 decoder는 이를 `Cancelled`로 잘못 바꾸었다. attention이 false가 되고
   채팅의 최신 종단 결과 선택에서 다른 결과 뒤로 사라질 수 있었다.

백엔드 취소 전파의 한계와 별개로, pending 증거를 종단 완료로 만드는 것은 이번 PR이 만든 오류다.
수리는 `retained_terminal_wake`에 기존 `matched_pending` 해석을 적용한다.
동일 owner의 미소비는 Queued, 인계 후 다른 owner는 Queued_at, 충돌은 Unknown으로 유지한다.
`withdrawn_at_cancel`만 별도로 취소 상태가 된다. 새 상태나 별도 큐를 만들지 않았다.

검증: 새 컴포넌트 시나리오에서 수정 전 **1/12 FAIL**, 수정 후 **12/12 PASS**.
같은 owner 잔류, 인계 owner + 원 owner ACK, attention 유지 결정을 확인했다.
이는 actual producer branch와 일치하는 decoder 입력 검사이며 전체 백엔드 실행을 흉내 낸 증거가 아니다.
[실패 로그](../evidence/2026-10-26-schedule-behavior-audit/retained-before.log),
[수정 후 로그·입력 해시](../evidence/2026-10-26-schedule-behavior-audit/README.md).

## 백엔드에서 추가로 확인한 소스 반례

다음은 이번 PR의 변경이 아니며 전체 runtime으로 재현하지 않았다.
이 경로들이 남아 있는 상태에서 예약 기능을 다중 사용에 대해 무오류라고 승인할 수 없다.

### F3 — 권한 확인과 실제 변경 사이 target 변경: P2 후보

[tool_schedule](../../lib/tool_schedule.ml)의 `authorize_row_change`는 lock 밖에서 행을 읽는다.
`handle_cancel`은 그 결과를 버리고 schedule_id와 actor만
[Schedule_service](../../lib/schedule/schedule_service.ml)에 전달한다.
[store cancel_request](../../lib/schedule/schedule_store.ml)는 lock 안에서 현재 행을 다시 읽지만
현재 owner에 대해 caller를 재인가하거나 expected instance를 대조하지 않는다.

반례: A가 recipient여서 cancel 권한을 확인함 → operator가 target을 B로 갱신함 →
A의 지연된 cancel이 B의 새 정의를 취소함. A는 commit 당시 creator/recipient가 아니어도 변경할 수 있다.
update 역시 lock 전 stored snapshot을 근거로 권한과 보존 필드를 결정하므로 유사한 stale write가 가능하다.
순차 소유권 거절 테스트는 이 사이의 retarget을 검사하지 않는다.
수리는 실제 행에 대한 재인가나 instance/version 조건을 변경 lock 안에서 판정하는 방향이어야 한다.

### F4 — due만 수정한 호출이 다른 호출의 새 recurrence를 덮을 수 있음: P2 후보

[update schema](../../config/tools/masc_schedule_update.toml)는 recurrence_kind 생략 시 stored recurrence를
유지한다고 설명한다. 그러나 tool handler는 이를 lock 전 stored snapshot에서 복사한다.
due 입력이 있으면 Replace_timing이고, store는 현재 recurrence를 다시 보존하지 않는다.

반례: U1이 interval 정의를 읽고 due_in_sec만 수정 준비 → U2가 Daily로 변경해 저장 →
U1 저장으로 Daily가 이전 interval로 되돌아감. 호출자가 recurrence를 보내지 않았어도 발생할 수 있다.
기존 concurrent content-edit 검사는 Keep_timing이므로 이 조합을 덮지 않는다.
수리 시 omitted recurrence와 명시적 recurrence 변경을 store에 구분해 전달하거나 stale revision을 거절해야 한다.

### F5 — dispatch 실패 정산 write 실패 뒤 Running이 남을 수 있음: P2 후보

[schedule_runner](../../lib/schedule/schedule_runner.ml)의 `finish_retryable_dispatch`는
`retry_running` 저장 실패를 결과 문자열에 기록하지만 이전 Running을 후속 tick에서 재정산할
상태를 유지하지 않는다. `finish_failed_dispatch`의 정산 저장 실패도 같은 위험이 있다.
일반 tick은 Due만 선택하며 전역 Running 복원은 startup에서만 수행한다.

반례: 정상 start로 Running 저장 → consumer의 retryable failure → Due 복귀 write만 실패 →
저장소 정상화 후 같은 process에서 tick을 계속해도 해당 Running은 후보가 아님.
F2의 최초 startup recovery 실패와 진입 지점은 다르다. 실제 재현은 양쪽 모두 별도로 필요하다.
복구를 위해 무조건 전역 Running→Due를 반복하면 현재 실행의 lease를 훔칠 수 있다.

## 정상·오류·경합 시나리오 대조

| 행동 | 기대 | 이번 근거 / 남은 한계 |
|---|---|---|
| 단발 접수 → 대기 → 시작 → 끝 → ACK → 종단 | 각 단계 구분, 접수를 완료로 승격하지 않음 | actual decoder 검사; 실제 모델 실행 아님 |
| 같은 Keeper에서 다른 모델의 다른 입력 처리 | 다른 stimulus/instance가 이 회차를 완료시키지 않음 | exact identity 검사와 source review |
| 원 모델 실패 후 다른 provider로 재개 | durable 입력 유지, 실제 효과 중복 여부 확인 | queue/batch disposition 소스 확인; provider failover 실측 없음 |
| 서로 다른 Keeper의 요청을 함께 조회 | target/instance별 분리 | source-extracted 선택 및 decoder 격리 검사 |
| A→B 인계 후 A ACK | B pending으로 유지 | decoder + 과거 실제 producer 행 재생 |
| 인계 후 정의 취소, B pending | pending을 취소 완료로 만들지 않음 | 새 실패/수정 검사; backend 전파 수리는 별개 |
| queue 없음 + dispatch-only ledger | Missing, 대기/완료로 만들지 않음 | decoder 실행 |
| 상반된 terminal 증거 | Unknown | decoder 실행 |
| 권한 없는 다른 caller의 순차 변경 | 거절 | 기존 테스트 소스 확인, 이번 실행 없음 |
| 권한 확인 사이 operator retarget | 이전 owner 변경 거절 | F3 소스 반례, 실제 동시 재현 미실행 |
| 두 호출의 retime/recurrence 변경 | 생략된 recurrence가 경쟁 호출의 새 값을 보존 | F4 소스 반례, 실제 동시 재현 미실행 |
| 일시 저장 실패 후 정상화 | Running 정산을 계속함 | F2/F5 소스 반례, 실제 fault injection 미실행 |
| Keeper/workspace 변경 중 늦은 조회 도착 | 현재 scope에 다른 결과를 적용하지 않음 | 기존 generation/workspace admission 소스 확인; 전체 TUI 미실행 |
| 결과 채널 전달 | 모델이 도구를 호출한 효과를 목적지에서 확인 | 실행하지 않음; occurrence 완료만으로 보장 불가 |

이번 수리 후 component 실행은 domain 28, observation 12, historical producer replay 14,
selection 결정 8이다. 이들을 합산해 전체 사용자 흐름을 실행했다고 세지 않는다.
리뷰 완료는 위의 소스 반례와 실제 다중 사용자·모델 실행 공백을 없앴다는 뜻이 아니다.


## MASC 후속 리뷰의 P2 대응

원 head 88df3ad213bd6ac290f41032d3362dff606b2ec0에 대해 ocaml-agent-ic이
[review 5650416953](https://github.com/jeong-sik/masc/pull/46092#pullrequestreview-5650416953)에서
null stimulus_id receipt의 목록 전체 실패를 지적했다. 이 후속 발견으로 앞선 source PASS를
전체 무결함 근거로 이월하지 않는다. 지원되는 미확인 receipt만 Unknown으로 보존하도록 수정했고,
남은 identity와 증거의 부정합은 거절한다. 원 리뷰어의 CR 해소는 별도 재검토 대상이다.

추가 검증: component 새 사례는 수정 전 1/13 실패, 수정 후 13 PASS.
실제 production 행/목록 decoder source를 실행한 혼합 페이지는 수정 전 3/9 실패,
수정 후 추가 음성 대조군 포함 13 PASS. 현재 domain 28 / historical replay 14 / selection 8도 통과했다.
이는 decoder 소비자 증거이며 다중 provider·사용자 runtime이나 설치된 TUI 실행 증거가 아니다.
