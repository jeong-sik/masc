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

## 2. 확인한 사실

2026-10-22, ego lite 0.6.0.16(Chromium 154), 이 맥에서 쟀다.

| 항목 | 값 |
|---|---|
| 작업 공간을 만들고 example.com 으로 가서 스냅샷 | 한 번 실행에 0.66 s (공간 55 ms, 이동 388 ms, 스냅샷 41 ms) |
| 같은 공간을 다시 열고 스냅샷, 끝내기 | 한 번 실행에 0.28 s |
| 작업 공간 | 실행이 끝나도 남는다. `taskSpace(id)` 로 다시 연다. `finish({keep: []})` 로 닫는다 |
| 페이지 | `p1`, `p2` 같은 라벨과 CDP `targetId`. `task.tabs()` 는 공간 안의 모든 탭과 `openedBy` 를 준다 |
| 인자 | `ego-browser nodejs` 의 Node 에는 호출한 쪽 환경 변수가 오지 않는다. 스크립트 안에 JSON 값으로 넣으면 따옴표와 `</script>` 가 섞여도 그대로 온다 |
| 출력 | `console.log` 가 stderr 로 나온다. 프로세스가 끝날 때 한꺼번에 나오고(2026-10-23, 3 초 간격으로 쓴 두 줄이 끝에 같이 왔다), `console.log` 는 바꿀 수 없다 |
| 대화상자 | SDK 가 대화상자 상태를 프로세스마다 따로 든다. 대화상자를 연 실행이 끝나도 대화상자는 남고, 그 뒤의 실행은 그 페이지에 닿는 모든 호출(`page.info`, `page.events`, `page.cdp`)이 시간 초과다(2026-10-23, 0.6.0.16). ego-lite 의 `docs/native-javascript-dialog-requirement.md` 가 이것을 아직 못 맞춘 요구로 적었다 |
| 스냅샷 | 접근성 역할로 쓴 텍스트와 `@21` 같은 ref. 머리 줄에 공간과 페이지 목록이 붙는다 |
| selector | ref, `text=`, `loc=role:…`, `loc=css:`, `xpath=`, 일반 CSS. 하나만 맞아야 한다. 대상이 화면 밖이면 스스로 스크롤한다 |
| 없는 것 | 뒤로·앞으로 가기, 탭 앞으로 가져오기는 Page API 에 없다. `page.cdp()` 로는 부를 수 있다 |
| 스크린샷 | 파일로 쓰고 경로를 돌려준다 |
| 업로드 | `page.setInputFiles(selector, paths)` 는 CSS 선택자(`loc=css:` 도), 여러 파일, 숨은 입력에 된다. 파일이 아닌 입력은 TypeError 로 거절한다. 그 오류 문구는 라벨과 파일 입력이 든 컨테이너도 받는다고 하고, 파일 입력이 셋인 `body` 는 거절했다. 없는 경로는 말없이 0 바이트 파일로 넣는다. 파일은 페이지가 읽을 때 읽는다: 넣은 뒤 원본을 지우면 페이지의 `file.text()` 가 NotFoundError 였다(2026-10-23, 0.6.0.16) |
| 프레임 | 기본 viewport snapshot 에 같은 출처와 다른 출처(127.0.0.1 위의 localhost) iframe 의 내용이 ref 와 함께 들어 있다. `{scope: "subtree", root: "@<iframe ref>"}` 는 그 프레임만 읽는다. 그 ref 로 `page.click`·`page.fill` 하면 프레임 안에서 된다. role·글자 locator 는 최상위 문서에 맞는 것이 없으면 프레임까지 찾아서, 다른 출처 프레임에서도 fill·click 이 됐다. snapshot 을 먼저 찍지 않고 ref 를 쓰면 `Unknown ref: 3; take a new snapshot` 으로 거절한다(2026-10-23, 0.6.0.16) |
| 파일 선택 창 | 클릭할 때 입력을 만드는 페이지는 `page.waitForFileChooser({timeout})` 을 먼저 걸고 클릭한 뒤 `chooser.setFiles(paths)` 로 채운다. 선택 창에는 `isMultiple()` 과 `setFiles()` 가 있다. 로컬 fixture 에서 두 파일이 `report.txt/19, a.html/60` 으로 페이지의 change 처리에 닿았다. 선택 창이 뜨지 않으면 `page.waitForFileChooser timed out after <ms>ms` 로 끝난다. `setFiles` 의 답에 업로드가 연 대화상자가 `dialog` 로 올 수 있다(안내서 v2.1.0). 선택 창을 답하지 않고 두면 같은 Node 프로세스의 다음 선택 창 대기와 클릭이 `this Page is already waiting for a file chooser` 로 막힌다. 새 프로세스는 막히지 않는다. `setFiles([])` 는 선택 창을 닫고 페이지에 change 를 보내지 않으며, 그 뒤 업로드는 된다. 선택 창이 안 떠서 시간이 다 된 대기는 아무것도 남기지 않는다(2026-10-23, 0.6.0.16) |
| 다운로드 | agent 작업 공간의 다운로드는 시작 전에 걸어 둔 `page.waitForEvent("download")` 로만 받는다. `saveAs(경로)` 는 복사본(링크 1개, 다른 inode)을 만들고 없는 상위 폴더도 만든다. ego 의 임시 파일은 시스템 임시 폴더(`ego-browser-download-*`)에 생긴다. 다운로드하는 동안 운영자의 `~/Downloads` 폴더의 수정 시각이 바뀌고(이동만 할 때는 그대로였다) 끝난 뒤 남는 것은 없었다. `delete()` 는 ego 의 임시 파일만 지운다. `timeout: 0` 은 거절하고 2147483647 ms 는 받는다. 닫힌 페이지의 대기는 "No target with given id found" 로 끝난다(2026-10-23, 0.6.0.16, Node v24.21.0) |
| 로그인 | 공간은 브라우저 프로필의 쿠키를 같이 쓴다. 공간이 계정을 나누지는 않는다 |
| 넘기기 | `task.handOff()` 는 바로 돌아오고, `listTaskSpaces()` 의 소유가 `agentDelegatedToUser` 가 된다. 그 뒤 그 공간의 호출(`tabs()`, `page.url()`, 다시 `handOff()`)은 모두 `error_code: "EGO_TASK_SPACE_USER_IN_CONTROL"` 로 실패한다. `taskSpace(id)` 로 다시 연 핸들의 `ownership` 도 `agentDelegatedToUser` 다. ego 화면에는 넘긴 공간을 돌려주는 버튼이 없다(운영자가 확인). `takeOverTaskSpace(id)` 는 운영자 동작 없이 바로 성공하고, `userPage()` 가 그때 활성이던 탭을 준다. `waitForControl` 은 시간이 다 될 때까지 기다리다 실패한다(2026-10-23) |

