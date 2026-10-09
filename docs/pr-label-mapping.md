# PR 라벨 매핑 가이드

PR 을 분류할 때 세 축 라벨(kind / area / impact)을 각각 하나씩 붙이고, 검토가 진행되면 `pr/*` 상태 라벨을 더하거나 갱신합니다.

라벨 어휘의 정본은 `.github/issue-taxonomy.json`입니다. 이 문서는 정본 어휘로 PR 분류를 안내하며, 정본이 은퇴한 라벨(`area/tui`, `area/gates`, `area/typed`, `impact/no-op`)은 쓰지 않습니다.

## kind — PR 이 무엇을 하는가

| 라벨 | 쓰는 곳 |
|---|---|
| kind/defect | 버그 수정 |
| kind/gap | 없던 기능의 격차 해소 |
| kind/capability | 새 능력·확장 |
| kind/refactor | 동작 변경 없는 재구성 |
| kind/test | 테스트만 추가·수정 |
| kind/docs | 문서·감사 기록 |
| kind/inquiry | 질문·조사 성격 |
| kind/erosion | 자원·구조 침식 대응 |

## area — 어느 영역인가 (하나)

area/keeper, area/dashboard, area/ci, area/collab, area/connector, area/continuity, area/goal-task, area/observability, area/persistence, area/runtime, area/tools, area/transport, area/turn, area/verification

- 변경 파일 경로(`lib/`, `test/`, `bin/` 아래)를 근거로 정합니다.
- 코드 경로가 없는 문서 전용 PR 은 문서가 다루는 주제 기준으로 정합니다(예: 분류·게이트 문서는 `area/tools`).
- TUI 화면 변경은 `area/dashboard` 입니다. 정본이 `area/tui`를 `area/dashboard` 에 합쳤습니다.
- 여러 영역을 건드리면 가장 중심인 하나만 남깁니다.

## impact — 바깥에 미치는 영향 (하나)

| 라벨 | 의미 |
|---|---|
| impact/internal | 내부 동작만 바꿈(기본값). 동작 변화가 없는 문서·테스트 변경도 여기 |
| impact/degrades | 어떤 동작이 나빠질 수 있음 |
| impact/breaks-continuity | 연속성을 깰 수 있음 |
| impact/breaks-collab | 협업 흐름을 깰 수 있음 |
| impact/blinds-operator | 운영자 가시성을 가림 |

## 상태 라벨(진행 중 갱신)

| 라벨 | 의미 |
|---|---|
| pr/review-approved | 현 head 에 결속된 approve-guard footer 승인이 존재 |
| pr/review-changes | 열린 변경 요청 또는 FAIL 판정이 존재 |
| pr/unresolved | 미해결 리뷰 스레드가 존재 |
| pr/conflict | main 과 충돌 |

해당하지 않는 상태 라벨은 붙이지 않습니다.

## 규칙

- 축 라벨은 PR 당 각 하나입니다.
- 라벨만으로 승인·병합을 판정하지 않습니다. 판정 근거는 리뷰 본문의 `verdict: PASS head: <40자>` 첫 줄과 `approve-guard: head <40자>` footer 로만 셉니다.
