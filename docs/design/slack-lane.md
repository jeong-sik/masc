# Slack Lane — 슬랙 개인 스트림 설계 (초안)

2026-09-07. browser-lane(#33768)의 레인 사례로 제안. 승인 전.
2026-09-07 갱신: 외부 폴러 백엔드 안에서 **서버 내부(in-process) 폴링 파이버**로
종착지를 옮김 — Discord(#19393)·iMessage(#30531)가 사이드카를 지우고
in-process gateway로 간 것과 같은 방향. 외부 폴러(jeong-sik/me#1291)는
증분 1이 들어오기 전까지의 브릿지다.

## 목적

- 바인딩된 Slack 채널의 메시지를 **개인화 필터**(계정 화이트리스트)로 골라
  서버 안 상태에 쌓고, TUI 전용 탭에서 스트림으로 본다.
- keeper 리더 도구가 같은 상태(및 Slack REST)를 조회해 다이제스트·조사에 쓴다.
- 쓰기(답장)는 후속 — verb 권한 분류와 함께.

배경: 앱 Event Subscriptions에 `message.groups`/`message.channels`가 없어
소켓 푸시는 멘션뿐이다. REST 수집은 스코프가 이미 있어 가능하고,
jeong-sik/me#1291의 slack-stream 폴러가 종단 간을 증명했다
(15분 주기 수집 → board 게시, 계정 필터, 커서는 게시 성공 후에만 전진).

## 구조 — 서버 안 폴링 파이버

browser-lane은 백엔드가 명령을 long-poll로 가져가지만, Slack은 공개 REST
API라 서버가 직접 부를 수 있다. 그래서 외부 백엔드도 명령 큐도 없다.

```
masc 서버 :8935
  lib/slack_lane            상태: 채널별 링 버퍼(최근 N)
  server_slack_poll_lane    폴링 파이버 (gateway 파이버와 같은 자리):
    loop { sleep poll_interval;
           바인딩(.gate/runtime/slack/bindings.json)마다
             Slack_rest_client.conversations_history (신규 함수)
             → 봇/서브타입/멘션 제외 → 계정 필터
             → 링 버퍼 append + 커서(.gate/runtime/slack/poll-cursor.json) 전진
             → (브릿지 기간) board 게시 유지 — 다이제스트 회로 보존 }
  /slack-lane/stream        TUI가 읽어감
        │
        ├──→ TUI 탭 (masc_tui_slack_*)
        └──→ keeper 도구 masc_slack_read
```

- **켜고 끔**: `[slack] poll_enabled` + `poll_interval_sec` (runtime.toml,
  env 우선). 기본 꺼짐 — "SLACK_APP_TOKEN 없으면 gateway가 조용히 꺼진다"와
  같은 자세. 토큰은 서버 env의 기존 SLACK_BOT_TOKEN.
- **내구성**: 서버가 하루 여덟 번 재시작해도 커서는 파일에 있고, 파이버는
  부팅 시 이어 받는다. 링 버퍼는 메모리 — 재시작 후 과거는 채우지 않는다
  (진실은 Slack이 가진다; 다이제스트는 board 누적으로 커버).
- **외부 브릿지 폴러**: 증분 1 머지 즉시 stop. 그 전까지 board 게시를
  이중으로 하지 않게, 파이버의 board 게시는 브릿지가 죽은 뒤에 켠다
  (설정 한 줄로 전환).

## 동사(verb)와 권한 경계

| verb | 도구 | 분류 |
|---|---|---|
| `messages.read` | masc_slack_read | 읽기 (lane 버퍼, 없으면 REST) |
| `thread.read` | masc_slack_read | 읽기 (conversations.replies) |
| `post.send` | (미정) | 쓰기 — act budget 필요. `chat:write` 스코프는 이미 있음 |

## 증분

1. **수집 레인**: `Slack_rest_client.conversations_history`(신규),
   `lib/slack_lane`(상태), `server_slack_poll_lane`(파이버), runtime.toml knob,
   커서 파일. 브릿지 폴러 stop + 파이버가 board 게시 인수.
2. **리더 도구**: `messages.read`/`thread.read`. 다이제스트 keeper가
   board 긁기를 대체.
3. **TUI 탭**: `masc_tui_slack_*` — 채널 전환 + 계정 필터 뷰.
4. **쓰기**: `post.send` + act 분류(browser-lane의 `verb_is_read` 대응).

## 검증

- `test/test_slack_poll_lane.ml` — 파이버의 필터·커서 전진 계약
  (test_slack_gateway_state.ml의 모양). 가짜 REST로.
- `dune build @check` + CI green. 릴리즈 게이트는 타입체크뿐이니
  테스트 스탠자 등록(test/dune)까지 마쳐야 실효(과거 교훈).

## 열린 질문

- 링 버퍼 크기와 채널별 상한(트래픽 많은 채널의 채움 속도).
- TUI 탭의 데이터 갱신 경로 — 스냅샷 폴링 vs 기존 SSE 재사용.
- 브릿지→파이버 전환 판정: board에 이중 게시가 없는지 실측으로 확인 후.
- 토큰: 봇 토큰 유지가 기본. 세션 토큰(xoxs) 대체는 비공식 경로라
  명시적 승인 없이는 설계에 넣지 않는다.
