# 연결과 복구

## 자동 선택과 고정된 작업

처음 BrowserTabs 또는 BrowserSession open에서 lane을 생략하면 서버가 사용 가능한
브라우저를 선택한다. browserSelection의 lane과 clientId를 이후 호출에 복사한다.
browser_binding_required는 tabId가 어느 브라우저의 것인지 빠졌다는 뜻이다.
원래 관측의 lane/clientId를 넣어 고친다. ambiguous_browsers이면 browsers 목록에서
작업 대상을 확인해 명시한다. no_available_browser이면 연결 또는 설정된 작업 세션이
필요하다. 이 오류들은 브라우저 명령을 보내기 전에 반환된다.

선택 거절이나 특정 탭의 실패를 전체 브라우저·Lane Add-on 장애로 일반화하지
않는다. `keeper_lane_status`는 Keeper 실행 sandbox를 보는 도구이므로 browser
연결 진단에는 쓰지 않는다. BrowserSession open 성공은 기존 live 연결·로그인·읽기
실패의 복구 증거가 아니다. 새 세션은 독립 작업에만 사용하고, 원래 작업은 반환된
live 연결 중 요청 대상과 로그인이 있는 연결에서 탭 목록과 읽기로 계속할 수
있는지 먼저 확인한다.

## 레인 오류

- live의 연결 부재는 브라우저 프로세스, 확장, native host, 서버 연결 중 어디서나
  발생할 수 있다. “브라우저가 꺼졌다”로 단정하지 않는다. 결과의 `error`가 경우를
  나눈다.
  - `ambiguous_browser_clients`: `clients`에서 하나를 골라 그 clientId로 다시 부른다.
  - `selected_client_disconnected`: 고른 연결(`clientId`)이 끊겼다. 남은 연결이 있으면
    그 연결의 탭 목록부터 다시 읽고, 없으면 `no_live_client`와 같이 한다.
  - `no_live_client`: 이 lane에 연결된 브라우저가 없다. 고칠 수 있는 사람은
    운영자뿐이라 같은 호출을 되풀이해도 답은 같다. 운영자에게 알린다.
  - `live_transport_unsupported`: 고른 연결(`clientId`, `transport`)이 그 일
    (`capability`)을 못 한다. live 연결은 방식(`transport`)에 따라 할 수 있는 일이
    다르다. `drag`는 `webdriver_bidi`·`ego_task_space` 연결이 하고, `set_zoom`은
    `web_extension` 연결만 한다. `activate_tab`은 `web_extension`·`webdriver_bidi`
    둘 다 하지만 `webdriver_bidi`는 브라우저 창에 포커스도 준다. 읽기
    (`mode=text`·`elements`·`scene`·`screenshot`)는 셋 다 한다. `mode=snapshot`
    (ego 자신의 접근성 트리와 ref)과 click·fill 의 `target`(그 ref, 또는 role·이름이나
    보이는 글로 고른 대상)은 `ego_task_space` 연결만 한다. `ego_task_space`
    연결은 읽기, `open_tab`, `close_tab`, `back`·`forward`·`reload`, `accept_dialog`·`dismiss_dialog`,
    `hand_off`·`take_over`, `upload`(`selector` 의 파일 입력, 또는 `opener` 로 뜨는 파일 선택 창),
    `mode=downloads`, `BrowserGoto`,
    그리고 click·`click_at`·`double_click`·hover·drag·`scroll`·`scroll_at`·fill·
    `select_option`·`follow_link`·`type_text`·`press_key` 를 한다. 드래그는 셀렉터로 고른
    `drag_to`(경유점 `via` 없음)만 SDK 가 영수증을 돌려주고, 영수증에 `dialog` 가 없으면 입력이
    풀린 것으로 본다. 좌표 `drag`, `via` 가 있는 `drag_to`, `scene` 노드로 고른 드래그는 입력을
    보낸 뒤에는 끝까지 실행돼도 결과를 알 수 없다고 답하고, 운영자가 입력을 초기화할 때까지 그
    연결의 다음 입력이 거절된다. 입력을 보내기 전에 거절된 드래그는 입력을 그대로 쓸 수 있다.
    프레임은 `framePath`
    없이 다룬다: snapshot 이 iframe 내용을 ref 와 함께 담고, 그 ref 나 role·글 `target` 으로
    프레임 안을 누르고 채운다. 터치·`set_zoom`·`set_viewport`·`activate_tab` 은 하지
    않는다. `press_key` 는
    이름 있는 키와 ASCII 문자만 누르고, 다른 글자는 `type_text` 로 친다. 이동·닫기·
    입력은 그 공간에서 에이전트가 연 페이지만 한다(첫 페이지 `p1` 포함). 그 공간에서
    운영자가 연 탭은 목록에는 나오지만 읽거나 옮기거나 누르면 거절된다. 로그인이
    필요한 사이트는 `open_tab` 으로 그 주소를 열고 읽는다.
    로그인 화면이나 캡차처럼 사람이 해야 하는 단계가 나오면 아래 로그인 인계를 따른다.
    그 일을 하는 다른 연결이 있으면 그 clientId로 탭 목록과 페이지를 다시
    읽은 뒤 거기서 다시 한다. 탭 ID와 관측은 연결마다 따로다. 그런 연결이 없으면
    운영자에게 알린다.
