# Keeper 대기와 종료 차단 복구

큐의 pending 개수는 아직 처리하지 않은 입력 수다. 실패 횟수가 아니다.
`/health?full=1`의 전체 등급, `operator_action_reasons`, Keeper별
`/api/v1/keepers/<name>/waiting-inventory`를 함께 읽는다.

## 실행 후보의 한도가 모두 찬 경우

`runtime_quota_spent`는 실행 중인 Keeper의 배정 후보가 모두 한도를 소진했을
때 나온다. Keeper마다 한 행이며 계정 수나 누적 거절 수를 뜻하지 않는다.

1. Keeper 설정의 현재 배정과 `config_revision.runtime_assignment`를 읽는다.
2. `/api/v1/runtime/resolved`에서 이미 선언된 대체 경로의 후보와 현재 휴식,
   문맥 크기 등 실행 조건을 확인한다. 휴식 표시가 없다는 것만으로 실제 호출이
   성공한다고 판정하지 않는다.
3. 배정을 바꾸기로 결정했다면 기존 assignment API에 읽은 revision을 함께
   보낸다. 409이면 새 상태를 읽고 다시 판단한다. revision만 바꿔 재전송하지 않는다.
4. 저장·적용 결과와 배정을 다시 읽은 뒤 실제 후보 선택, 턴 결과, 입력 정산을
   확인한다. 별도 wake나 입력 재전송은 필요하지 않다.

제공자가 밝힌 한도 해제 시각은 다시 시도할 수 있는 시각이다. 성공 보장이 아니다.
재시작으로 경고가 사라져도 제공자 한도가 풀렸다는 증거가 되지 않는다.

## 종료 중 Task 버전이 바뀐 경우

새 종료 처리는 쓰기 전 `BacklogVersionConflict`를 만나면 최신 소유권과 같은
종료 작업의 반환 기록을 다시 확인한다. 다른 주체의 Task를 반납하거나 원래
정리 대상 밖으로 범위를 늘리지 않는다.

이미 `Blocked(Task_settlement)`로 저장된 기록은 별도 확인이 필요하다.
오류 문장을 해석해 자동 재생하지 않는다. 다음 API는 `CanAdmin` 인증을 요구한다.

- 조회: `GET /api/v1/keepers/<name>/shutdown-operations/<operation-id>/task-settlement-retry`
- 재개 요청: 같은 경로의 `POST`

조회는 저장된 작업과 현재 재개 조건을 읽으며 예약이나 변경을 만들지 않는다.
`eligible: true`이고 두 버전이 모두 관측됐을 때 재개를 요청할 수 있다.
재개 요청에는 조회한 두 버전과 사유를 담는다.

```json
{
  "schema": "masc.keeper_shutdown.task_settlement_retry.request.v1",
  "expected_revision": 1,
  "expected_backlog_version": 42,
  "reason": "현재 소유권과 반환 기록을 확인한 뒤 원래 종료 요청을 재개한다"
}
```

위 숫자는 예시다. 현재 조회 결과를 사용한다. 서버는 같은 작업의 진입 차단,
Keeper identity, 실행 중인 턴·레인의 부재, 다른 종료 기록, 원래 Task의 소유권과
정확한 반환 기록을 다시 확인한다. 처음에는 등록된 실행 레인이 없는
`Dormant_meta / No_inflight_turn / Blocked(Task_settlement)`만 허용한다.
기록을 읽지 못하거나 소유권·identity·버전이 바뀌면 재개하지 않는다.

응답의 `applied`는 재개 단계가 저장됐다는 뜻이고, `scheduled`는 기존 종료
처리에 예약됐다는 뜻이다. 두 값만으로 종료·삭제 완료를 판단하지 않는다.
작업을 다시 읽고 실제 정리와 완료 전달 결과를 확인한다. 저장 후 예약하지
못한 경우에도 저장 사실과 예약 실패가 각각 응답에 남는다. `audit`는 감사
기록 결과이며, 기록 실패가 이미 저장된 재개를 취소하지는 않는다.
재개 후에는 같은 조회 경로로 저장된 단계를 읽을 수 있다. 그때
`eligible: false`여도 이미 진행 중이거나 완료된 작업일 수 있다.

다른 종류의 `Blocked`, 실행 결과가 불확실한 종료, 사라진 owner의 확인은 이
API의 범위가 아니다. 진입 차단이나 큐 파일을 직접 지우지 않고 해당 기록의
원인과 지원하는 복구 동작을 확인한다.
