# Browser Lane — masc ↔ 브라우저 연결 설계 (MVP)

2026-09-06. task-1382. 사용자 승인: 자동화 인스턴스(A)와 실세션 커넥터(B) 둘 다.

## 목적

- **A — keeper 자동화 인스턴스**: keeper 전용 브라우저(Playwright Firefox 빌드)를
  열고 조작하고 읽는다. 사용자 프로파일과 분리.
- **B — 실세션 커넥터**: 사용자의 살아있는 Firefox/Zen(확장 + native messaging)에서
  탭 목록과 페이지 텍스트를 읽는다. 조작(act)은 후속 — 게이트 설계와 함께.

실측(2026-09-06): stock Firefox는 Playwright로 못 잡는다(juggler 자체 빌드만).
그래서 A의 브라우저는 Playwright 빌드, B만이 "진짜 내 브라우저"를 담당한다.

## 구조 — 레인 하나, 백엔드 둘

두 백엔드가 같은 서버 인터페이스(long-poll 명령 큐)를 쓴다. 서버에 새
리스너/소켓을 만들지 않고 기존 HTTP 서버에 엔드포인트 2개를 얹는다.

```
keeper 도구                    masc 서버 (기존 HTTP :8935)
masc_browser_session  ──┐      ┌─ /browser-lane/poll   (lane이 명령을 가져감, long-poll)
masc_browser_navigate ──┤ tool ├─ /browser-lane/result (lane이 결과를 돌려줌)
masc_browser_read     ──┤ 해들 │
masc_browser_tabs     ──┘      └─ lane 상태: lane_id → 연결/대기열
        │
        │ 명령 큐: {id, verb, args} / 결과 {id, ok, data|error}
   ┌────┴─────────────────────────┐
   │ A 백엔드: playwright 데몬     │  node, 자체 빌드 firefox,
   │   lane_id = "automation"      │  세션 수명 = 도구가 지정
   └───────────────────────────────┘
   ┌───────────────────────────────┐
   │ B 백엔드: 확장 + host          │  WebExtension(background)
   │   lane_id = "live"             │  ↕ native messaging (4B LE + JSON)
   │                                │  host 프로세스(브라우저가 기동) = long-poll 클라
   └───────────────────────────────┘
```

- lane 식별: `poll` 요청이 `lane` 필드로 자기를 밝힌다. 첫 poll 시 연결 등록.
- 인증: localhost 전용 경로 + 설정 가능 토큰(`browser_lane_token`; 없으면 localhost
  바인딩 자체가 경계). 원격 노출 금지 — 터널 대상 아님.
- 명령 수명: tool 호출이 명령을 발행하고 타임아웃 내 결과를 기다린다.
  lane 부재 시 즉시 실패("브라우저 레인이 연결되어 있지 않습니다").

## 동사(verb)와 권한 경계

| verb | 도구 | 분류 |
|---|---|---|
| `tabs.list` | masc_browser_tabs | 읽기 |
| `page.read` | masc_browser_read | 읽기(페이지 텍스트, 캡 50k) |
| `session.open` / `session.close` | masc_browser_session | A 전용, 자원 관리(읽기 등급) |
| `page.goto` | masc_browser_navigate | **조작** — 외부효과 |
| `page.click` / `form.submit` | 후속 | **조작** — 외부효과, 게이트 대상 |

MVP 범위: 읽기 동사 + session.open/close + page.goto까지. page.goto는
`tool_execute`와 같은 외부효과 등급으로 게이트를 탄다(navigate는 웹에 쓰기를
남길 수 있다 — 로그인 세션에서 POST 재요청 등). click/submit은 별도 승인을
만들 때까지 레인 프로토콜에도 넣지 않는다.

교훈 적용(#33638): 동사는 닫힌 variant로 선언하고 unknown verb는 거부.
문자열 접두 분류 금지.

## B 확장 (MVP)

- manifest.json (MV2 — Firefox/Zen 안정권; MV3는 Firefox 128+ 가능하나 MVP는 MV2)
- 권한: `tabs`, `nativeMessaging`, `<all_urls>`(page.read의 executeScript)
- background: `browser.runtime.connectNative("masc_browser_host")`로 상시 연결.
  메시지 {id, verb, args} 수신 → tabs.query / scripting으로 실행 → {id, ok, data}
- host 등록: `~/Library/Application Support/Mozilla/NativeMessagingHosts/masc_browser_host.json`
  (Zen은 Mozilla 경로를 따른다; 다르면 Zen 전용 경로에도 복사 — 설치 스크립트가 처리)

## A 데몬 (MVP)

- node 단일 파일: playwright로 firefox 실행(필요 시), poll 루프.
  session.open → 브라우저 기동, session.close → 종료. 세션은 데몬이 하나만.
- 데이터 디렉터리: `<base>/.masc/browser-lane/profile`(자동 생성).

## masc 도구 배선 (기존 패턴 그대로)

1. `config/tools/masc_browser_*.toml` — embedded schema
2. `tool_schemas_misc_toml.ml` — schema_of_name 추가
3. `tool_schemas_misc.ml` — `Misc_browser_*` variant (+enumerate가 dispatch 강제)
4. `lib/tool_misc_browser_lane.ml` — 핸들러: 명령 발행/대기
5. HTTP 엔드포인트: 서버 라우트에 poll/result 추가
6. keeper 노출: keeper descriptor에 도구 추가(웹 도구와 같은 경로)

읽기 도구는 `is_read_only = true`(게이트 없음). navigate는 외부효과로
게이트 분류 — 레인 verb 자체는 읽기/조작 구분을 프로토콜에 실어
백엔드가 거부할 수 있게 한다(방어 심층).

## 순서

1. 확장 + host + 로컬 수신 시험(브라우저 ↔ host까지 end-to-end)
2. 서버 엔드포인트 + 도구(B 읽기 2개) → live 세션에서 tabs/read 실측
3. A 데몬 + session/navigate 도구
4. 조작 동사 게이트 설계(별도 문서)

## 안전

- 레인 토큰은 로컬 파일 권한(0600)으로.
- page.read 출력 캡 50k(툴 버짓 보호, masc_web_fetch와 같은 head/tail 창).
- 확장은 native messaging port 하나만 열고, host는 poll 응답만 믿는다.
- 조작 동사가 게이트를 우회하는 경로를 만들지 않는다 — 도구 계층에서만 발행.
