---
rfc: "browser-ego-bound-space-missing"
title: "ego 연결이 묶인 Space 를 잃으면 연결을 끝내고 명시적으로만 다시 열어요"
status: Accepted
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
  (`Browser_ego_peer.script`).
- 없는 번호면 `taskSpace` 호출 자체가 던져요. 2026-11-04 로컬 ego lite 0.6.2.5 에서
  `taskSpace(987654)` 가 `task space not found: 987654` 를 던졌고, 오류에 `code` 는
  없었어요. ego 문서에 적힌 오류 코드도 `EGO_TASK_SPACE_NAME_IN_USE` 와
  `EGO_PAGE_UNRESPONSIVE` 뿐이에요.
- 스크립트 머리(`Browser_ego_peer.frame`)의 `catch` 는 무엇이 던졌든
  `{ok:false, error}` 하나로 답해요. 그래서 peer 는 `taskSpace` 자체가 실패했는지,
  그 뒤의 페이지 단계가 실패했는지 구분하지 못해요. 둘 다 "효과 모름"으로 답해요.
- Space 가 목록에 있는지는 `space_status` 를 부를 때만 확인해요
  (`Browser_ego_peer.space_status`). 결과는 `Present | Missing | Unknown` 이고,
  `Missing` 이면 "no replacement was opened" 로 답하고 끝나요. 새 Space 를 몰래
  열지 않는 것은 의도예요.
- 자동 선택은 상태가 `Missing` 이나 `Unknown` 인 ego 연결을 이미 고르지 않아요
  (`Browser_selection`). 그런데 그 상태는 `space_status` 에서만 바뀌어서, 위 사건들
  에서는 계속 `Present` 였어요.
- Space 는 번호로 가려요. `space_status` 는 이름이 바뀐 Space 도 같은 Space 로 보고
  이름만 새로 읽어요(`test_native_space_status`).
- 사용자 소유 Space 거절에는 이미 길이 있어요(`Browser_addon_live_ego` 의 `loop`).
  연결을 끝내고, `Browser_addon_observation.Ego_user_owned_name` 으로 거절을
  공개하고, clientId 없는 `take_over` 가 되찾으면 다시 연결해요. 사라진 Space 에는
  이 길이 없어요.
- 다시 연결할 때는 설정의 Space 참조로 열어요. `Named_space` 면
  `taskSpace(<이름>)` 이 그 이름의 Space 를 이어 붙이거나 새로 만들고,
  `Existing_space` 면 그 번호만 열어요.
- 일반 `BrowserTabs` 가 브라우저를 고르지 못하면 답에 `error` 와 `clients` 만 실어요
  (`Browser_addon_host.selection_detail`). 사용자 소유 거절 기록은
  `BrowserTabs {mode:"connections"}` 의 `inventoryIssues` 와 대시보드에만 나와요.

## 3. 결정 (운영자, 2026-11-04)

- 사라진 Space 를 자동으로 다시 열지 않아요. 명시적으로 되찾을 때만 다시 열어요.
  운영자가 일부러 Space 를 닫았을 때 그 결정을 덮어쓰지 않기 위해서예요.
- 되찾기는 지금의 사용자 소유 되찾기와 같은 동작(clientId 없는 `take_over`)으로 해요.
- 부를 수 있는 쪽도 같아요(Keeper·운영자).
- 기록은 사용자 소유 거절과 같은 자리에만 실어요. 일반 `BrowserTabs` 답은 바꾸지 않아요.
- 오류 문구를 비교해서 사라짐을 판정하지 않아요.

## 4. 설계

### 4.1 알아채기

1. 묶인 Space 로 여는 스크립트(`Browser_ego_peer.script`)는 `taskSpace(<번호>)` 를
   따로 감싸요. 이 호출이 던지면 답에 `spaceOpen: "failed"` 를 실어요. 문구가 아니라
   던진 위치로 구분해요. 본문은 돌지 않아요.
2. peer 는 이 답을 받으면 `listTaskSpaces()` 로 목록을 한 번 읽어요.
   `space_status` 와 같은 관측이고, 읽기 창은 `Tabs_list` 의 것을 써요.
   - `Present`: 연결의 Space 상태를 새로 남기고, 원래 오류를 돌려줘요.
   - `Missing`: 연결의 Space 상태를 `Missing` 으로 남기고, "묶인 Space 가 없어졌고
     새 Space 는 열지 않았다"로 답해요.
   - 목록이 답하지 않았거나 애매함(`Unknown`): 연결의 Space 상태는 그대로 두고, 원래
     오류 뒤에 왜 판단하지 못했는지를 붙여요. `Unknown` 으로 덮으면 그 연결이 자동
     선택에서 계속 빠져서, 1장과 같은 모양의 결함이 다시 생겨요.
3. 세 경우 모두 효과 전 실패예요. `taskSpace` 가 던졌으면 본문은 돌지 않았어요.
4. Space 는 지금처럼 번호로만 가려요. 이름은 비교하지 않아요.

