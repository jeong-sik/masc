# Full-health owner-readiness boundary 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-31T02:52:54+09:00`
- 작성자: `Codex`
- 결정 ID: `health-ready-boundary-linux-r1`
- 적용 대상: full-health refresh loop startup ordering
- 결정 상태: `추적 필요`

## 근거

- 항목: full-health refresh loop는 shell prewarm 반환이나 post-ready auxiliary setup이 아니라 owner
  readiness에 직접 결합한다.
- 출처: exact-source r61/r62/r63 Linux restart runs, Eio official documentation, straggler primary papers
- 확인일시: `2026-08-31T02:52:54+09:00`
- 신뢰도: `High`
- 제한조건: one-process Linux/arm64, preserved durable volume, 0.01 CPU timeout 뒤 0.5 CPU restart를
  실측했다.
- Delta: `start_full_health_snapshot_refresh_loop` 호출을 `mark_owner_state_ready` 직후로 이동한다.

## 검증

- 1차: baseline r61에서 active-timeout stop이 3.37초/exit 0으로 끝났지만 restart-to-current가
  62.882초임을 확인했다.
- 2차: shell prewarm 직전 병렬화 r62는 timeout을 만들고 current latency를 62.619초로 거의 줄이지
  못해 폐기했다.
- 3차: owner-readiness 배치 r63은 start-to-current 1.823초, submissions 1, joins 0, timeout 0이었다.
- 4차: r61 durable receipt/ledger 4/4와 r63 queue 252/latest stimulus 일치를 확인했다.
- 5차: cold empty-volume r64가 start-to-current 1.739초, submissions 1, joins 0, timeout 0으로
  수렴했다.
- 6차: focused main_eio/bootstrap build와 cases 73–74 2/2, format/diff check, app exit 0을 확인했다.
- 재현 결과: 성공. 단순 병렬화 실패를 버리고 owner readiness 배치에서 current recovery를 97.1%
  단축했다.

## 불확실성

- 미확인 항목: multi-server, external PG latency, 더 큰 Keeper fleet, Draft PR CI/review.
- 영향: 다른 startup workload에서는 초기 full-health scan이 post-ready lanes와 자원 경쟁을 일으킬 수
  있다. generation invalidation은 false-ready publication을 막지만 총 startup CPU는 늘 수 있다.
- 추가 확인 필요: cold-volume 및 larger-fleet restart pair, resource timing telemetry, Draft PR checks와
  review, stacked merge order 유지.

## 적용범위

- 영향 받는 영역: post-readiness full-health loop launch order.
- 제약/배제: shell prewarm budget/timeout, generic proactive refresh, full-health worker singleflight,
  producer invalidation semantics는 바꾸지 않는다.
- 롤백 조건: owner-ready 시간이 악화되거나 first current가 shell-prewarm baseline보다 느려지거나 초기
  result가 post-ready mutation 뒤 current로 수렴하지 않으면 롤백한다.
