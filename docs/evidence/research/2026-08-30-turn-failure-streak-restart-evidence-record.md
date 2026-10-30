# Turn failure streak restart 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T22:08:59+09:00`
- 작성자: `Codex`
- 결정 ID: `turn-failure-streak-restart-linux-r1`
- 적용 대상: Keeper consecutive turn-failure accounting
- 결정 상태: `추적 필요`

## 근거

- 항목: 동일 checkpoint와 실패 chain을 재개하는 Keeper는 process restart 전의 연속 실패
  횟수를 이어가야 한다.
- 출처: exact-source Linux BuildKit image, internal fake-provider log, live
  `masc_keeper_status`, execution receipt, durable streak snapshot, `/health?full=1`
- 확인일시: `2026-08-30T22:08:59+09:00`
- 신뢰도: `High`
- 제한조건: 네 Keeper, two-candidate lane, typed thinking-only `Accept_rejected`로 측정했다.
- Delta: registry-only counter를 strict Keeper별 durable record로 승격하고 등록 전에 복원한다.

## 검증

- 1차: baseline clean restart가 동일 failure chain을 `1 -> 1`로 보고하는 것을 확인했다.
- 2차: focused registry restart sequence와 malformed schema fail-closed, direct keepalive,
  147,200-case typed terminal matrix가 통과했다.
- 3차: fixed exact-source Linux에서 첫 실패 `count:1`, 첫 restart POST 전 live count 1,
  두 번째 실패 뒤 durable/live count 2를 확인했다.
- 재현 결과: 성공. process restart가 연속 실패 chain을 새 chain으로 위장하던 gap을 닫았다.

## 불확실성

- 미확인 항목: durable write/remove I/O fault injection, crash가 durable save와 registry update
  사이에 발생하는 경우의 operator surface.
- 영향: filesystem failure에서는 process-local count와 durable count가 일시적으로 다를 수 있다.
- 추가 확인 필요: Draft PR CI/review bot과 fault-injection 회귀를 추적한다.

## 적용범위

- 영향 받는 영역: Keeper 등록/restart 등록, turn failure increment, successful turn/operator clear.
- 제약/배제: runtime lane 선택, provider protocol, receipt disposition, checkpoint 내용은 바꾸지 않는다.
- 롤백 조건: restart 전 count가 복원되지 않거나, successful reset 뒤 count가 부활하거나,
  malformed record를 0으로 처리하면 롤백한다.
