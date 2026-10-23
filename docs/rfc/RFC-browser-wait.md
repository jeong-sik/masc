---
rfc: "browser-wait"
title: "Let a Keeper wait for a page condition on every browser connection"
status: Draft
created: 2026-10-23
author: vincent + claude
related: ["browser-live-ego", "browser-live-one-connection"]
---

# RFC — 브라우저 연결 모두에서 페이지 조건을 기다린다

## 1. 문제

masc 브라우저 도구에는 기다리는 동작이 없다. Keeper 는 무언가를 누른 뒤 화면이 바뀌기를 바랄 때 같은 탭을 다시 읽는다.

2026-10-16 부터 10-23 11:40Z 까지 Keeper raw trace(`~/me/.masc/keepers/*/raw-traces`, `tool_execution_started`)를 셌다. 스크립트와 결과는 `docs/evidence/2026-10-23-browser-wait/` 에 있다.

- 브라우저 도구를 부른 Keeper 는 12개, 호출은 1000번이다. 그중 읽기(`BrowserRead`, `BrowserTabs`)가 564번이다.
- 같은 탭을 같은 mode 로, 다른 브라우저 호출 없이 60초 안에 거듭 읽은 묶음이 54개다. 길이별로 2번 36개, 3번 15개, 4번 2개, 5번 1개다. 첫 읽기 뒤에 덧붙은 읽기는 76번이다.
- 76번 중 52번이 `kidsnote-incoming-dd-manager` 다. 10-23 의 예는 이렇다.
  - Slack 에서 `press_key` 를 누른 뒤 3.9초, 3.4초 간격으로 text 를 두 번 읽었다.
  - "Reply in thread" 를 누른 뒤 5초 뒤에 elements 를 읽었다.
  - 반응 버튼에 `hover_at` 한 뒤 4.6초, 6.4초 간격으로 선택자를 바꿔 가며 elements 를 읽었다.
- 셸 `sleep` 으로 브라우저를 기다린 경우는 없었다.

덧붙은 읽기 76번은 호출의 약 7.6% 다. 큰 비용은 아니다. 다만 Keeper 는 "바뀌었나"를 읽어서 확인하니 매번 페이지 전체를 받는다. 언제까지 기다릴지도 Keeper 가 정한다. 다시 읽는 간격(2~14초)은 모델이 답을 만드는 시간에 따라 정해진다.

ego lite 는 `page.waitForURL()`·`waitForSelector()`·`waitForFunction()` 을 준다(안내서 v2.1.0). 이슈 #45284 21번이 이것을 쓰자고 했다. 다른 연결에도 같은 동작이 있어야 Keeper 가 연결마다 다르게 배우지 않는다.

## 2. 지금 있는 것

| 무엇 | 어디 | 기다리는 것 |
|---|---|---|
| `BrowserGoto` | 모든 연결 | 각 연결의 이동 명령이 돌아올 때까지 |
| ego snapshot 대상 입력 | `Browser_ego_peer.target_input` | 대상이 붙을 때까지 2초(`target_wait_ms`) 기다린 뒤, 정확히 하나가 아니면 효과 전에 거절한다 |
| ego 다운로드 | `Browser_ego_peer` | 페이지 단계마다 `waitForEvent("download")` 를 걸어 둔다 |
| 명령의 응답 시간 | `Browser_lane.reply_timeout_sec` | 읽기·입력은 20초, 이동은 45초, `BrowserAct` 는 60초다. ego peer 는 여기서 2초를 뺀 시간 안에 끝내야 한다 |

Keeper 가 조건을 주고 기다리는 도구는 없다.

## 3. 지켜야 할 것

