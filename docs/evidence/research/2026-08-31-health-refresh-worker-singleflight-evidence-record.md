# Full-health worker singleflight 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-31T02:30:04+09:00`
- 작성자: `Codex`
- 결정 ID: `health-refresh-worker-singleflight-linux-r1`
- 적용 대상: event-driven full-health worker lifecycle
- 결정 상태: `추적 필요`

## 근거

- 항목: caller timeout 뒤에도 실행 중인 full-health worker는 process-wide singleflight로 공유하고,
  compute 중 invalidation된 generation의 결과는 게시하지 않는다.
- 출처: exact-source r60 Linux runtime, local Eio 5.5 executor source, durable receipt/ledger/timeseries,
  current primary literature
- 확인일시: `2026-08-31T02:30:04+09:00`
- 신뢰도: `High`
- 제한조건: single-process Linux/arm64 container, 0.05 CPU fault, 61-schedule load를 실측했다.
- Delta: active worker promise, waiter join, late publication, invalidation generation discard/follow-up을
  full-health refresh에 적용한다.

## 검증

- 1차: Eio executor pool에서 caller promise wait 취소가 worker function 실행 취소를 보장하지 않음을
  source로 확인했다.
- 2차: 첫 20초 timeout 뒤 submissions=62/active=true가 유지되고 다음 wake가 submissions 증가 없이
  joins=1로 바뀌었다.
- 3차: 두 번째 timeout 뒤 submissions=63인 채 late ready snapshot이 게시됐다.
- 4차: generation이 바뀐 worker 결과 2개가 폐기됐고 bounded follow-up이 current snapshot을 게시했다.
- 5차: 61 accepted receipt가 61 unique durable ledger row로 수렴하고 final latest stimulus가 일치했다.
- 6차: focused health cases 6/6, format/diff check, app exit 0을 확인했다.
- 재현 결과: 성공. r59의 timeout 후 successor overlap 경로가 active-worker join과 late publication으로
  바뀌었고 dirty result는 폐기됐다.

## 불확실성

- 미확인 항목: multi-process/server singleflight, worker 영구 hang, server switch shutdown과 raw executor
  job 종료의 최악 지연, Draft PR CI/review.
- 영향: process 밖 worker는 조율되지 않으며 영구 hang이면 active promise가 새 refresh를 계속 join시킬
  수 있다.
- 추가 확인 필요: bounded worker abandonment/epoch 정책 PoC, multi-server fault run, Draft PR checks와
  review, 앞선 stacked PR merge 순서 유지.

## 적용범위

- 영향 받는 영역: cached full-health background worker submission/publication/failure metadata.
- 제약/배제: generic `Proactive_refresh`, timeout/backoff 값, producer invalidation hooks, synchronous test
  refresh는 바꾸지 않는다.
- 롤백 조건: timeout 뒤 submissions가 active worker와 동시에 증가하거나 dirty generation 결과가 ready로
  게시되거나 final durable latest stimulus가 current snapshot에서 누락되면 롤백한다.