- live 응답은 성공했을 때도 `clientId` 옆에 `transport`를 싣는다. hover나 drag가 필요한
  일이면 시작할 때 이 값을 본다. `web_extension`이면 그 연결로는 못 하므로, 연결 목록에
  `webdriver_bidi` 연결이 있는지 먼저 확인한다. automation과 stagehand 응답에는
  `transport`가 없다.
- 닫힌 automation 세션에서 작업해야 한다면 자신의 새 세션을 연다.
  `BrowserSession status`로 상태를 읽고 `open`/`close`는 작업 소유권을 확인해 사용한다.
- 이미 시작된 세션이라는 응답은 소유권 증명이 아니다. 그 세션이 자신의 진행 중인
  작업인지 확인하고, 확인할 수 없다면 takeover나 close 후 reopen을 하지 않는다.
- 특정 탭의 확장 권한이 없으면 그 권한 문제를 알린다. 요청된 탭 대신 무관한
  다른 탭을 읽어 같은 작업을 완료했다고 하지 않는다.

탭 목록이 `complete=false`이면 일부 탭의 메타데이터를 읽지 못한 것이다.
`unavailableTabs`의 ID와 오류를 남기고 읽을 수 있는 요청 대상 탭에서 계속한다.
요청 대상 자체가 그 목록에 있으면 다른 탭으로 대신 완료하지 않는다. 시간 초과는
업무 규칙의 거절이 아니며, 조작이 적용됐는지 불확실하므로 현재 페이지부터 읽는다.

## 로그인·인증 인계

Ego Space는 같은 브라우저 안의 작업 공간이다. 작업할 때마다 새 창을 열거나
운영자의 현재 화면을 앞으로 가져오지는 않는다. `hand_off`도 창 표시나 로그인
성공의 증명이 아니라 제어권 인계다.

1. 현재 관측의 lane/clientId/tabId와 페이지 주소를 보관한다. BrowserAct
   `hand_off`를 같은 live clientId로 한 번 호출해 공간 전체를 운영자에게 넘긴다.
   성공 결과의 `spaceId`와 `spaceName`은 그 공간의 SDK 정보다.
   인계 전에 agent가 제어 중인 공간의 관리 Page(명시적으로 adopt한 Page 포함)를 활성화하려면
   같은 clientId/tabId와 expectedUrl로 BrowserInteract `activate_tab`을 사용한다.
   Ego의 네이티브 탭 활성화와 최소화된 창 복원을 요청하며, 반환된 active와
   window 상태는 실제 화면 노출이나 OS 포커스의 증명이 아니다. 실패·불확실
   응답을 자동 재실행하지 않는다. 이미 인계한 공간에는 호출하지 않는다.