1. **임의 스크립트를 받지 않는다.** 브라우저 도구는 임의 스크립트를 받지 않는다(`docs/design/browser-lane.md`). 그래서 `waitForFunction` 은 이 RFC 에 넣지 않는다. 조건은 닫힌 합 타입으로 받는다.
2. **기다리기는 읽기다.** 효과가 없어서 다시 불러도 된다. 그래서 읽기를 받는 페이지(ego 에서는 그 공간이 관리하는 페이지)에서 받는다.
3. **응답 시간 안에 끝난다.** 기다리는 시간의 상한을 정하고, 그 명령의 응답 시간을 그만큼 늘린다. 상한을 넘는 요청은 효과 전에 거절한다.
4. **시간이 다 된 것은 실패가 아니다.** "N 밀리초 안에 조건이 맞지 않았다"는 답이다. 타입으로 나눈다.
5. **연결 하나가 한 번에 명령 하나를 한다.** ego 연결은 Node 프로세스 하나가 명령을 차례로 한다(#45485). 기다리는 동안 그 연결의 다른 명령은 줄을 선다. 상한이 짧아야 하는 이유다.
6. **이동을 건너도 조건을 본다.** 링크를 누른 뒤 URL 을 기다리면 문서가 바뀐다. 페이지 안에서 도는 스크립트 하나로는 이동을 넘지 못한다.

## 4. 조건

```ocaml
type selector_state = Attached | Visible | Hidden | Detached

type condition =
  | Url_is of string            (* 문서 URL 이 정확히 같다 *)
  | Url_starts_with of string   (* 문서 URL 이 이 글로 시작한다 *)
  | Selector of { selector : string; state : selector_state }
  | Text_appears of string      (* 보이는 글에 이 글이 있다 *)
  | Target of Browser_lane.snapshot_target  (* ego 만: ref·role·text 대상이 하나 붙는다 *)
```

- `Hidden` 과 `Detached` 는 "없어질 때까지"다. 로딩 표시가 사라지기를 기다릴 때 쓴다.
- `Text_appears` 는 대소문자를 그대로 비교한다. 부분 일치다.
- 조건 여러 개를 묶는 `all`·`any` 는 넣지 않는다. 필요하면 다음에 정한다.
- wire 는 `until: {url}`, `{urlPrefix}`, `{selector, state}`, `{text}`, `{target}` 중 하나와 `timeoutMs` 다.

답은 이렇다.

```json
{"tabId": 3, "met": true, "waitedMs": 840, "url": "https://app.slack.com/...", "title": "..."}
{"tabId": 3, "met": false, "waitedMs": 5000, "url": "...", "title": "..."}
```

`met: false` 는 효과 없는 정상 답이다. 탭이 닫히거나 대화상자에 막히면 지금의 읽기처럼 거절한다.

## 5. 후보

### A. 읽기 하나로 기다린다

`BrowserRead mode=wait` 에 `until` 과 `timeoutMs` 를 준다. live 능력 `Page_wait` 를 새로 둔다.

| 연결 | 하는 방법 |
|---|---|
| ego | `waitForURL`·`waitForSelector({state})`·대상 locator 의 `waitForSelector`. 글은 `text=` locator. Node 실행 하나 |
| BiDi, 자동화 Firefox, 확장, Stagehand | peer 가 짧은 페이지 읽기(URL, 선택자 상태, 글 찾기)를 250ms 마다 되풀이한다. 매번 새 스크립트라 이동을 넘는다. 읽기 스크립트는 지금의 `Browser_page_script` 를 쓴다 |

- 좋은 점: 효과가 없어서 다시 불러도 된다. 연결마다 뜻이 같다. 도구 하나에 mode 하나만 는다.
- 나쁜 점: 누르기와 기다리기 사이에 호출이 하나 더 든다. 그 사이에 잠깐 떴다 사라지는 것(토스트)은 놓칠 수 있다.

### B. 효과 뒤에 기다린다

`BrowserInteract`·`BrowserAct`·`BrowserGoto` 에 `waitUntil` 을 붙인다. 효과를 낸 같은 실행에서 기다리고, 영수증에 `waited: {met, waitedMs}` 를 싣는다.

- 좋은 점: 호출이 하나 준다. 효과 바로 뒤부터 보니 잠깐 뜬 것도 덜 놓친다. ego 안내서도 행동과 기다리기를 한 실행에 두라고 한다.
- 나쁜 점: 효과가 난 뒤의 실패와 "아직 안 맞음"을 한 답에 섞는다. 기다리다 연결이 끊기면 효과는 났는데 결과를 모른다. 도구 셋의 스키마와 각 연결의 효과 경로를 다 바꾼다.

### C. A 를 먼저 하고, 같은 조건 타입으로 B 를 나중에 한다

## 6. 권고

C 를 권한다. A 로 조건 타입과 연결별 구현을 먼저 굳힌다. 그 뒤 B 가 필요한지는 A 를 쓴 기록(`mode=wait` 바로 앞이 효과인 비율, `met: false` 비율)으로 정한다.

상한은 10초로 시작한다. `Page_wait` 의 응답 시간은 `timeoutMs` 에 읽기 응답 시간(20초)을 더한 값으로 한다. 10초면 ego 연결의 다른 명령이 최대 10초 줄을 선다.

## 7. 검증

- 조건 파서: wire 왕복, 둘 이상 주기·없음·빈 글·상한 초과를 효과 전에 거절.
- 연결마다: 이미 맞은 조건은 곧바로 `met: true`, 나중에 맞는 조건(타이머로 바꾸는 fixture), 끝내 안 맞는 조건은 `met: false` 와 `waitedMs ≥ timeoutMs`, 링크를 눌러 이동하는 동안의 `Url_is`.
- 실제 브라우저: ego lite, 자동화 Firefox, live BiDi 에서 같은 fixture. 결과를 PR 본문에 적는다.
- 기록: A 를 넣은 뒤 이 RFC 의 1절과 같은 방법으로 다시 센다. 같은 탭을 거듭 읽은 묶음이 줄었는지 본다.

## 8. 정할 것

1. 후보: C(권고), A 만, B 만.
2. 상한: 10초로 시작해도 되는지.
3. 운영자 브라우저(확장, live BiDi)에서도 받을지. 읽기라서 받는 것이 지금 규칙과 맞다.

## 9. 넣지 않는 것

- `waitForFunction` 같은 임의 스크립트 조건.
- 네트워크가 조용해질 때까지 기다리기. 연결마다 볼 수 있는 것이 다르다.
- 프레임 안 조건. ego 는 locator 가 프레임까지 찾지만, 다른 연결은 `framePath` 가 필요하다. A 를 넣은 뒤 정한다.