## 3. 결정

ego 를 live 레인의 세 번째 연결 방식 `ego` 로 둔다. 그 연결은 browser Add-on worker 안에서 돈다.

- live 레인은 "운영자의 로그인을 가진 브라우저"다. ego 공간은 운영자 프로필의 로그인을 쓴다. 뜻이 같다.
- browser Add-on worker 는 이미 호스트 프로세스로 돌고, `[browser.live.bidi]` 의 Keeper Firefox 를 띄워 BiDi 연결로 붙인다. ego 연결도 같은 자리에서 `ego-browser nodejs` 를 부른다.
- Keeper 는 지금처럼 BrowserTabs·BrowserRead·BrowserInteract·BrowserAct·BrowserGoto 를 부른다. 샌드박스는 그대로다.
- 연결 방식마다 할 수 있는 일은 `Browser_lane.live_transport_serves` 표 한 곳에 적는다. 모든 칸을 적어야 컴파일된다.
- live 는 운영자와 같은 신뢰 수준이다. ego 연결에 따로 허용 목록을 두지 않는다. browser 도구를 부를 수 있는 Keeper 는 BiDi·확장 연결처럼 이 연결도 쓴다. 공간이 운영자 프로필의 로그인을 그대로 쓰므로, 그 Keeper 는 운영자가 로그인한 사이트 모두에 닿는다.
- 이동은 절대 http(s) 주소만 받는다. loopback 과 사설 주소는 BiDi 연결처럼 막지 않는다.

### 다른 길

| 길 | 좋은 점 | 걸리는 점 |
|---|---|---|
| 새 작업 레인 `ego` (automation·stagehand 처럼) | 세션 열기·닫기가 작업 공간과 맞는다 | 작업 레인은 "서버가 띄운 로그인 없는 브라우저"다. 레인 이름이 늘면 선택·전송 형식·TUI·도구 enum 이 모두 바뀐다 |
| 특정 Keeper 의 샌드박스를 푼다 | 코드가 거의 없다 | 그 Keeper 가 호스트 전체와 운영자 로그인에 제한 없이 닿는다 |

## 4. 연결과 탭

