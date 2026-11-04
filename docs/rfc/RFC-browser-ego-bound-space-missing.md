---
rfc: "browser-ego-bound-space-missing"
title: "ego 연결이 묶인 Space 를 잃으면 연결을 끝내고 명시적으로만 다시 열어요"
status: Draft
created: 2026-11-04
updated: 2026-11-04
author: vincent
related: ["browser-ego-goal-spaces"]
---

# RFC — ego 연결이 묶인 Space 를 잃으면

이슈 #48095.

## 1. 문제

ego 앱 안에서 연결이 묶인 Space 가 사라지면, 그 연결로 가는 명령이 모두
`task space not found: <번호>` 로 실패해요. 연결은 끝나지 않고, Keeper 에게는
살아 있는 브라우저로 계속 보여요. 되찾을 길이 없어서 서버를 다시 시작할 때까지
그 연결로는 브라우저를 쓸 수 없어요.

10-30 이후 `<base-path>/.masc/tool_calls`(실측 `/Users/dancer/me/.masc/tool_calls/2026-1{0,1}/*.jsonl`,
2026-11-04 에 집계)의 브라우저 도구 기록이에요.

| Space | 실패 호출 | 기간(UTC) | Keeper 수 |
|---|---|---|---|
| 123 | 3 | 10-30 00:22 → 01:32 | 2 |
| 8 | 3 | 10-30 06:41 → 06:42 | 2 |
| 12 | 3 | 10-30 09:21 → 09:41 | 3 |
| 20 | 3 | 10-30 11:49 → 12:16 | 2 |
| 3 | 1 | 11-01 01:11 | 1 |
| 1 | 11 | 11-03 05:13 → 06:00 | 3 |

- 11-03 건은 06:00Z 뒤로 Keeper 들이 그 연결을 쓰지 않았어요. 서버가 07:09Z 에
  재시작할 때까지 약 2시간 동안 연결이 그대로 남았어요.
- 사라지기 직전 Keeper 의 `finish_space` 호출은 없었어요. 무엇이 Space 를 닫는지는
  RFC-browser-ego-goal-spaces §1 처럼 아직 모르는 상태예요.

## 2. 확인한 사실

- 명령 스크립트는 처음 연 Space 의 번호로 `taskSpace(<번호>)` 를 불러요
  (`Browser_ego_peer.script`). Space 가 없으면 ego 가 오류 문구만 돌려줘요.
  ego lite 0.6.2.5 문서에 적힌 오류 코드는 `EGO_TASK_SPACE_NAME_IN_USE` 와
  `EGO_PAGE_UNRESPONSIVE` 뿐이에요.
- 스크립트 머리(`Browser_ego_peer.frame`)의 `catch` 는 무엇이 던졌든
  `{ok:false, error}` 하나로 답해요. 그래서 peer 는 `taskSpace` 자체가 실패했는지,
  그 뒤의 페이지 단계가 실패했는지 구분하지 못해요.
- Space 가 목록에 있는지는 `space_status` 를 부를 때만 확인해요
  (`Browser_ego_peer.space_status`). 결과는 `Present | Missing | Unknown` 이고,
  `Missing` 이면 "no replacement was opened" 로 답하고 끝나요. 새 Space 를 몰래
  열지 않는 것은 의도예요.
- 목록 확인은 번호만 비교해요(`Browser_ego_space_observation.inventory`). ego 앱이
  다시 시작된 뒤 같은 번호가 다른 Space 에 쓰이면 `Present` 로 볼 수 있어요.
  RFC-browser-ego-goal-spaces 가 10-30 에 번호가 8 로 돌아간 것을 관측했어요.
- 사용자 소유 Space 거절에는 이미 길이 있어요(`Browser_addon_live_ego` 의 `loop`).
  연결을 끝내고, `Browser_addon_observation.Ego_user_owned_name` 으로 거절을
  공개하고, clientId 없는 `take_over` 가 되찾으면 다시 연결해요. 사라진 Space 에는
  이 길이 없어요.
- 다시 연결할 때는 설정의 Space 참조로 열어요. `Named_space` 면
  `taskSpace(<이름>)` 이 그 이름의 Space 를 이어 붙이거나 새로 만들고,
  `Existing_space` 면 그 번호만 열어요.

## 3. 결정

- 사라진 Space 를 자동으로 다시 열지 않아요. 명시적으로 되찾을 때만 다시 열어요
  (운영자 결정, 2026-11-04). 운영자가 일부러 Space 를 닫았을 때 그 결정을 덮어쓰지
  않기 위해서예요.
- 오류 문구를 비교해서 사라짐을 판정하지 않아요.

## 4. 설계

### 4.1 알아채기

