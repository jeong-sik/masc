# Health message-mutation cache 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-31T00:19:58+09:00`
- 작성자: `Codex`
- 결정 ID: `health-message-mutation-cache-linux-r1`
- 적용 대상: cached full-health Keeper event queue and reaction ledger projection
- 결정 상태: `추적 필요`

## 근거

- 항목: committed workspace message/delivery mutation 뒤 full health는 old ready queue facts를
  재사용하면 안 된다.
- 출처: exact-source Linux mention/immediate/fresh snapshots, BuildKit identity, focused tests
- 확인일시: `2026-08-31T00:19:58+09:00`
- 신뢰도: `High`
- 제한조건: isolated one-server Linux/arm64 container와 stopped Keeper mention을 실측했다.
- Delta: server-installed message mutation hook이 기존 workspace/dashboard invalidation 및 SSE와
  full-health invalidation/wake를 합성한다.

## 검증

- 1차: source audit에서 message mutation hook에 full-health invalidation이 없음을 확인했다.
- 2차: pre-fix r47은 accepted mention 4ms 뒤에도 old queue/ledger count 1을 유지했다.
- 3차: 나중 fresh snapshot은 같은 durable queue를 count 2로 계산했다.
- 4차: post-fix r48은 accepted response 약 1.2ms 뒤 snapshot을 계산했고 immediate probe는
  current-ready queue/ledger count 3을 반환했다.
- 5차: focused test는 기존 두 cache prefix invalidation, unrelated cache 보존,
  full-health callback exactly-once를 확인했다.
- 재현 결과: 성공. message queue 변이를 숨기던 false-ready window를 제거했다.

## 불확실성

- 미확인 항목: multi-server process, broadcast burst 중 wake coalescing의 장시간 부하,
  Draft PR CI/review.
- 영향: process-global hook과 unbounded wake stream은 one-server process에서 검증됐다.
- 추가 확인 필요: Draft PR checks/review와 #31977 → #31979 merge 순서를 유지한다.

## 적용범위

- 영향 받는 영역: committed workspace message/delivery mutation 뒤 workspace/dashboard/SSE와
  cached full-health queue/ledger projection.
- 제약/배제: message authority, delivery policy, queue classification, refresh interval은 바꾸지 않는다.
- 롤백 조건: accepted mention 뒤 old ready counts가 재출현하거나 callback failure가 committed
  message 결과를 실패시키면 롤백한다.