- 연결 하나가 ego 작업 공간 하나다. worker 가 처음 붙을 때 `taskSpace(이름)` 또는 고정된 숫자 ID로 열거나 이어서 연다. 연결 종료는 작업 완료가 아니다. 성공한 작업은 명시적인 `finish_space`로 완료한다.
- 공간 이름은 설치마다 하나다. 운영자 공간(`ownership: "user"`)은 열지 않는다. 운영자에게 넘긴 공간(`agentDelegatedToUser`)은 연다. 넘긴 채로 서버가 다시 시작해도 `take_over` 로 되찾아야 해서다(5절). `EGO_TASK_SPACE_NAME_IN_USE` 가 오면 연결하지 않고 그 이유를 남긴다.
- 연결 하나는 명령을 하나씩 처리한다. worker 안에서 연결마다 fiber 하나가 명령을 받아 실행하고 답한 뒤에 다음 명령을 받는다. 그래서 스크립트 둘이 한 공간을 동시에 만지지 않는다.
- 연결 하나에 `ego-browser nodejs` 프로세스 하나가 그 연결의 스크립트를 모두 실행한다. 명령마다 프로세스를 새로 띄우면, 앞 명령이 연 대화상자가 남은 페이지에 다음 명령이 닿지 못한다(2절). 프로세스는 `nodejs -e` 로 띄운 고정 루프다. 연결의 비공개 디렉터리(0700)에 있는 Unix 소켓으로 worker 에 붙고, 받은 스크립트를 하나씩 async 함수로 실행한다. 그 함수의 `console` 은 쓴 줄을 모으는 객체이고, 모은 줄을 소켓으로 답한다. 소켓 파일은 프로세스가 붙자마자 지운다.
- 명령이 시간 창 안에 답하지 않거나, 출력 한도를 넘거나, 취소되면 그 프로세스를 그룹째 멈춘다. 프로세스가 소켓에 붙기 전, 시작을 기다리는 동안 취소돼도 같다. 다음 명령은 새 프로세스를 띄운다. 명령마다 프로세스를 띄우던 때와 같은 규칙이고, 시간 창 계산(6절)도 같다.
- 연결이 끝나면 소켓을 닫고 SDK 프로세스만 멈춘다. 오류·취소·사용자 인계·worker retirement는 Space를 완료하지 않는다. `finish_space`의 검증된 native `closedSpace=true` 응답이 있어야 파일 정리를 허용한다. 그 외에는 browser-backed 파일을 보존하고 정리 결과를 미확인으로 남긴다.
- 탭 번호는 연결 안에서 페이지 라벨(`p1`, `p2`)마다 한 번 정한 정수다. ego 는 라벨을 공간이 끝날 때까지 바꾸지 않고, `targetId` 는 실행 사이에 들고 다니지 말라고 한다. 라벨이 없는 탭(운영자가 그 공간에 연 탭)만 `targetId` 로 목록 번호를 받는다. 목록에서 사라진 탭의 번호는 버린다.
- 라벨이 있고 `openedBy: "agent"` 인 페이지만 이동·닫기·입력을 받는다. 라벨 없는 운영자 탭은 목록에만 나오고, 읽기도 효과 없이 거절한다. ego 문서가 그런 탭은 adopt 한 뒤에만 다루라고 해서다. BiDi 의 "이 연결이 연 탭만" 규칙과 비슷하다.

## 5. 동작

명령마다 정해진 스크립트 하나를 실행한다. Keeper 가 보낸 JS 는 받지 않는다. 인자는 JSON 값으로 스크립트에 넣는다.

