# 연결과 복구

## 레인 오류

- live의 연결 부재는 브라우저 프로세스, 확장, native host, 서버 연결 중 어디서나
  발생할 수 있다. “브라우저가 꺼졌다”로 단정하지 않는다. 결과의 `error`가 경우를
  나눈다.
  - `ambiguous_browser_clients`: `clients`에서 하나를 골라 그 clientId로 다시 부른다.
  - `selected_client_disconnected`: `clients`에 남은 연결이 있으면 고른다. 없으면
    `no_live_client`와 같이 한다.
  - `no_live_client`: `host`에 설치된 host가 보는 포트(`launcher_port`)와
    워크스페이스 포트(`workspace_port`), 판정(`verdict`)과 `message`가 있다. 이
    `message`와 `retry`를 운영자에게 그대로 전한다. 고칠 수 있는 사람은 운영자뿐이라
    같은 호출을 되풀이해도 답은 같다.
- 닫힌 automation 세션에서 작업해야 한다면 자신의 새 세션을 연다.
  `BrowserSession`에는 현재 `open`/`close`가 있고 `status`는 없다.
- 이미 시작된 세션이라는 응답은 소유권 증명이 아니다. 그 세션이 자신의 진행 중인
  작업인지 확인하고, 확인할 수 없다면 takeover나 close 후 reopen을 하지 않는다.
- 특정 탭의 확장 권한이 없으면 그 권한 문제를 알린다. 요청된 탭 대신 무관한
  다른 탭을 읽어 같은 작업을 완료했다고 하지 않는다.

## 운영자가 automation을 설정할 때

```sh
geckodriver --host 127.0.0.1 --port 4444 --websocket-port 0
```

```toml
[browser]
webdriver_url = "http://127.0.0.1:4444"
# 필요하면 설치된 Firefox/Zen 실행 파일의 절대 경로를 지정한다.
# binary = "/path/to/Zen.app/Contents/MacOS/zen"
```

HTTP 포트와 BiDi 포트는 별개다. `--websocket-port 0`은 OS가 빈 포트를 배정하게
한다. 기본 9222가 점유돼 있으면 HTTP driver가 ready여도 BiDi handshake가
실패할 수 있다. **404만으로 포트 충돌을 확정하지 말고** 해당 driver 로그의
address-in-use와 반환 endpoint를 함께 확인한다.

복구할 때는 종료된 자기 테스트 세션과 자신이 시작한 driver만 대상으로 한다.
다른 브라우저나 9222의 기존 프로세스를 종료하지 않는다. Keeper에게 운영자
프로세스 제어 권한이 주어진 것으로 해석하지 않는다.

근거: [Mozilla geckodriver Flags](https://firefox-source-docs.mozilla.org/testing/geckodriver/Flags.html),
[MDN BiDi 연결](https://developer.mozilla.org/en-US/docs/Web/WebDriver/How_to/Create_BiDi_connection).