이 층만으로도 `Missing` 인 연결은 자동 선택에서 빠져요(2장).

### 4.2 사라졌을 때

1. 명령의 답을 보낸 뒤, 연결 상태가 `Missing` 이면 worker 가 연결 cycle 을 끝내요.
   `taskSpace` 실패로 알았든 `space_status` 로 알았든 같아요.
   순서는 되찾기 hook 연결 → 기록 공개 → 연결 끊기예요. 기록을 본 쪽이 바로
   `take_over` 를 불러도 hook 이 있고, 연결이 이유 없이 사라진 것처럼 보이는 틈이
   없어요.
2. worker 는 `Browser_addon_observation.unavailable` 의 새 경우
   `Ego_space_missing { space; space_id; observed_at }` 를 공개해요. `space` 는 이름이에요.
3. 기록은 사용자 소유 거절과 같은 연결 목록(`Browser_connection_inventory` 의
   `issues`)에 들어가요. 이 기록은 목록을 불완전하게 만들지 않아요. 같은 worker 의
   다른 연결은 그대로 고를 수 있어요.
4. Missing 답 문구에 "clientId 없는 `take_over` 가 설정의 Space 를 다시 연다"를 더해요.

### 4.3 되찾기

1. clientId 없는 `take_over` 는 지금처럼 기록을 공개한 worker 로 가요.
2. worker 는 설정의 Space 참조를 봐요.
   - `Named_space`: 기록을 지우고 다시 연결을 시작해요. 답은
     `{action:"take_over", spaceName, reopening:true}` 예요. 사용자 소유 되찾기처럼
     연결은 답 뒤에 이어져요. 새 번호와 clientId 는 `BrowserTabs` 에서 보여요.
     이전 탭은 없어요.
   - `Existing_space`: 그 번호는 없으므로 거절해요. 기록은 남아요. 운영자가 설정을
     바꿔야 해요.
3. 같은 이름의 사용자 소유 Space 가 있으면, 다시 연결하는 cycle 이 지금처럼
   사용자 소유 거절로 끝나요.

## 5. 하지 않는 것

- 목록을 주기적으로 읽지 않아요. `taskSpace` 가 실패한 명령이 있을 때만 읽어요.
- 자동으로 다시 열지 않아요.
- 일반 `BrowserTabs` 답에 기록을 싣지 않아요.
- Goal 별 Space 와 그 라우팅은 RFC-browser-ego-goal-spaces 의 범위예요.
- 무엇이 ego 안에서 Space 를 닫는지는 이 RFC 에서 조사하지 않아요.

## 6. 대가

- Space 가 사라질 때마다, 되찾기 전까지 그 연결로는 브라우저가 없어요. 지금도
  사실상 없는 상태라서 달라지는 건 "보이지 않게 실패"가 "보이게 없음"이 되는 거예요.
- 되찾기 한 번이 필요해요. 1장의 사건마다 Keeper 1~3명이 실패한 호출은 1~11번이었어요.
- 운영자가 일부러 닫은 Space 도 Keeper 가 `take_over` 로 다시 열 수 있어요. 지금의
  사용자 소유 되찾기와 같은 권한이에요.
- `take_over` 의 답은 다시 연결된 것을 증명하지 않아요. 결과는 `BrowserTabs` 로 봐요.
- `taskSpace` 가 실패한 명령마다 목록을 한 번 더 읽어요. `Missing` 이면 cycle 이
  끝나므로 사라진 Space 하나에 한 번이에요.

## 7. 미해결

- ego 가 Space 를 닫는 원인.
- ego 앱이 다시 시작된 뒤 번호가 다시 쓰이는 경우. RFC-browser-ego-goal-spaces 가
  10-30 에 번호가 8 로 돌아간 것을 관측했어요. 묶인 번호가 다른 Space 에 쓰이면
  `taskSpace(<번호>)` 가 성공하므로 이 RFC 의 방법으로는 알아채지 못해요.

## 8. 검증

- `test_browser_ego_peer`:
  - 스크립트를 node 에서 돌려 `taskSpace` 가 던지면 `spaceOpen:"failed"` 답 하나만
    나오고 본문이 돌지 않는지.
  - 가짜 runner 로 목록이 `Missing` 이면 효과 전 실패와 Space 상태 `Missing`,
    `Present`·`Unknown` 이면 원래 오류가 효과 전 실패로 나오는지.
- `test_browser_addon_live_ego`: 사라짐 → cycle 끝 → `Ego_space_missing` 공개 →
  `take_over` → 이름으로 다시 연결. `Existing_space` 는 거절. 사용자 소유 시나리오와
  같은 틀이에요.
- 기록과 연결 목록 항목의 JSON 왕복.
- 배포 뒤 측정: 사라짐 사건마다 실패 호출 수, 되찾기까지 걸린 시간, `take_over` 호출 수.
  기준은 1장의 표예요(`tool_calls` 집계).