| live 기능 | ego 호출 | 첫 단계 |
|---|---|---|
| `tab_listing` | `task.tabs()` | 한다 |
| `text_read`, `element_inventory`, `scene_read` | `page.evaluate` 로 `Browser_page_script`·`Browser_scene_script` 를 그대로 실행 | 한다. selector 와 `within` 이 다른 연결과 같은 뜻이 된다 |
| `viewport_capture` | `page.screenshot()` 파일을 읽어 base64, 앞뒤로 `info()` 비교 | 한다 |
| `accessibility_snapshot` | `page.snapshot()`(viewport), `{scope: "full_page"}`, `{scope: "subtree", root: "@12"}`. 글을 `maxChars` 에서 자르되 서로게이트 쌍은 쪼개지 않는다 | 한다(BrowserRead `mode=snapshot`). ego 연결만 한다. 프레임 읽기(`read_frames`)도 이 길이다: viewport snapshot 이 iframe 내용을 담고, 그 iframe 의 ref 를 root 로 한 subtree 가 한 프레임을 읽는다. 읽기의 `framePath` 와 `mode=frames` 는 peer 에 오기 전 live 전송 역량 검사에서 `live_transport_unsupported` 로 거절된다. snapshot 을 쓰는 길은 도구 설명과 가이드가 알려 준다 |
| `dom_interaction` | selector click·fill·hover·double_click·select_option은 Ego의 `page.click/fill/hover/dblclick/selectOption`에 그대로 보낸다. Ego가 locator·actionability·자동 스크롤·iframe/shadow 탐색을 맡는다 | selector는 Ego SDK 문법이다. selectOption은 `{value}` 또는 그 배열로 정확한 값을 전달하며 native programmatic selection을 따른다(비활성 option도 선택 가능). scene node, 문서 전체 scroll, 직접 href 이동만 공통 DOM 어댑터를 쓴다 |
| `snapshot_target_input` | snapshot ref·role·text를 Ego locator로 바꾸어 `page.click/fill/hover/dblclick`에 보낸다. 별도 `waitForSelector`를 덧붙이지 않는다 | 소유·대화상자·관측 URL 검사는 native 메서드 진입 전에 한다. native 메서드가 실패하면 이미 입력됐을 수 있어 결과 모름이며 재실행하지 않는다. popup·dialog 영수증과 탭의 위치를 돌려준다 |
| `native_workflow` | BrowserInteract `action=workflow`가 native Page 입력·이동·wait와 마지막 snapshot을 한 broker 명령으로 실행한다. selector와 대기는 Ego가 처리한다 | 최초 expectedUrl과 순서가 정해진 steps를 받으며 메서드별 native `options`를 SDK에 전달한다. `selectionJson`은 string/object/array/null 선택을 보존한다. 호스트의 누적 명령 타이머를 더하지 않는다. 실패·dialog·제어권 상실에서 멈추고 completed 진행을 보존한다. 드래그 실패에 해제를 합성하지 않으며(좌표 경로 `page.drag` 만 `mouse.down` 뒤 재개), 해제 미확인은 추가 입력을 막는다. 입력 결과 불확실 시 전체 재실행하지 않는다. 임의 host JavaScript는 노출하지 않는다 |
| `trusted_hover`, `trusted_keyboard` | `page.mouse.move`, `page.keyboard.type`·`press` | 한다. 입력 전에 `pointer_guard_script`·`keyboard_guard_script` 가 관측한 문서·URL·화면을 확인한다 |
| `point_click`, `trusted_button_click`, `trusted_double_click`, `point_scroll` | `page.mouse.click`(`button`, `clickCount`), `page.mouse.wheel` | 한다. 마우스 단계(`move`·`click`·`wheel`, 드래그의 `move`)마다 `label` 에 `MASC · <actor 또는 agent> · <동작>` 을 넣는다. ego 가 그 글을 자기 커서 강조 옆에 보여 줘서, 운영자가 누가 무엇을 하는지 본다. BiDi 연결의 표시(`Browser_pointer_feedback`)와 같은 조각이다 |
| `tab_creation` | `task.newPage()` 뒤 `goto` | 한다 |
| `tab_navigation` | `page.goto` (agent 페이지만) | 한다 |
| `tab_closing` | `page.close()` (agent 페이지만) | 한다 |
| `tab_history` | 새로고침은 `page.reload()`. 뒤로·앞으로는 `page.cdp()` 로 `Page.getNavigationHistory` 를 읽고 `Page.navigateToHistoryEntry` 로 한 칸 옮긴 뒤, 그 탭의 현재 항목이 그 칸이 되고 문서가 다 불러와질 때까지 기다린다 (agent 페이지만) | 한다. 그 쪽에 항목이 없으면 행동 전에 거절한다 |
| `dialog_answer` | `page.info()` 가 페이지를 막은 대화상자를 알려 주고, `acceptDialog(text?)`·`dismissDialog()` 로 답한다 (agent 페이지만) | 한다. 탭 목록의 행에 `dialog` 가 실린다. 클릭·키 입력이 대화상자를 열면 그 영수증에 담고, 페이지 스크립트가 막히면 부분 효과다. 열린 동안 그 페이지의 읽기·이동·입력은 행동 전에 거절하고, 탭 닫기는 받는다. 연결의 프로세스가 하나라서(4절) 다음 명령도 그 대화상자에 닿는다 |
| `download_listing` | agent 페이지를 건드리는 단계가 그 페이지에 `page.waitForEvent("download")` 대기를 하나 걸어 둔다. 잡힌 다운로드는 `saveAs` 로 worker 의 다운로드 폴더 아래 `ego/<id>` 에 저장하고, ego 의 임시 파일은 `delete()` 로 지운다. 대기는 다운로드마다 다시 걸린다. 대기가 실패하면(페이지가 닫힌 경우 포함) 멈추고, 그 페이지의 다음 단계가 다시 건다 | 한다(BrowserRead `mode=downloads`, 탭 하나). 행은 Gecko 와 같은 모양(대기 중·끝남·중단)이고, 끝난 파일은 Gecko 와 같은 broker 로 publish 해 `artifact` 로 돌려준다. 목록은 ego 프로세스 안에 있어서, 멈춘 명령 뒤 새 프로세스는 그때부터 본 것만 안다. `watchingSince` 가 그 시점이다. 운영자의 다운로드 폴더에는 남는 것이 없다. ego 의 브라우저가 다운로드하는 동안 그 폴더를 건드리기는 한다 |
| `file_upload` | `page.setInputFiles(selector, paths)`에 native locator/ref와 worker 사본을 그대로 전달한다. label·container·shadow 해소는 SDK가 맡는다 | 영수증 `chosen`은 SDK에 넘긴 staged 파일 메타데이터이며 페이지의 파일 목록을 다시 관측한 값이 아니다. 파일 확인·sandbox 전달·공간 종료까지 lease는 MASC가 맡는다. `opener`는 native locator로 클릭하고 `waitForFileChooser()`의 SDK 대기를 쓴다. 파일 전달 전에 포기한 chooser만 `setFiles([])`로 닫는다. `setFiles(paths)`에 진입한 뒤에는 실패하더라도 SDK가 정리를 맡으며 MASC가 두 번째 호출을 하지 않는다 |
| `tab_activation` | CDP `Target.activateTarget` | 다음 단계 |
| 드래그 | waypoint 없는 selector 간 `drag_to`는 `page.dragAndDrop`. scene node·좌표·명시적 waypoint는 관측한 pointer 경로를 유지한다 | 한다. SDK에 없는 waypoint-list·scene identity 의미를 보존한다 |
| 터치, 줌, 뷰포트 | 이 연결에서 아직 지원하지 않는다 | 다음 단계 |

