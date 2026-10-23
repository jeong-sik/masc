# 연결과 복구

## 자동 선택과 고정된 작업

처음 BrowserTabs 또는 BrowserSession open에서 lane을 생략하면 서버가 사용 가능한
브라우저를 선택한다. browserSelection의 lane과 clientId를 이후 호출에 복사한다.
browser_binding_required는 tabId가 어느 브라우저의 것인지 빠졌다는 뜻이다.
원래 관측의 lane/clientId를 넣어 고친다. ambiguous_browsers이면 browsers 목록에서
작업 대상을 확인해 명시한다. no_available_browser이면 연결 또는 설정된 작업 세션이
필요하다. 이 오류들은 브라우저 명령을 보내기 전에 반환된다.

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
    다르다. `drag`는 `webdriver_bidi` 연결만 하고, `set_zoom`은
    `web_extension` 연결만 한다. `activate_tab`은 둘 다 하지만 `webdriver_bidi`는
    브라우저 창에 포커스도 준다. 읽기(`mode=text`·`elements`·`scene`·`screenshot`)는
    셋 다 한다. `ego_task_space` 연결은 읽기, `open_tab`, `close_tab`, `BrowserGoto`,
    그리고 click·`click_at`·`double_click`·hover·`scroll`·`scroll_at`·fill·
    `select_option`·`follow_link`·`type_text`·`press_key` 를 한다. drag·터치·
    `set_zoom`·`set_viewport`·`activate_tab`·frame 안 입력은 하지 않는다. `press_key` 는
    이름 있는 키와 ASCII 문자만 누르고, 다른 글자는 `type_text` 로 친다. 이동·닫기·
    입력은 그 공간에서 에이전트가 연 페이지만 한다(첫 페이지 `p1` 포함). 그 공간에서
    운영자가 연 탭은 목록에는 나오지만 읽거나 옮기거나 누르면 거절된다. 로그인이
    필요한 사이트는 `open_tab` 으로 그 주소를 열고 읽는다.
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
