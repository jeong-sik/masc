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
| `local_failure` | 로컬 복구 작업이 결과를 반환하지 못했거나, 명시적 memory admission pass가 자기 오류로 끝남 | 표시된 원인과 복구 근거를 확인한다. |

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

## 결과 증거가 없는 정확한 원 요청의 처리

worker와 host Exact record 및 결과 증거가 모두 없는 dispatched original은 위 복원으로
해결되지 않는다. 기다리거나 sync를 반복한 사실은 재전송 근거가 되지 않는다.
원본·커서·Memory·worker volume을 지워 미실행 상태로 바꾸지 않는다.

이 변경은 개별 history 원본의 향후 Memory 적용을 내구적으로 차단하고, 그 원본이
포착한 범위를 현재 Memory로 새로 판단하는 API를 추가한다. 아래는 소스 계약이며
배포나 실제 복구를 수행한 기록이 아니다. 대상 서버에 이 구현이 배포됐는지 먼저
확인한다. 기존 catch-up의 202나 정상 health만으로 새 API의 가용성을 판단하지 않는다.

GET과 POST의 경로는 같다. 두 메서드 모두 bearer의 `CanAdmin` 권한이 필요하다.

```text
/api/v1/keepers/<keeper>/memory-history-originals/<request-id>/resolution
```

`request-id`는 관측한 원본 ID의 canonical JSON 문자열 전체다. 이를 한 경로 구간으로
percent-encode 한 번만 한다. JSON을 다시 포맷하거나 이중 인코딩하지 않는다.
서버는 경로 구간을 나눈 뒤 한 번 decode한다.

먼저 정확한 원본의 GET을 읽는다. 응답 schema는
`keeper.memory.history_original_resolution.v1`이다. `preview.kind=eligible`일 때의
`preview.expected` 전체를 사용한다. 원본에 과거 저장된 Memory revision을 대신 쓰지
않는다. 이 값은 예약이 아니며 실제 직렬 lane에서 다시 대조한다. 이미 차단된 원본은
`already_fenced`와 기존 `fence`를 보여 주며 새 expected를 제시하지 않는다.

`original_range`는 원본에 보존된 atom·official 범위 요약이다. 현재 health의 gap이나
unread 전체와 다를 수 있으며, 그 수치를 차단 또는 새 판정의 범위로 대신하지 않는다.
원본 부재, host 실행 기록·완료 proof, 기존 범위 receipt, 읽기 실패 등으로 조건을
확인할 수 없으면 진행하지 않는다. `eligible=null`은 부적격 확정이 아닌 관측 불가다.

POST는 아래 네 필드만 받는다. `expected_workspace`의 `base_path`와 `masc_root`는
대상 서버가 공개한 실제 canonical 경로여야 한다. 다음 JSON은 합성 예시이며 그대로
실행할 요청이 아니다. 해시는 해당 GET의 expected로, 경로는 대상 workspace로 바꾼다.

```json
{
  "schema": "keeper.memory.history_original_resolution.request.v1",
  "expected_workspace": {
    "base_path": "/example/workspace",
    "masc_root": "/example/workspace/.masc"
  },
  "expected": {
    "owner_record_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "memory_revision": 7,
    "memory_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "cursors_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  },
  "reason": "정확한 원본의 결과 부재를 확인하고 같은 범위의 새 판정을 요청함"
}
```

Memory가 없는 관측은 `memory_revision`과 `memory_sha256`이 함께 null이다. 필수 필드
누락·중복·알 수 없는 필드는 거절한다. `actor`, Keeper 이름, 원본 ID는 본문에 넣지
않는다. actor는 인증된 서버 값이고 대상은 경로에서 정한다. workspace 누락·형식 오류는
400, 다른 workspace는 409로 내구 접수 전에 거절한다.

POST의 `durable_acceptance=recorded`는 intent가 저장됐다는 뜻이다. 이어지는
`scheduling.kind=submitted|coalesced`는 202 예약 결과다. Librarian disabled/invalid는
409, executor 미초기화·`ran_inline`·`dropped`·예약 실패는 503이지만, 응답에
`recorded`가 있으면 intent는 남아 있다. 이를 무접수로 간주해 반복 POST하지 않는다.
`durable_acceptance=unconfirmed`도 무쓰기를 뜻하지 않는다. 정확한 같은 GET을 읽어
intent와 fence를 확인한 뒤 판단한다.

POST의 `completion.kind`는 항상 `not_observed`다. 이후 GET은 저장된 완료 증거만
보여 준다. `intents[].phase.kind`의 `requested`, `fenced`, `child_intended`,
`child_confirmed`와 `completion.kind=memory_committed`를 구분한다. `refused` 또는
`unavailable`이면 해당 typed 관측을 보존한다. child 확인, worker 응답, 주의 행의 부재도
실제 Memory 완료를 대신하지 않는다. 이 GET은 lane을 깨우거나 Memory epoch·receipt를
복구 저장하지 않는다.

원래 RPC의 재전송, 옛 원문·불명확한 실행 증거·커서의 삭제나 선행 ACK는 이 API의
효과가 아니다. 정확한 범위의 새 child가 실제 Memory receipt를 남긴 뒤 기존 consumer가
입력을 ACK한다. 자세한 계약은
[history original resolution RFC](../rfc/RFC-librarian-history-unknown-resolution.md)를 따른다.

## 관측 범위와 배포

Memory health 응답은 `librarian.operator_action_required`, 별도 attention alert,
`alert_summary.librarian_attention_required_keepers`를 함께 제공한다. 서버·TUI·dashboard를
같은 계약으로 배포한다. 다른 schema의 응답을 decoder에 통과시키는 호환 경로는 없다.

`/health?full=1`의 `keeper_memory_attention`은 현재 프로세스에서 완료한 durable 관측과
독립 admission 관측(worker 대기 또는 pass 실패)을 읽는다. `operator_action_required`와 이유가 전체 health로 이어진다.
관측 수와 scope를 함께 보며, 일부 관측에 attention이 없다는 결과를 fleet 전체 drain으로
부르지 않는다. `keeper_memory_execution`의 serving은 별도의 경로 가용성이다.

대시보드는 갱신 실패 시 이전 값을 보존하면서 실패와 마지막 관측임을 표시한다.
TUI는 보유 snapshot보다 앞선 행 응답으로 행을 교체하거나 없애지 않고 fleet을 다시 읽는다.
이는 관측 순서를 지키는 동작이며 Memory 실행·복구를 새로 허가하지 않는다.
