# Ego user-owned Space recovery

2026-11-02 사고. 로그인 인계(`hand_off`) 뒤 task 가 끝나면 ego lite 의 작업
Space 소유권이 `user` 로 남는다. ego backend 는 user 가 소유한 이름의 Space 를
열지 않으므로 browser lane 은 연결을 거부하고, worker 는 재시작 전까지 그
상태를 다시 확인하지 않는다. `masc-keepers` Space 가 이 상태로 5일간 남아
`clients: []` 가 이유 없이 반화됐고, 복구는 운영자가 raw SDK 로
`claimTaskSpace` 를 부르고 lane addon 을 detach/attach 하는 작업이었다.

## 실측 사실 (2026-11-02, ego lite 0.6.2.5)

- `takeOverTaskSpace(id)` 는 task 가 끝난 Space 에서 프로세스를 종료한다.
  try/catch 로 잡을 수 없다. 한 스크립트 안에서 "takeOver 실패 시 claim" 의
  fallback 은 불가능하고, 호출 전 관찰로 둘 중 하나를 골라야 한다.
- `claimTaskSpace(id)` 만 끝난 task 의 Space 를 agent 소유로 되돌린다.
- `taskSpace(name 또는 id)` 는 user 가 소유한 끝난 Space 에도 붙어
  `ownership` 을 보고한다. 연결 거부는 ego SDK 가 아니라 masc 의
  `Browser_ego_peer.open_space` 가 내리는 판단이다.
- 위임 중(`agentDelegatedToUser`)에는 open 이 되고 step 만 거부된다. 막힌
  상태는 task 종료로 소유권이 `user` 가 된 경우뿐이다.
- worker 가 `Browser_addon_owner.mark_ego_user_owned_name` 으로 기록한
  `unavailable` 은 snapshot 과 `published` 에 실려 서버까지 오지만,
  `Browser_connection_inventory.build` 는 이를 결과에 넣지 않는다. 그래서
  `clients: []` 가 침묵한다.

## 변경

### L1 — inventory 가 거부 이유를 말한다

`Browser_connection_inventory` 의 issue 에 닫힌 합타입을 추가한다.

```
Ego_user_owned_space of { instance_id : string; space : string; observed_at : float }
```

`build` 가 각 관측의 `published.unavailable` 에서 `Ego_user_owned_name` 을
이 issue 로 바꾼다. 결과 JSON 은 `inventoryIssues` 에
`kind: "ego_user_owned_space"`, `instanceId`, `space`, `observedAt` 를 싣는다.
TUI 디코더는 `issues_of_json` 을 공유하므로 같이 갱신된다.

이 issue 는 worker 가 온전히 답한 lane 사실이지 관측 실패가 아니므로,
인벤토리 완전성을 깨지 않고 자동 선택도 막지 않는다. 거부만 남은 lane 에서
자동 선택은 `no_available_browser` 로 거부하고, 같은 worker 가 다른
수송의 건강한 client 를 서빙 중이면 그 client 를 여전히 자동으로 고른다.
issue 는 그 옆에 계속 나열된다. 관측이 실제로 읽히지 않은 기존
`Source_unavailable` 계열과 구분된다.

### L2 — take_over 가 끝난 task 의 Space 를 회수한다

`BrowserAct take_over` 는 두 입력을 받는다.

- 관측된 `clientId` 와 함께 (현행): 연결된 peer 에서 SDK
  `takeOverTaskSpace` 를 부른다. 위임 중 Space 의 기존 경로다.
- `lane: "live"` 만으로 (신규): host 가 모은 관측에서 ego backend 가
  `Ego_user_owned_name` unavailable 을 보고할 때만 허용된다. host 는 그
  worker 하나를 골라 `Issue {route = Live_route None; verb = Page_act (Control Take_over)}`
  를 보낸다. 대상 worker 가 그 상태가 아니면 현행 거부 문구를 유지한다.

worker 의 `Browser_addon_owner.issue` 는 `Live_route None` +
`Control Take_over` 조합을 현재의 "requires a selected clientId" 거부 대신,
등록된 ego 회수 훅으로 넘긴다. 훅은 `Browser_addon_live_ego.run` 이
소유권 관찰 결과와 함께 등록한다:

1. `unavailable` 이 기록한 user-owned Space ID 정확히 1개일 때 새 session 에서
   `claimTaskSpace(id)` 를 부른다. 0개면 "requires a selected clientId" 를,
   2개 이상이면 모호함을 이유로 거부한다 (이름이 겹치는 Space 목록 포함).
2. claim 성공 시 연결 주기를 다시 돌린다: `serve_space` 재실행 →
   `attach_live` → 이후 poll 로 명령을 받는다. worker 재시작은 없다.
3. 회수는 운영자가 계속하라고 말한 뒤에만 부른다. 이 동의 조건은
   `take_over` 의 현행 계약 문구("Only after the operator has said they are
   done")와 같은 자리에 둔다. ego SDK 의 안내 문구와 같은 뜻이다.

`unavailable` 기록은 Space ID 목록을 함께 운반하도록 확장한다
(`ids : int list`). 이 wire 를 읽는 곳은 worker-서버 사이와 대시보드
(browser-lane-connections 스키마) 둘 다이며, hard cut 으로 함께 갱신한다.
과거 형태의 reader 는 만들지 않는다.

## 하지 않는 것

- worker 의 주기적 재확인 루프. 소유권은 claim 외에는 저절로 돌아오지
  않으므로 폴링은 회수 없이 상태만 다시 본다. L2 의 요청 시점 회수가 같은
  일을 한 번의 호출로 한다.
- 자동 claim. 운영자 동의 없이 user 소유 Space 를 가져오는 경로는
  만들지 않는다.
- task 종료 자체의 금지. 로그인 인계 절차(skill `browser-lanes` 의
  4단계)가 권하는 회수(`take_over`)를 세션이 끝내기 전에 하는 것이 절차적
  예방이며, 이 변경은 그 절차가 놓쳤을 때의 복구를 담당한다.

## 시험

- L1: `published.unavailable` 이 issue 로 나오는 것, issue 디코드 왕복,
  TUI `issues_of_json` 소비.
- L2: host 의 라우팅 허용/거부(unavailable 없을 때 현행 거부), worker
  `issue` 의 분기(ID 0/1/2개), claim 스크립트의 영수증 판독, 회수 후
  재연결 주기. ego 라이브 앱이 필요한 끝단 동작은 배포 뒤 실측으로
  남긴다(사고 재현: probe Space 를 만들어 finish → take_over 회수).