1. 스크립트 머리가 `taskSpace(<번호>)` 를 따로 열어요. 이 호출이 던지면 답에
   `spaceOpen: "failed"` 를 실어요. 문구가 아니라 던진 위치로 구분해요.
2. peer 는 `spaceOpen: "failed"` 를 받으면 `listTaskSpaces()` 로 목록을 한 번 읽어요.
   - `Present`: Space 는 있어요. 원래 실패를 그대로 돌려줘요. 연결은 유지해요.
   - `Unknown`: 원래 실패를 돌려주고, 모름을 관측에 공개해요. 연결은 유지해요.
   - `Missing`: 4.2 로 가요.
3. 목록 확인은 번호와 이름이 둘 다 맞아야 `Present` 예요. 같은 번호인데 이름이
   다르면 원래 Space 가 아니므로 `Missing` 이에요. 비교할 이름은 연결이 처음
   관측한 이름이에요.

### 4.2 사라졌을 때

1. 그 명령은 효과 전 실패로 답해요. 내용은 "묶인 Space(번호·이름)가 없어졌고,
   새 Space 는 열지 않았고, clientId 없는 `take_over` 가 다시 연다"예요.
2. 연결 cycle 을 끝내요. worker 는 `Browser_addon_observation.unavailable` 에 새 경우
   `Ego_space_missing { space; space_id; observed_at }` 를 더해 공개해요.
3. 기록은 사용자 소유 거절과 같은 연결 목록(`Browser_connection_inventory` 의
   `issues`)에 들어가요. Keeper 는 `BrowserTabs` 에 `mode: "connections"` 를 줘서
   읽고, 대시보드도 같은 목록을 보여줘요.

### 4.3 되찾기

1. clientId 없는 `take_over` 가 사라진 Space 도 다시 열어요. worker 는 설정의 Space
   참조로 다시 연결해요.
   - `Named_space`: 같은 이름으로 열어요. 번호와 clientId 는 새것이고, 이전 탭은 없어요.
   - `Existing_space`: 그 번호는 없으므로 거절하고, 운영자가 설정을 바꿔야 한다고 답해요.
2. 부를 수 있는 쪽은 지금의 사용자 소유 되찾기와 같아요(Keeper·운영자).

## 5. 하지 않는 것

- 목록을 주기적으로 읽지 않아요. `taskSpace` 가 실패한 명령이 있을 때만 읽어요.
- 자동으로 다시 열지 않아요.
- Goal 별 Space 와 그 라우팅은 RFC-browser-ego-goal-spaces 의 범위예요.
- 무엇이 ego 안에서 Space 를 닫는지는 이 RFC 에서 조사하지 않아요.

## 6. 대가

- Space 가 사라질 때마다, 되찾기 전까지 그 연결로는 브라우저가 없어요. 지금도
  사실상 없는 상태라서 달라지는 건 "보이지 않게 실패"가 "보이게 없음"이 되는 거예요.
- 되찾기 한 번이 필요해요. 1장의 사건마다 Keeper 1~3명이 실패한 호출은 1~11번이었어요.
- 운영자가 일부러 닫은 Space 도 Keeper 가 `take_over` 로 다시 열 수 있어요. 지금의
  사용자 소유 되찾기와 같은 권한이에요. 운영자만 열게 할지는 7장에 남겨요.
- `taskSpace` 가 실패한 명령마다 목록을 한 번 더 읽어요.

## 7. 미해결

- 되찾기를 `take_over` 로 할지, 새 동작(예: `reopen_space`)으로 나눌지. `take_over` 는
  "운영자에게서 되찾는다"는 뜻이라, 사라진 Space 를 다시 여는 일과 이름이 맞지 않아요.
- 다시 여는 권한을 운영자에게만 둘지.
- 연결이 없어진 뒤 일반 `BrowserTabs` 답에도 이 기록을 실을지. 지금 사용자 소유
  거절은 `mode: "connections"` 의 연결 목록에서 보여요. 일반 `BrowserTabs` 답에도
  실리는지는 확인하지 않았어요.
- ego 가 Space 를 닫는 원인.

## 8. 검증

- `test_browser_ego_peer`: 가짜 runner 로 `taskSpace` 실패 → 목록 `Missing` 이면 효과 전
  실패와 cycle 끝 신호, `Present`·`Unknown` 이면 원래 실패를 그대로 돌려주는지.
- `Browser_ego_space_observation`: 같은 번호 다른 이름이 `Missing` 인지.
- `test_browser_addon_live_ego`: 사라짐 → cycle 끝 → `Ego_space_missing` 공개 →
  `take_over` → 다시 연결. 사용자 소유 시나리오와 같은 틀이에요.
- 배포 뒤 측정: 사라짐 사건마다 실패 호출 수, 되찾기까지 걸린 시간, `take_over` 호출 수.
  기준은 1장의 표예요(`tool_calls` 집계).