ego 만의 읽기는 연결 방식 표의 기능 `accessibility_snapshot` 으로 둔다. BrowserRead `mode=snapshot` 이 ego 스냅샷을 그대로 돌려주고, 줄마다 붙은 ref(`ref=12`)는 그 순간의 페이지를 가리킨다. BrowserInteract 의 click·fill·hover·double_click은 그 ref 나 role·글을 `target` 으로 받는다(`snapshot_target_input`). Ego 연결의 `selector`와 `target`은 Ego 자신의 locator 뜻을 따른다. `target`은 다른 연결에서 효과 전에 거절한다. 페이지가 바뀌거나 입력한 뒤, 또는 ego 가 Stale/Unknown ref 를 거절하면 새 snapshot 을 읽는다. ref 수명과 문서 식별은 ego 의 고유 registry 가 맡고 MASC 가 다시 구현하지 않는다. URL 검사는 native 메서드를 호출하기 전 관측이며, 메서드 내부 대기·입력과 원자적인 검사는 아니다.

### 사람에게 넘기기

로그인·캡차처럼 사람이 해야 하는 단계가 나오면 Keeper 가 공간을 운영자에게 넘긴다. 운영자가 끝났다고 말하면 Keeper 가 되찾는다. 2026-10-23 운영자가 이 방식을 골랐다.

