---
rfc: "browser-live-ego"
title: "Serve ego lite as a live browser connection"
status: Draft
created: 2026-10-22
author: vincent + claude
related: ["browser-live-one-connection", "browser-keeper-firefox", "browser-lane-stagehand"]
---

# RFC — ego lite 를 live 브라우저 연결로 쓴다

## 1. 문제

Keeper 는 로그인된 브라우저가 필요할 때 ego lite 를 쓰지 못한다.

2026-10-22 16:09 KST, `kidsnote-incoming-dd-manager` 가 Slack `#incoming-dd-web` 을 처리하다 막혔다.
`~/me/.masc/tool_calls/2026-10/22.jsonl` 에 남은 순서는 이렇다.

1. 16:09:31 stagehand 로 Slack 채널 주소에 갔다.
2. 16:09:34 읽어 보니 `workspace-signin` 화면이었다. stagehand Chromium 에는 Slack 로그인이 없다.
3. 16:09:52 `keeper_skill` 로 `ego-browser` 스킬을 열었다.
4. ego 는 한 번도 실행하지 않고 MASC 브라우저 도구로 돌아갔다. automation 은 `Firefox BiDi closed`, live 는 `no_live_client` 였다.

같은 Keeper 가 운영자에게 남긴 말도 같다. 샌드박스에서 `ego-browser` 를 부르면 `not found` 가 나오고,
"ego 를 MASC 브라우저 레인에 붙여 주면 BrowserTabs 로 바로 쓰겠다"고 했다.

이유는 실행 위치다. live 설정에서 `sandbox_profile` 을 적은 Keeper 37개가 모두 `"microvm"` 이다.
10-20 부터 10-22 까지 Keeper 의 셸 호출은 전부 microVM 안의 `Execute` 였다.
`ego-browser` 는 호스트의 `~/.local/bin` 에 있는 macOS 앱이라 microVM 에서 보이지 않는다.