2. `masc_ask`로 해야 할 일과 그 Space 이름·번호를 알리고, 끝나면 알려 달라고
   요청한다. 현재 알고 있는 Task/Goal ID를 함께 보낸다. 예를 들어 질문은
   “Ego의 Space <이름> (#<번호>)에서 Slack 로그인을 마친 뒤 완료를 선택해 주세요.
   화면이 보이지 않으면 그 상태를 알려 주세요”로, 선택지는 “로그인 완료”, “중단”,
   자유 입력을 제공한다. 비밀번호나 인증 코드를 Ask에 보내 달라고 하지 않는다.
   Ask의 context에는 원래 브라우저 연결·탭·주소와 재개할 일을 남긴다.
3. 운영자는 Ego 오른쪽 위 Space 버튼의 관리 패널에서 해당 공간을 선택한다.
   화면이 보이지 않는다는 답이나 질문은 완료 확인이 아니다. 인계 중인 공간에서
   읽기·입력·창 조작을 계속하거나 다른 Space를 만들어 우회하지 않는다.
   같은 요청을 반복 생성하지 않고, 기다리는 동안 독립 작업을 진행한다.
4. 원래 Ask에 로그인 완료가 답변됐거나 대화에서 운영자가 명확히 계속하라고 한
   뒤에만 같은 clientId로 `take_over`를 호출한다. 중단 답변이면 되찾지 않는다.
   `take_over`는 같은 Space와 native 사용자 인계 경계의 Page를
   `activeTabId`/`egoPage`로 돌려준다. 현재 활성 탭이나 로그인 성공 증거가 아니다.
   `egoPage.label=null`이면 해당 탭을 명시적으로 `adopt_tab`한 뒤 읽는다.
   되찾기 자체는 adopt·문서 읽기·입력 불확실성 초기화를 하지 않는다.
   명시적으로 adopt한 뒤에는 원래 출처를 보존한 채 입력·이동·활성화를
   해당 native Page에 요청할 수 있다. 출처가 unknown인 탭은 닫지 않고
   `release_tab`으로 운영자에게 돌려준다.
   경계의 Page가 없거나 달라졌으면 현재 활성 탭으로 대체하지 않으며,
   응답 유실 뒤 `take_over`를 자동 재실행하지 않는다.
   BrowserTabs와 의도한 관리 Page의 새 관측으로 실제 로그인 상태를 확인한다.
   완료 답변 자체를 로그인 성공으로 기록하지 않는다. 원래 페이지가 없거나 연결이
   끊겼다면 관측한 상태를 알리고, 다른 공간으로 재개 권한을 옮겨 해석하지 않는다.

`masc_ask`는 질문을 저장하고 반환하며, 기록된 답변은 원래 질문·context·Task/Goal
결속과 함께 Keeper를 다시 깨운다. BrowserAct가 Ask를 자동 생성하거나 답변을
검사하지는 않으므로, Keeper가 두 도구를 위 순서로 사용해야 한다.

근거: [Ego Space 협업](https://www.egolite.app/document/en/docs/space),
설치된 `ego-browser skill`의 “User control and completion”.

## 운영자가 automation을 설정할 때

```toml
[browser]
geckodriver = "/absolute/path/to/geckodriver"
# 필요하면 설치된 Firefox/Zen 실행 파일의 절대 경로를 지정한다.
# binary = "/path/to/Zen.app/Contents/MacOS/zen"
```

geckodriver는 MASC 서버가 직접 띄우고 서버가 끝날 때 내린다. 빈 loopback 포트와
`--websocket-port 0`을 쓰므로 포트를 고를 일이 없다. 드라이버 출력은
`.masc/browser-lane/geckodriver.log`에 있다.

복구할 때는 종료된 자기 테스트 세션만 대상으로 한다. geckodriver 프로세스는
서버 몫이라 Keeper가 종료하거나 새로 띄우지 않는다.
다른 브라우저나 9222의 기존 프로세스를 종료하지 않는다. Keeper에게 운영자
프로세스 제어 권한이 주어진 것으로 해석하지 않는다.

근거: [Mozilla geckodriver Flags](https://firefox-source-docs.mozilla.org/testing/geckodriver/Flags.html),
[MDN BiDi 연결](https://developer.mozilla.org/en-US/docs/Web/WebDriver/How_to/Create_BiDi_connection).
