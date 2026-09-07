# Slack Lane — 슬랙 개인 스트림 설계 (초안)

2026-09-07. browser-lane(#33768)의 두 번째 레인 사례로 제안. 승인 전.

## 목적

- 바인딩된 Slack 채널의 메시지를 **개인화 필터**(계정 화이트리스트)로 골라
  서버 안 상태에 쌓고, TUI 전용 탭에서 스트림으로 본다.
- keeper 리더 도구가 같은 상태(및 Slack REST)를 조회해 다이제스트·조사에 쓴다.
- 쓰기(답장)는 후속 — verb 권한 분류와 함께.

배경: 앱 Event Subscriptions에 `message.groups`/`message.channels`가 없어
소켓 푸시는 멘션뿐이다. REST 수집은 이미 스코프가 있어 가능하며,
jeong-sik/me#1291의 slack-stream 폴러(15분 주기, MCP board 게시, 계정 필터,
커서는 게시 성공 후에만 전진)가 그 증명이다. 이 설계는 그 폴러를
masc 서버 안 상태로 흡수하는 쪽이다.

## 구조 — 밀어넣기 백엔드 하나

browser-lane은 백엔드가 명령을 long-poll로 가져가지만, Slack은 공개 HTTP API라
서버가 직접 부를 수 있다. 그래서 명령 큐를 만들지 않고 폴러는 결과만 민다.

```
slack-stream 폴러(me#1291)  ──POST /slack-lane/events──┐
  (15분 주기, 계정 필터)                                  │
                                                        ▼
masc 서버 :8935                        lib/slack_lane 상태 (링 버퍼)
  /slack-lane/events  (폴러가 배치를 밀어넣음)             │
  /slack-lane/stream  (TUI가 읽어감)                      ├→ TUI 탭 (masc_tui_slack_*)
                                                        └→ keeper 도구 masc_slack_read
keeper 도구 masc_slack_read ──(즉답 필요하면)── lib/gate/slack_rest_client 직접 호출
```

- 인증: browser-lane과 같은 경계 — localhost 전용 경로 + 설정 토큰
  (`slack_lane_token`). 원격 노출 금지.
- 상태: 채널별 링 버퍼(최근 N 메시지, 디스크 아님 — 재시작 시 폴러 커서가
  진실). board 게시는 다이제스트 회로로 그대로 유지(양립).
- 증분 2의 리더 도구가 즉답을 필요로 하면 `slack_rest_client`를 서버가 직접
  호출한다(토큰은 이미 env). 백엔드 왕복을 만들지 않는다.

## 동사(verb)와 권한 경계

| verb | 도구 | 분류 |
|---|---|---|
| `messages.read` | masc_slack_read | 읽기 (lane 버퍼, 없으면 REST) |
| `thread.read` | masc_slack_read | 읽기 (conversations.replies) |
| `post.send` | (미정) | 쓰기 — act budget 필요. `chat:write` 스코프는 이미 있음 |

## 증분

1. **상태 + 라우트 + TUI 탭**: `lib/slack_lane/`(상태, browser_lane의 모양),
   라우트 2개, 폴러의 게시 대상에 서버 추가, `masc_tui_slack_*` 렌더 모듈.
   탭은 채널 전환 + 계정 필터 뷰.
2. **리더 도구**: `messages.read`/`thread.read`. 다이제스트 keeper가 board 긁기를
   대체.
3. **쓰기**: `post.send` + act 분류(browser-lane의 `verb_is_read` 대응).

## 열린 질문

- 링 버퍼 크기와 채널별 상한(트래픽 많은 채널의 채움 속도).
- TUI 탭의 데이터 갱신 경로 — 스냅샷 폴링 vs 기존 SSE 재사용.
- 폴러의 서버 부재 시 행동 — board 게시로 폴백하면 무손실이 유지된다.
- 토큰: 봇 토큰 유지가 기본. 세션 토큰(xoxs) 대체는 비공식 경로라
  명시적 승인 없이는 설계에 넣지 않는다.