| BrowserAct | ego 호출 | 동작 |
|---|---|---|
| `hand_off` | `task.handOff()` | 공간 전체를 넘긴다. 탭은 고르지 않는다. 운영자에게 무엇을 할지는 Keeper 가 자기 말로 알린다 |
| `take_over` | `takeOverTaskSpace(spaceId)` 뒤 `userPage()` | 운영자가 끝났다고 말한 뒤에만 부른다. ego 도 MASC 도 그 말을 확인하지 않는다. 영수증에는 되찾을 때 활성이던 탭의 번호를 싣는다. 그 탭이 라벨 없는 운영자 탭이면 번호를 싣지 않고, adopt 하지도 않는다(#45284 22번) |

- 둘 다 탭이 없는 공간 단위 동작이다. `open_tab` 처럼 관측한 `clientId` 가 꼭 있어야 한다.
- 모든 스크립트의 틀이 `taskSpace()` 바로 뒤에 `task.ownership` 을 본다. `agent` 가 아니면 그 명령을 행동 전에 거절한다(`before: true`). 운영자가 ego 화면에서 직접 가져간 공간도 같다. 거절 문장은 `take_over` 를 운영자가 끝났다고 말한 뒤에만 쓰라고 알린다.
- `take_over` 만 반대로 `agent` 일 때 거절한다. 되찾을 것이 없어서다.
- 연결 방식 표의 기능은 `operator_handoff` 이고, `ego_task_space` 만 한다.

## 6. 실패

| 상황 | 분류 |
|---|---|
| 스크립트가 행동 전에 거절함(설정 없음, 인자 오류, 운영자 탭, 대상 없음, 관측한 문서·주소·화면이 바뀜) | 효과 없음. 스크립트가 행동 전에 확인하고 `before: true` 를 붙인 답만 이렇게 센다 |
| 읽기 명령에서 ego 가 오류로 답하거나 시간 안에 끝나지 않음 | 효과 없음 |
| 이동 뒤 ego 가 오류로 답함 | 같은 실행에서 그 탭의 행을 다시 읽는다. 행이 있으면 그 상태를 담은 부분 효과, 없으면 결과 모름 |
| 효과 명령에서 그 밖의 오류로 답함(실행 도중에 사람이 공간을 가져감 등) | 결과 모름. 탭을 다시 읽으라는 말을 붙인다. ego 의 오류 문장으로 효과가 있었는지를 가리지 않는다 |
| `ego-browser nodejs` 가 시간 안에 끝나지 않음 | 결과 모름. 그 실행을 프로세스 그룹째 멈추고 연결은 그대로 둔다. Keeper 는 그 탭을 다시 읽는다 |

실행을 시작할 때 이미 운영자가 공간을 쥐고 있으면, 틀이 소유를 보고 행동 전에 거절한다(5절 사람에게 넘기기). 실행 도중에 가져가면 그 뒤의 ego 호출이 `EGO_TASK_SPACE_USER_IN_CONTROL` 로 실패하고, 위 표대로 결과 모름이다. MASC 는 같은 명령을 다시 보내지 않는다.

시간 창은 서버가 그 명령을 기다리는 시간(`Browser_lane.reply_timeout_sec`)에서 결과를 전달할 여백 2초를 뺀 값이다. worker 는 그 안에서 멈춤 유예 2초를 남기고 실행한다. ego 쪽에 따로 시간 제한을 두지 않는다.

설정된 ego 가 처음 붙을 때 시작하지 못하면(경로가 틀림, `--version` 이 버전을 답하지 않음, 같은 이름의 운영자 공간) browser Add-on worker 가 뜨지 않고, 그 worker 의 BiDi 연결도 같이 뜨지 않는다. `[browser.live.bidi]` 의 Firefox 가 뜨지 못할 때와 같은 규칙이다.

## 7. 설정

`runtime.toml`:

```toml
[browser.live.ego]
command = "/절대/경로/ego-browser"
space = "masc-keepers"
```

이미 존재하는 같은 Space를 정확히 재개하려면 `space = 32`처럼 TOML 정수를 쓴다.
`space = "32"`는 이름이다. 정수 ID가 없거나 SDK가 다른 ID를 답하면 연결을 거절하며,
이름으로 재시도하거나 대체 Space를 만들지 않는다. 사용자 소유 Space를 claim하거나
인계된 Space를 take over하지도 않는다. 숫자 ID 연결은 현재 한 설치의 연결 설정이며,
Goal별 Space 자동 생성·저장·재개 관리와는 구분한다. `--ego-space`는 이름을 설정하고,
그 옵션을 생략한 setup은 기존 숫자 ID를 그대로 보존한다.

- 경로는 코드에 적지 않는다. 운영자가 적는다.
- `masc browser-lane-setup --mode ego` 가 이 표를 쓴다. `ego-browser` 를 PATH, 그다음 `~/.local/bin`(ego lite 첫 실행이 링크를 두는 곳)에서 찾고, `--version` 이 ego lite 와 Chromium 버전을 답할 때만 쓴다. 답하지 않는 ego 를 적으면 browser Add-on worker 가 뜨지 못해서다.
- `masc setup` 의 도구 체크리스트(5 · Give imp tools)는 `ego-browser` 가 답할 때 이 명령을 해제된 줄로 보인다. Firefox 가 없어도 보인다. BiDi 줄과 같이 고르면 연결을 지정하지 않은 요청은 모호하다고 거절된다.
- live 를 끄면(`[browser.live] enabled = false`) ego 연결도 새 명령을 받지 않는다.
- `[browser.live]` 표가 받는 키(`enabled`, `bidi`)에 `ego` 를 더한다.

## 8. 검사

- 가짜 `ego-browser`: 세션 루프의 소켓에 붙어, 받은 스크립트 맨 위의 표지 주석(`// masc-ego: tabs.list` 등)을 읽고 정해진 답을 내는 실행 파일. worker 의 연결·탭 번호·실패 분류와, 프로세스 하나가 명령을 모두 실행하는지를 이걸로 본다.
- 표 검사: `test_browser_lane` 의 연결 방식 표 검사에 `ego` 열을 더한다.
- 실제 ego: 샌드박스 밖에서 example.com 과 고정 fixture 페이지로 목록·읽기·클릭·이동·닫기를 돈다. 결과는 `docs/evidence/` 에 둔다.
- live: 운영자 승인 뒤 Keeper 가 BrowserTabs 로 ego 연결을 보고 Slack 채널 하나를 읽는다.

## 9. 순서

1. 이 RFC.
2. `Browser_lane.live_transport` 에 `Ego`, 연결 방식 표, 설정 `[browser.live.ego]`.
3. worker 의 ego 연결: 공간 열기·닫기, `tabs.list`, 읽기 세 가지, 캡처.
4. 입력: click·fill·hover·키보드, `open_tab`·`goto`·`close_tab`.
5. 실제 ego 증거와 Keeper 스킬 안내.

### Native input adapter audit

- selector-to-selector `drag_to` without `via` delegates to `page.dragAndDrop`.
  Scene identity, explicit coordinates and custom waypoint drags retain the
  observed MASC pointer adapter because the SDK has no waypoint-list parameter.
- Upload selectors and chooser openers use native Ego locator/ref syntax. MASC
  does not resolve them with top-document CSS before or after the SDK call.
  `chosen` describes staged files handed to the SDK; reread the application to
  confirm upload/submission. Regular-file validation, sandbox transfer and the
  connection's file lease remain MASC responsibilities.
- `waitForFileChooser()` owns its native default wait. Live uploads and workflows
  use the existing cancellation boundary rather than an outer command deadline.
- Document-window scroll and observed direct-href navigation retain their
  different behavior from wheel-under-pointer and clicking a link. Dialogs and
  downloads already call native SDK methods; their remaining adapters maintain
  MASC receipts, artifact publication and process/file lifetime.

The persistent SDK-process adapter was checked on Ego 0.6.0.20 and rechecked
on installed [0.6.1.11](../evidence/ego-native-session-gap/0.6.1.11/).
The second SDK process made no progress past its before-info marker while the
original process held the confirm; it returned after the original dismissed
it. This supports retaining the serial session, without proving the SDK's
internal blocking cause or relabeling earlier Keeper runs as new-version
execution. The complete usage guides were byte-identical: the new guide
exposed no additional Page method replacing a MASC adapter. Separately, the
[.20 download observation](../evidence/ego-native-session-gap/#download-lifetime-is-not-inferred-from-the-guide)
does not support claiming every SDK round exit deletes its download temp files.

### Explicit shared Goal Space binding

After `masc_browser_tabs` reports an Ego connection, bind that observed Space
with `masc_browser_session` arguments
`{"action":"bind_goal","goalId":"<existing-goal-id>","lane":"live","clientId":"<observed-client-uuid>"}`.
This stores the Add-on installation and numeric Space ID with the verified host
actor. It does not read Pages, claim a Space, take over, or finish it. Repeating
the same assignment is idempotent; changing the assignment or assigning the same
Space to a different Goal is refused. Names are observations, not identity.
`{"action":"goal_status","goalId":"<existing-goal-id>"}` reads the stored
binding only; it does not establish that the Space is connected or visible.

For a Keeper's initial automatic tab discovery or session open, the host reads
its authoritative current Task and Goal links. One linked Goal with a binding
pins selection to that installation and numeric Space ID, resolving the current
client UUID from the worker's dispatch snapshot. A missing connection or different
installation refuses the request before browser dispatch. Multiple linked Goals
require an explicit browser selection. Goalless Tasks and Goals without a
binding retain ordinary selection. Explicit lane/clientId and bound Page calls
never consult this default or gain authority from it.

An Ego Space is already open: discover its Pages with BrowserTabs. A Goal pin
does not turn BrowserSession open into a native Space-creation operation. This
binding does not yet create missing Spaces, manage several simultaneous Goal
Spaces in one worker, reassign/delete bindings, or finish them on Goal completion.
User-held and delegated Spaces retain their existing admission rules; the stored
binding is no takeover authorization or proof of visible UI/login completion.

### Operator-confirmed input recovery

The browser installation advertises a private `lane_operator` form using the
existing Add-on operator controls. A pending input records a fresh generation,
original issued command ID, tab number, Page label and operation in its original
Ego peer. The form binds that generation to the currently connected client and
numeric Space ID; the host's existing private operator endpoint additionally
requires an operator credential and the original worker incarnation. The port
cannot be exported as a model tool.

After checking and resetting keys/buttons in that same Space, the operator may
press “입력 상태 확인·초기화 완료”. This sends no SDK input. It records
`Operator_reset_asserted`, permits a subsequent distinct command, and shows
`inputReadiness=operator_asserted` on results until a new holding operation
settles. Every result that is a JSON object carries `inputReadiness`:
`command_settled`, `operator_asserted` or `release_uncertain`. A tab list that
is a plain array carries nothing. An input preflight refusal restores the prior
provenance. A new input uncertainty creates a new generation, so an older
confirmation cannot unlock it. The form refuses active commands, foreign
clients/Spaces and stale generations;
a duplicate confirmation for the same still-current assertion is idempotent.
Stale form submissions return a `not_applied` view rather than an MCP error
that could unnecessarily retire the worker. After a lost reply, inspect the original installation and read its form only
if that same worker is still available; do not replay browser input. The
existing generic private-operator transport may retire a worker on an unknown
reply. This extension does not change that transport or persist pending input
across worker replacement, and never applies an old assertion to a replacement.

Dialog answers, handoff, takeover and generic “go” do not create this assertion.
It does not establish original SDK cleanup, visible UI or successful login. The
local admission state adds no release evidence of its own. It settles only from a
proof that `Browser_ego_release` builds from the answers the SDK declared for the
input-holding steps. Native workflows stop on a receipt-less holding step without
using Page.info to infer release or counting that uncertain step as completed.
The current SDK's keyboard.type returns void even after ordinary typing, so
this requires explicit operator recovery there as well. It does not supply the
missing SDK settlement contract or establish non-workflow input cleanup.
Real operator recovery and current installed Keeper/UI acceptance still require
execution evidence.


### Read the bound Space's native status

`page.act` action `space_status` requires the observed live client ID and reads
only that peer's bound numeric Space from the SDK's `listTaskSpaces` inventory.
It does not construct a TaskSpace handle or initialise background Page discovery. It returns `spaceId`,
`spaceName`, verbatim native `ownership` and `observedAt`, without Page calls,
claim, takeover or input settlement. Delegation does not block this metadata
query; missing or foreign IDs never fall back to a name or create a Space.
It does not establish visible UI, user completion or permission for later input.

The private operator view shows the last cached SDK observation without browser
I/O. Hand-off, takeover, control waits and failed metadata refreshes invalidate
that cache. Ordinary connection identity remains the attachment name and fixed
ID; refreshed native names are separate observations. The ordinary Add-on
connection row also carries `spaceObservation` (or explicit null) for that exact client and numeric Space. The host validates this field
before passing the row through. Dashboard connection lists and selected events
show the raw native value and its own observation time, including retained rows;
null stays unknown. Refreshing the row reads the cache only; explicit
`space_status` refreshes the SDK observation. This display does not change
control or establish current ownership, window visibility or login. TUI ownership
rendering and actual installed Keeper/UI proof remain follow-up work.

### Explicit native completion

`page.act` action `finish_space` requires the observed live client ID. It calls
`TaskSpace.finish({keep})` with `keepPages` (distinct permanent labels; default
empty). Use it once after task success, never for error or user control. The
response preserves the validated native receipt, including actual closure,
retained/closed labels and protected unmanaged-tab count. Every former Page label
ends, including retained Pages; subsequent Page/control work on this peer is
refused. Only metadata-only `space_status`, browser info and cached completion
readback remain available. An identical confirmed request returns its cached
receipt without replay. Lost, invalid or cancelled completion remains uncertain
and cannot be retried on this peer. A pre-effect refusal/unstarted process permits
an explicit later attempt. This process-local state does not provide durable
cross-worker completion reconciliation.

Worker retirement only stops the SDK session. A confirmed closed Space with
successful upload cleanup permits broker file cleanup; active, delegated,
retained or uncertain Spaces preserve files and return unconfirmed cleanup.
Retained files currently require operator-owned reconciliation; there is no
cross-worker lease reclamation. Automatic Goal completion is not wired here.