지금 저장소의 ego 지원(#44283, `addons/ego-browser`)은 이 문제를 풀지 않는다.
그 README 는 "관측 레인과 호스트에서 직접 실행하는 companion 이고, `BrowserSession lane=ego` 같은 새 백엔드는 아니다"라고 정했다.
호스트에서 명령을 직접 실행하는 에이전트(Codex, 운영자 셸)만 그 companion 을 쓴다.

live 설정에도 어긋난 곳이 있다. `runtime.toml` 의 스킬 소스 `user-agents` 는
`.masc/config/skills/ego-browser-owned-20261021T030829Z-dd26ea28` 를 가리킨다.
10-21 12:08 KST 에 Codex 세션이 "심볼릭 링크라서 못 읽는다"는 degraded 경고를 없애려고 ego 의 스킬을 복사한 것이다.
그 스킬은 "브라우저가 필요하면 기본으로 ego 를 쓰라"고 안내하는데, 그 안내를 따를 수 있는 Keeper 는 없다.

## 2. 확인한 사실

2026-10-22, ego lite 0.6.0.16(Chromium 154), 이 맥에서 쟀다.

| 항목 | 값 |
|---|---|
| 작업 공간을 만들고 example.com 으로 가서 스냅샷 | 한 번 실행에 0.66 s (공간 55 ms, 이동 388 ms, 스냅샷 41 ms) |
| 같은 공간을 다시 열고 스냅샷, 끝내기 | 한 번 실행에 0.28 s |
| 작업 공간 | 실행이 끝나도 남는다. `taskSpace(id)` 로 다시 연다. `finish({keep: []})` 로 닫는다 |
| 페이지 | `p1`, `p2` 같은 라벨과 CDP `targetId`. `task.tabs()` 는 공간 안의 모든 탭과 `openedBy` 를 준다 |
| 인자 | `ego-browser nodejs` 의 Node 에는 호출한 쪽 환경 변수가 오지 않는다. 스크립트 안에 JSON 값으로 넣으면 따옴표와 `</script>` 가 섞여도 그대로 온다 |
| 출력 | `console.log` 가 stderr 로 나온다 |
| 스냅샷 | 접근성 역할로 쓴 텍스트와 `@21` 같은 ref. 머리 줄에 공간과 페이지 목록이 붙는다 |
| selector | ref, `text=`, `loc=role:…`, `loc=css:`, `xpath=`, 일반 CSS. 하나만 맞아야 한다. 대상이 화면 밖이면 스스로 스크롤한다 |
| 없는 것 | 뒤로·앞으로 가기, 탭 앞으로 가져오기는 Page API 에 없다. `page.cdp()` 로는 부를 수 있다 |
| 스크린샷 | 파일로 쓰고 경로를 돌려준다 |
| 로그인 | 공간은 브라우저 프로필의 쿠키를 같이 쓴다. 공간이 계정을 나누지는 않는다 |

## 3. 결정

ego 를 live 레인의 세 번째 연결 방식 `ego` 로 둔다. 그 연결은 browser Add-on worker 안에서 돈다.

- live 레인은 "운영자의 로그인을 가진 브라우저"다. ego 공간은 운영자 프로필의 로그인을 쓴다. 뜻이 같다.
- browser Add-on worker 는 이미 호스트 프로세스로 돌고, `[browser.live.bidi]` 의 Keeper Firefox 를 띄워 BiDi 연결로 붙인다. ego 연결도 같은 자리에서 `ego-browser nodejs` 를 부른다.
- Keeper 는 지금처럼 BrowserTabs·BrowserRead·BrowserInteract·BrowserAct·BrowserGoto 를 부른다. 샌드박스는 그대로다.
- 연결 방식마다 할 수 있는 일은 `Browser_lane.live_transport_serves` 표 한 곳에 적는다. 모든 칸을 적어야 컴파일된다.

### 다른 길

| 길 | 좋은 점 | 걸리는 점 |
|---|---|---|
| 새 작업 레인 `ego` (automation·stagehand 처럼) | 세션 열기·닫기가 작업 공간과 맞는다 | 작업 레인은 "서버가 띄운 로그인 없는 브라우저"다. 레인 이름이 늘면 선택·전송 형식·TUI·도구 enum 이 모두 바뀐다 |
| 특정 Keeper 의 샌드박스를 푼다 | 코드가 거의 없다 | 그 Keeper 가 호스트 전체와 운영자 로그인에 제한 없이 닿는다 |
| 지금 companion 을 그대로 둔다 | 할 일이 없다 | Keeper 는 계속 못 쓴다 |

## 4. 연결과 탭

- 연결 하나가 ego 작업 공간 하나다. worker 가 처음 붙을 때 `taskSpace(이름)` 으로 열거나 이어서 열고, 끝날 때 `finish({keep: []})` 로 닫는다.
- 공간 이름은 설치마다 하나다. 운영자 공간(`ownership: "user"`)은 열지 않는다. `EGO_TASK_SPACE_NAME_IN_USE` 가 오면 연결하지 않고 그 이유를 남긴다.
- 탭 번호는 연결 안에서 페이지 라벨(`p1`, `p2`)마다 한 번 정한 정수다. ego 는 라벨을 공간이 끝날 때까지 바꾸지 않고, `targetId` 는 실행 사이에 들고 다니지 말라고 한다. 라벨이 없는 탭(운영자가 그 공간에 연 탭)만 `targetId` 로 목록 번호를 받는다. 목록에서 사라진 탭의 번호는 버린다.
- 라벨이 있고 `openedBy: "agent"` 인 페이지만 이동·닫기·입력을 받는다. 라벨 없는 운영자 탭은 목록에만 나오고, 읽기도 효과 없이 거절한다. ego 문서가 그런 탭은 adopt 한 뒤에만 다루라고 해서다. BiDi 의 "이 연결이 연 탭만" 규칙과 비슷하다.

## 5. 동작

명령마다 정해진 스크립트 하나를 실행한다. Keeper 가 보낸 JS 는 받지 않는다. 인자는 JSON 값으로 스크립트에 넣는다.

| live 기능 | ego 호출 | 첫 단계 |
|---|---|---|
| `tab_listing` | `task.tabs()` | 한다 |
| `text_read`, `element_inventory`, `scene_read` | `page.evaluate` 로 `Browser_page_script`·`Browser_scene_script` 를 그대로 실행 | 한다. selector 와 `within` 이 다른 연결과 같은 뜻이 된다 |
| `viewport_capture` | `page.screenshot()` 파일을 읽어 base64, 앞뒤로 `info()` 비교 | 한다 |
| `dom_interaction` (click·fill) | `page.click(selector)`, `page.fill(selector, text)` | 한다. 스스로 스크롤한다 |
| `trusted_hover`, `trusted_keyboard` | `page.hover`, `page.press`, `keyboard.type` | 한다 |
| `tab_creation` | `task.newPage()` 뒤 `goto` | 한다 |
| `tab_navigation` | `page.goto` (agent 페이지만) | 한다 |
| `tab_closing` | `page.close()` (agent 페이지만) | 한다 |
| `tab_history` | `page.reload()` 만 API 에 있다. 뒤로·앞으로는 CDP | 다음 단계 |
| `tab_activation` | CDP `Target.activateTarget` | 다음 단계 |
| 좌표 입력, 드래그, 터치, 줌, 뷰포트 | `page.mouse` 등 | 다음 단계 |

다음 단계에서 ego 만의 읽기를 더한다. ego 스냅샷을 그대로 돌려주는 BrowserRead 모드와, BrowserInteract 가 ego ref·`loc=role:` selector 를 받게 하는 일이다. 연결 방식 표의 새 기능으로 둔다.

## 6. 실패

| 상황 | 분류 |
|---|---|
| 스크립트가 ego 에 닿기 전에 거절됨(설정 없음, 인자 오류, 운영자 탭에 입력) | 효과 없음 |
| ego 가 selector 하나를 찾지 못함, 공간이 사람에게 넘어감 | 효과 없음. ego 는 이 경우 동작하지 않는다 |
| 이동·클릭 뒤 ego 가 오류로 답함 | 그 페이지를 다시 읽는다. 읽히면 읽은 상태를 담은 부분 효과, 못 읽으면 결과 모름 |
| `ego-browser nodejs` 가 시간 안에 끝나지 않음 | 결과 모름. 연결을 끝내고 다시 붙는다 |

공간이 운영자에게 넘어갔으면(`handOff`, 운영자 조작) 다음 명령부터 효과 없음으로 거절하고 그 이유를 돌려준다.

## 7. 설정

`runtime.toml`:

```toml
[browser.live.ego]
command = "/절대/경로/ego-browser"
space = "masc"
```

- 경로는 코드에 적지 않는다. 운영자가 적는다.
- `browser-lane-setup` 은 `ego-browser --version` 이 답하는지만 확인하고 이 표를 쓴다.
- live 를 끄면(`[browser.live] enabled = false`) ego 연결도 새 명령을 받지 않는다.
- `[browser.live]` 표가 받는 키(`enabled`, `bidi`)에 `ego` 를 더한다.

## 8. 지울 것

ego 연결이 live 에서 Slack 읽기를 해낸 뒤에 지운다.

- `addons/ego-browser` (#44283 의 관측 레인과 `host.py`). 같은 일을 browser Add-on 이 한다.
- live `runtime.toml` 의 스킬 소스 `user-agents` 와 그 복사본. Keeper 에게는 MASC 브라우저 스킬이 ego 연결을 안내한다.

## 9. 검사

- 가짜 `ego-browser`: 스크립트 맨 위의 표지 주석(`// masc-ego: tabs.list` 등)을 읽고 정해진 출력을 내는 실행 파일. worker 의 연결·탭 번호·실패 분류를 이걸로 본다.
- 표 검사: `test_browser_lane` 의 연결 방식 표 검사에 `ego` 열을 더한다.
- 실제 ego: 샌드박스 밖에서 example.com 과 고정 fixture 페이지로 목록·읽기·클릭·이동·닫기를 돈다. 결과는 `docs/evidence/` 에 둔다.
- live: 운영자 승인 뒤 Keeper 가 BrowserTabs 로 ego 연결을 보고 Slack 채널 하나를 읽는다.

## 10. 순서

1. 이 RFC.
2. `Browser_lane.live_transport` 에 `Ego`, 연결 방식 표, 설정 `[browser.live.ego]`.
3. worker 의 ego 연결: 공간 열기·닫기, `tabs.list`, 읽기 세 가지, 캡처.
4. 입력: click·fill·hover·키보드, `open_tab`·`goto`·`close_tab`.
5. 실제 ego 증거와 Keeper 스킬 안내.
6. `addons/ego-browser` 와 live 스킬 소스 정리.
