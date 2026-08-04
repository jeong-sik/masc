# RFC-0357 — Scheduled-autonomous 턴은 heartbeat가 아니라 typed stimulus의 변화로 admit한다

- Status: Withdrawn (2026-08-04)
- Created: 2026-08-02
- Withdrawal issue: #26697
- Related: #26675, #26690

## 결정

이 제안은 구현하지 않는다.

Keeper는 매 턴 task, board, goal을 직접 관측하고 다음 행동을 스스로 결정한다.
서버가 backlog 변화량을 별도로 소비해 scheduled-autonomous 턴을 허가하거나
억제하면 자율 판단 앞에 중복 admission gate가 생긴다. 소비 cursor의 별도 저장
권한까지 필요해져 비용과 상태 복잡도가 기능 이득을 초과한다.

따라서 PR-0이 추가했던 backlog-edge 관측값은 현재 계약에서 제거한다. 과거
데이터를 위한 필드, decoder, migration, fallback은 두지 않는다.

## 존치 불변식

- backlog의 commit-point revision은 저장 데이터 위생을 위한 단일 권한으로 유지한다.
- revision은 Keeper admission이나 wake suppression 정책을 소유하지 않는다.
- Keeper의 주기 실행, reactive wake, schedule 실행 계약은 이 철회로 변경하지 않는다.
- 진척도 점수, no-progress counter, retry/turn cap 같은 대체 휴리스틱을 추가하지 않는다.

## 종결

이 문서는 철회 사실과 남는 경계만 보존하는 tombstone이다. 아래 구현 계획,
상태 필드, 실패 매트릭스, 검증 계획은 모두 폐기했으며 현재 설계로 해석하면 안 된다.
