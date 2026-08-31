# Full-health mutation burst coalescing 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-31T01:43:22+09:00`
- 작성자: `Codex`
- 결정 ID: `health-refresh-burst-coalesce-linux-r1`
- 적용 대상: event-driven full-health mutation refresh loop
- 결정 상태: `추적 필요`

## 근거

- 항목: mutation wake는 current-state refresh를 보장하되 짧은 sibling burst를 complete scan마다
  증폭시키면 안 된다.
- 출처: exact-source r57/r58 Linux schedules, debug refresh logs, durable ledger rows, current primary
  literature
- 확인일시: `2026-08-31T01:43:22+09:00`
- 신뢰도: `High`
- 제한조건: isolated one-server Linux/arm64 container와 61-schedule burst를 실측했다.
- Delta: full-health wake에만 100ms fixed leading-edge coalescing을 적용한다.

## 검증

- 1차: source audit에서 pre-compute drain만 있고 time window가 없음을 확인했다.
- 2차: pre-fix 122 invalidation은 1.252s 동안 refresh 104회를 만들었다.
- 3차: post-fix 동일 122 invalidation은 17 refresh와 105 coalesced siblings로 accounting됐다.
- 4차: final ready snapshot의 latest stimulus가 newest durable row와 일치했다.
- 5차: single ledger mutation은 112.205ms 뒤 current-ready가 됐다.
- 6차: 두 실행 모두 timeout/stale/error 없이 exit 0으로 끝났다.
- 재현 결과: 성공. refresh amplification을 83.7% 줄이고 bounded freshness를 유지했다.

## 불확실성

- 미확인 항목: 수분 이상 지속되는 continuous mutation load, slow 1s+ health compute, multi-server
  process, Draft PR CI/review.
- 영향: fixed window는 trailing-edge starvation을 만들지 않지만, 지속 부하에서는 약 100ms마다
  refresh가 계속될 수 있다.
- 추가 확인 필요: 장시간 부하와 slow-compute fault injection, Draft PR checks/review,
  #31977 → #31979 → #31981 → #31984 → #31987 → #31989 merge 순서를 유지한다.

## 적용범위

- 영향 받는 영역: generic proactive wake scheduling과 full-health event-driven refresh.
- 제약/배제: generic default는 0ms, periodic interval/timeout/backoff, cached fields, producer
  invalidation semantics는 바꾸지 않는다.
- 롤백 조건: single mutation freshness가 설정 bound를 넘거나 latest durable row가 ready snapshot에서
  누락되거나 continuous load가 refresh starvation을 만들면 롤백한다.

