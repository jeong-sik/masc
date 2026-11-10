# Keeper 메모리 처리와 복구

Keeper 턴 완료와 Memory 반영은 별도 단계다. 턴을 마치면 보존한 원문을 읽으라는
신호가 Librarian lane으로 간다. 다음 턴 전에 반영이 끝난다는 시간 약속은 없다.

## 상태부터 구분한다

| 관측 | 의미 | 다음 행동 |
|---|---|---|
| `processing` | 기존 worker 결과를 기다림 | 기존 원 요청의 결과를 관측한다. |
| `capacity` | worker 접수 전 용량 거절 | 해당 installation의 실제 용량 반환 신호로 다시 진행한다. |
| `missing_after_dispatch` | 전송 의도 뒤 worker에서 원 요청을 찾지 못함 | 원 요청·host Exact·실행 proof를 확인한다. 실행되지 않았다는 뜻은 아니다. |
| `outcome_unknown` | 원 실행 결과가 불명확함 | 원인과 권위 있는 결과 증거를 확인한다. |
| `local_failure` | 로컬 복구 작업이 결과를 반환하지 못함 | 표시된 원인과 복구 근거를 확인한다. |

뒤의 세 상태는 기존 typed `needs_attention` 규칙에 따라 조치 필요로 표시된다.
durable history와 명시적 memory admission 중 하나라도 해당하면 Keeper를 한 번 센다.
일반 processing과 섞거나 stopped 수로 바꾸지 않는다.

## 사용할 수 있는 명령

선택한 Keeper의 채팅에서 `/memory status`로 서버 관측 행을 조회한다.
대기 원인과 durable 측정 시각을 함께 본다. 원 요청 ID는 대시보드의 상세 pending/admission
관측 JSON에서 확인한다. 요청마다 원문 전체를 다시 계산하는 것은
아니다. admission wait와 durable 측정은 별도 관측이며 durable 시각으로 admission의
최근 상태까지 판단하지 않는다.

`/memory sync`는 기존 직렬 Memory lane을 깨운다. HTTP202의 submitted/coalesced와
`completion=unobserved`는 접수 결과다. Memory 반영 완료나 재전송 허가가 아니다.
`/memory`만 입력하면 timeline 표시가 바뀐다.

## 원 결과로 자동 복원할 수 있는 경우

원 호출의 host execution proof는 저장됐지만 Exact terminal publication이 끊긴 경우,
다음 유효한 wake에서 submit-once 소비자가 결과를 복원할 수 있다. worker에 원 요청이
나열되지 않거나 worker가 Off여도 이 복원은 worker RPC·provider 호출을 하지 않는다.

복원은 같은 원 요청 claim 아래에서 전체 record·proof와 마지막 Started ordinal,
원본 schema를 검증한다. 일치하는 `Call_ended`만 저장한 뒤 다시 읽는다. 그 뒤에도
소비자의 원본 답변 검증, 실제 Memory 반영, 범위 receipt 확인, 해당 stream의 ACK가
남는다. 원 terminal 복원이 곧 Memory commit은 아니다.

활성 claim이나 proof가 없는 Started는 그대로 둔다. provider refusal proof도 이
경로에서 terminal이나 다음 실행으로 바꾸지 않는다. 이전 attempt, 다른 schema,
손상된 proof, 원 Exact record 없는 orphan proof로 원 요청을 진행시키지 않는다.

## 증거가 없는 원 요청

worker와 host Exact record 및 결과 증거가 모두 없는 dispatched original은 위 복원으로
해결되지 않는다. 기다리거나 sync를 반복한 사실은 재전송 근거가 되지 않는다.
원본·커서·Memory·worker volume을 지워 미실행 상태로 바꾸지 않는다.

이 버전은 그런 원본을 안전하게 clear하는 명령을 제공하지 않는다. 개별 원본의 향후
Memory apply를 내구적으로 fence하고 후속 판단을 연결하는 별도 계약과 검증이 필요하다.
이 잔여 작업은 [#50828](https://github.com/jeong-sik/masc/issues/50828)에서 추적한다.

## 관측 범위와 배포

Memory health v13은 `librarian.operator_action_required`, 별도 attention alert,
`alert_summary.librarian_attention_required_keepers`를 함께 제공한다. 서버·TUI·dashboard를
같은 계약으로 배포한다. v12를 새 decoder에 통과시키는 호환 경로는 없다.

`/health?full=1`의 `keeper_memory_attention`은 현재 프로세스에서 완료한 durable 관측과
독립 admission wait를 읽는다. `operator_action_required`와 이유가 전체 health로 이어진다.
관측 수와 scope를 함께 보며, 일부 관측에 attention이 없다는 결과를 fleet 전체 drain으로
부르지 않는다. `keeper_memory_execution`의 serving은 별도의 경로 가용성이다.

대시보드는 갱신 실패 시 이전 값을 보존하면서 실패와 마지막 관측임을 표시한다.
TUI는 보유 snapshot보다 앞선 행 응답으로 행을 교체하거나 없애지 않고 fleet을 다시 읽는다.
이는 관측 순서를 지키는 동작이며 Memory 실행·복구를 새로 허가하지 않는다.
