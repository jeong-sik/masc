# Health task-mutation cache 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-31T00:05:02+09:00`
- 작성자: `Codex`
- 결정 ID: `health-task-mutation-cache-linux-r1`
- 적용 대상: cached full-health task-owner fleet projection
- 결정 상태: `추적 필요`

## 근거

- 항목: successful task mutation 뒤 full health는 TTL 내 old ready owner facts를 재사용하면 안 된다.
- 출처: exact-source Linux claim/immediate/periodic snapshots, BuildKit identity, focused tests
- 확인일시: `2026-08-31T00:05:02+09:00`
- 신뢰도: `High`
- 제한조건: isolated one-server Linux/arm64 container와 one active task owner를 실측했다.
- Delta: server-installed task mutation hook이 execution cache invalidation과 full-health
  invalidation/wake를 한 callback에서 합성한다.

## 검증

- 1차: source audit에서 task hook이 execution/light-dashboard cache만 무효화함을 확인했다.
- 2차: pre-fix r45는 claim 5ms 뒤에도 computed time과 owner false/count 0을 유지했다.
- 3차: 같은 task state의 periodic snapshot은 owner true/count 1을 계산했다.
- 4차: post-fix r46는 claim 완료와 같은 millisecond에 새 snapshot을 계산했고 4ms 뒤
  current-ready owner true/count 1을 반환했다.
- 5차: focused tests는 execution invalidation이 유지되고 full-health invalidation이 정확히 한 번
  호출되며, invalidated response가 warming/refresh-requested를 반환함을 확인했다.
- 재현 결과: 성공. task ownership 변이를 숨기던 false-ready TTL window를 제거했다.

## 불확실성

- 미확인 항목: multi-server process, task mutation 폭주 시 wake coalescing의 장시간 부하,
  Draft PR CI/review.
- 영향: process-global hook과 unbounded wake stream은 현재 one-server process contract에서 검증됐다.
- 추가 확인 필요: Draft PR checks와 review를 확인하고, #31977 merge 순서를 유지한다.

## 적용범위

- 영향 받는 영역: authoritative task/goal-link mutation 뒤 execution 및 cached full-health projection.
- 제약/배제: task authority, Keeper scheduling, health policy, refresh interval은 바꾸지 않는다.
- 롤백 조건: task mutation 뒤 old ready fields가 재출현하거나 composed observer failure가
  authoritative task commit 결과를 실패시키면 롤백한다.

