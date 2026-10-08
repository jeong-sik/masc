# 연결과 복구

## 레인 오류

- live의 연결 부재는 브라우저 프로세스, 확장, native host, 서버 연결 중 어디서나
  발생할 수 있다. “브라우저가 꺼졌다”로 단정하지 않는다. 결과의 `error`가 경우를
  나눈다.
  - `ambiguous_browser_clients`: `clients`에서 하나를 골라 그 clientId로 다시 부른다.
  - `selected_client_disconnected`: `clients`에 남은 연결이 있으면 고른다. 없으면
    `no_live_client`와 같이 한다.
  - `no_live_client`: `host`에 워크스페이스 포트(`workspace_port`), 이 서버가 실제로
    듣는 포트(`serving_port`), 지금 이 서버를 poll 하는 host 수(`polling_hosts`),
    판정(`verdict`)과 `message`가 있다. 이
    `message`와 `retry`를 운영자에게 그대로 전한다. 고칠 수 있는 사람은 운영자뿐이라
    같은 호출을 되풀이해도 답은 같다.
  - `live_transport_unsupported`: 고른 연결이 그 일을 못 한다. live 연결은 방식
    (`transport`)에 따라 할 수 있는 일이 다르다. `hover_at`과 `drag`는
    `webdriver_bidi` 연결만 하고, `activate_tab`은 `web_extension` 연결만 한다.
    읽기(`mode=text`·`elements`·`scene`·`screenshot`)는 둘 다 한다. `servingClients`에 연결이 있으면 그 clientId로
    탭 목록과 페이지를 다시 읽은 뒤 거기서 다시 한다. 탭 ID와 관측은 연결마다
    따로다. 비어 있으면 `retry`를 운영자에게 그대로 전한다.
    `webdriver_bidi` 연결이 필요한 일이었으면 응답에 `bidiHost`가 있다. 그 `message`는
    BiDi host가 지금 떠 있는지, 마지막 host가 언제 왜 끝났는지, 붙이는 방법을 말한다.
    이것도 운영자에게 그대로 전한다. host를 띄우는 일은 운영자가 한다.
- live 응답은 성공했을 때도 `clientId` 옆에 `transport`를 싣는다. hover나 drag가 필요한
  일이면 시작할 때 이 값을 본다. `web_extension`이면 그 연결로는 못 하므로, 연결 목록에
  `webdriver_bidi` 연결이 있는지 먼저 확인한다. automation과 stagehand 응답에는
  `transport`가 없다.
- 닫힌 automation 세션에서 작업해야 한다면 자신의 새 세션을 연다.
  `BrowserSession`에는 현재 `open`/`close`가 있고 `status`는 없다.
- 이미 시작된 세션이라는 응답은 소유권 증명이 아니다. 그 세션이 자신의 진행 중인
  작업인지 확인하고, 확인할 수 없다면 takeover나 close 후 reopen을 하지 않는다.
- 특정 탭의 확장 권한이 없으면 그 권한 문제를 알린다. 요청된 탭 대신 무관한
  다른 탭을 읽어 같은 작업을 완료했다고 하지 않는다.

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
