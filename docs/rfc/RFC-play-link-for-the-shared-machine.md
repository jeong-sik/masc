---
rfc: "play-link-for-the-shared-machine"
title: "링크 하나로 공유 기계에 자리를 준다"
status: Draft
created: 2026-09-28
updated: 2026-09-28
author: vincent + claude
related: ["0439", "machine-spectating-goes-through-lanes"]
---

# RFC — 링크 하나로 공유 기계에 자리를 준다

## 0. 요약

바깥 사람과 외부 에이전트가 masc 의 공유 DOS 기계에서 keeper 와 같이 게임을 한다.
첫 대상은 삼국지3 핫시트다.

- 운영자가 초대 링크를 만든다. 링크에는 이 기계만 다룰 수 있는 credential 이 들어 있다.
- 받은 사람은 폰이나 브라우저에서 링크를 열고 화면을 본다. 자기 차례가 오면 패드나 키보드로 누른다.
- 외부 에이전트는 같은 credential 로 MCP 에 붙어 `masc_dos_*` 도구를 부른다.
- 차례는 기존 controller 를 넘겨서 정한다.

출발점은 oh-my-pi README §07("hand someone the link, they're in")이다. 가져오는 것은
"링크가 곧 권한이고, 건네면 들어온다"는 경험이다. omp 는 에이전트 대화를 공유하지만,
여기서는 기계 화면과 자리를 공유한다. 서버가 곧 호스트이고 공개 주소로 닿으므로
별도 릴레이는 두지 않는다.

## 1. 지금 있는 것

- **기계 하나, 조종자 하나.** `lib/dos_lane/dos_lane.mli` 의 controller 는 삼국지3 같은
  핫시트 게임을 위해 있다. 조종자가 아니면 `load`·`eject`·`step`·`press`·`click`·`type_text` 가
  `Held_by` 로 거절된다. 화면 읽기(`screen`·`capture`·`peek`)는 조종자가 필요 없다.
  `pass ~who ~to_` 로 넘기거나 비운다. 멈춘 keeper 의 조종권은 `release_left` 로 풀린다.
- **차례 넘기기 도구.** `masc_dos_pass` 는 넘길 때 Board 글로 다음 사람을 @mention 한다.
  설명에 "Turn-taking, not access control" 이라고 적혀 있다.
- **관전 라우트.** `GET /api/v1/lane-addons/live?source_kind=dos_capture&since=N&incarnation=I`
  (`server_routes_http_routes_lane_addons.ml` `get_live`).
  - 화면이 바뀌었을 때만 `screen = {format: "rgb8", width, height, rgb_base64}` 를 준다.
    그대로면 몇 바이트짜리 답을 준다. 답은 JSON 압축을 거친다.
  - DOS 답에는 최근 활동(`activity`: load, press, pass, save …)이 붙는다.
  - 권한은 `with_read_auth` → `authorize_read_request` → `CanReadState` 다(`server_auth.ml`).
  - TUI 가 0.3초마다 이 라우트로 DOS 화면을 그린다.
- **도구 단위 권한.** 등록된 도구마다 `Tool_catalog` 가 필요 권한 하나를 선언하고
  `Auth.authorize_tool` 이 강제한다. 등록 안 된 이름은 거절한다.
  `lib/tool/tool_catalog.ml` 의 `explicit_metadata` 에서 `masc_dos_screen`·`masc_dos_peek` 은
  `read_state_tool`(`CanReadState`), 나머지 `masc_dos_*` 는 `mutating_tool`(`CanBroadcast`)이다. HTTP 쓰기 라우트는
  `with_tool_actor_auth ~tool_name` 으로 같은 표를 읽고, 그 credential 이름으로 기록한다.
  MSX 의 `POST /api/v1/msx/press` 가 이 방식으로 사람 입력을 받는다.
- **역할과 권한.** `lib/types/types_auth.ml` 의 `agent_role = Worker | Admin`,
  `permission = CanInit | CanReset | CanReadState | CanAddTask | CanClaimTask | CanCompleteTask
  | CanBroadcast | CanVote | CanAdmin`. `has_permission` 은 모든 쌍을 적은 match 다.
- **credential 발급·회수.** `Auth.create_token_expiring_in ~agent_name ~role ~hours`
  (1..8760시간)과 `Auth.delete_credential`("The bearer stops validating from the next request").
- **공개 주소의 인증.** 공개 base(`MASC_HTTP_BASE_URL`)가 loopback 이 아니면 서버는
  strict token 인증을 강제한다(`http_auth_strict_enabled`).

없는 것: DOS 사람 입력 HTTP 라우트, 이 기계만 다루는 역할, 바깥 사람이 여는 페이지,
초대 발급 흐름.

## 2. 결정

### 2.1 참가자와 이름

| 참가자 | 들어오는 길 | 기록되는 이름(`who`) |
|---|---|---|
| keeper | 지금처럼 `masc_dos_*` 도구 | keeper 이름 |
| 운영자 | TUI | 운영자 credential 이름 |
| 바깥 사람 | 플레이 페이지(§2.6) | 초대 credential 이름 |
| 외부 에이전트 | MCP, 초대 credential | 초대 credential 이름 |

이름은 credential 이 정한다. 요청이 스스로 밝힌 이름은 쓰지 않는다.

### 2.2 역할 `Player` 와 권한 `CanPlayMachine`

- `agent_role` 에 `Player`, `permission` 에 `CanPlayMachine` 을 더한다.
- `has_permission`:
  - `Player` 는 `CanPlayMachine` 만 참이다.
  - `Worker`·`Admin` 도 `CanPlayMachine` 을 가진다. keeper 와 운영자는 지금처럼 논다.
- 컴파일러가 같이 고치게 만드는 자리: `permissions_for_role`, `agent_role_to_string`/`of_string`,
  `all_agent_roles`, `multiplier_for_role`,
  `Server_auth.request_credential_standing`(→ `Player_credential` 값 추가. 운영자도 keeper 도 아니다).
- `multiplier_for_role` 은 `Player` 에게 `worker_multiplier` 를 준다. 지금 운영 코드에서 한도를 거는
  곳은 `masc_broadcast` 하나다(`lib/mcp_tool_runtime_comm.ml:49` 가 `Session.check_rate_limit` 를 부른다).
  그런데 이 wrapper 는 역할을 받지 않고 늘 `GeneralLimit` 와 `Worker` 를 넘긴다
  (`lib/session.ml:411-412`). 요청 처리기는 그 `Worker` 로 `effective_limit` 를 부르고
  (`lib/session.ml:245`), 이 함수는 `multiplier_for_role` 로 `worker_multiplier` 를 곱한다
  (`lib/types/types_auth.ml:355-366`). 그래서 지금은 부른 쪽의 실제 역할로 배수를 고르지 않고, 늘
  `Worker` 배수가 걸린다. `Player` 는 broadcast 권한도 없다. `Player` 에게 `worker_multiplier` 를 주는 이유는 `multiplier_for_role` 이 모든 역할에 값을
  내야 하기 때문이다. 따로 설정 칸을 만들면 아무도 읽지 않는 값이 된다. DOS 입력에 역할별 한도를 걸 때,
  그 호출이 실제 역할을 넘기게 바꾸고 그때 칸을 만든다.
- **보안 경계는 credential 이다.** controller 는 차례를 정할 뿐이다. 무엇을 할 수 있는지는
  credential 이, 언제 할 수 있는지는 controller 가 정한다.

### 2.3 도구와 라우트 권한

- `Tool_catalog` 에서 `masc_dos_screen`·`masc_dos_press`·`masc_dos_type`·`masc_dos_step`·
  `masc_dos_pass` 의 필요 권한을 `CanPlayMachine` 으로 바꾼다.
- `masc_dos_load`·`masc_dos_eject`·`masc_dos_restore`·`masc_dos_save`·`masc_dos_click`·`masc_dos_peek`
  은 지금 권한 그대로 둔다.
  - `load`·`eject`·`restore` 는 판 자체를 바꾼다.
  - `save` 는 조종자 없이 이름 붙은 슬롯을 덮어쓴다.
  - `peek` 은 기계 메모리를 직접 읽는다. 화면에 안 나오는 상대 세력의 값을 읽을 수 있어서
    같이 하는 판에서는 바깥 참가자에게 열지 않는다.
  - `click` 은 삼국지3 을 키로 두는 지금 방식에 필요 없다. 마우스 게임 배치가 생기면 연다.
- live 라우트를 `with_read_auth` 에서 `with_permission_auth ~permission:CanPlayMachine` 으로 바꾼다.
  `Admin`·`Worker` 는 이 권한을 가지므로 TUI 와 keeper 는 그대로 본다. `Player` 에게는 live 만
  열리고 다른 읽기 라우트(`CanReadState`)는 닫혀 있다.
- live 는 DOS 와 MSX 를 같은 라우트로 답한다. 그래서 `Player` 는 MSX 화면도 본다. 읽기뿐이라
  판을 바꾸지 못하므로 그대로 둔다. 기계마다 권한을 나누면 기계가 늘 때마다 권한이 는다.

### 2.4 초대 발급과 회수

- 발급은 `CanAdmin` 만 한다. `POST /api/v1/play/invites {name, hours}` 와 TUI `/play invite <이름> <시간>`.
  - `Auth.create_token_expiring_in_if_absent ~role:Player ~hours` 로 만든다. 기한 없는 초대는 두지 않는다.
    Auth credential transaction 하나가 이름 파일 존재 확인, 저장, token cache 무효화를 묶는다.
    라우트 밖 credential writer가 먼저 저장했으면 초대는 `Name_taken Credential`로 거절한다.
    손상된 파일·대상 없는 redirect·dangling symlink도 이미 차지한 이름이다.
  - 발급은 다음 조건에서만 한다. 조건이 안 맞으면 거절하고 무엇이 빠졌는지 말한다.
    - `MASC_HTTP_BASE_URL` 이 있다.
    - 워크스페이스 인증이 켜져 있고 `require_token = true` 다. 인증이 꺼져 있으면 모든 요청이
      `Admin` 으로, `require_token = false` 면 토큰 없는 요청이 `Worker` 로 풀린다
      (`Auth.resolve_role_with_auth_config`). 어느 쪽이든 `Player` 로 좁힌 의미가 없다.
  - 초대 이름이 이미 있는 keeper 이름이나 credential 이름과 같으면 거절한다. ledger 와 `pass` 에서
    두 참가자가 같은 이름으로 보이면 누가 눌렀는지 가를 수 없다. keeper 이름은 저장된 keeper 와
    TOML 에 선언된 keeper 를 합쳐 읽는다. 목록을 못 읽으면 충돌이 없다고 말할 수 없으니 거절한다.
  - 초대 이름은 소문자로 시작하고 소문자·숫자만 쓴다(32자까지). `-` 를 받지 않는다. `-` 가 든
    credential 이름은 생성된 별명이나 keeper 전송 별칭(`Auth_nickname`)으로 읽혀 다른 이름에
    묶일 수 있다. 이 문법이면 `Common.safe_filename` 이 이름을 바꾸지 않아, 이름 하나가 credential
    파일 하나에 대응한다.
  - 답: `{name, expires_at, link: "<base>/play#<raw token>"}`. TUI 는 링크와 QR 을 카드에 띄운다.
    - 링크는 이 카드가 유일한 사본이라 채팅 행, 푸터, 세션 로그에는 넣지 않는다. `Esc` 나 `q` 로
      닫고 `/play link` 로 다시 연다. `y` 는 링크를 터미널 클립보드로 복사한다. 자동으로
      복사하지는 않는다. Enter 는 카드를 닫지 않는다. 명령을 보내고 답이 오기 전에 Enter 를 한 번
      더 눌러도 카드는 열린 채로 남는다.
    - 카드는 이름별로 이 TUI 프로세스 메모리에만 둔다. 초대를 또 발급해도 앞 카드는 남는다.
      `/play link` 는 가장 최근 카드를, `/play link <이름>` 은 그 이름의 카드를 연다. TUI 를
      끝내거나 그 초대를 `/play revoke` 하면 지운다. 살아 있는 초대 이름은 서버에서 하나뿐이라
      이름 하나에 카드도 하나다.
    - 링크가 카드 높이보다 길면 `j`/`k`(화살표 포함)로 한 줄씩 넘기고 `g`/`G` 로 처음과 끝으로
      간다. OSC 52 를 못 쓰는 터미널에서도 링크를 끝까지 읽고 옮길 수 있어야 한다.
    - QR 은 창에 통째로 들어갈 때만 그린다. 잘린 QR 은 읽히지 않으므로 좁으면 그리지 않고
      필요한 칸과 줄 수를 알린다. 색을 못 그리는 터미널은 링크만 보여 준다.
    - 발급 요청은 한 번에 하나만 보낸다. 앞 요청의 답이 오기 전에 보낸 다음 발급 명령은 거절하고
      답을 기다리라고 알린다. 대기열에 넣지 않는다.
  - raw token 은 이 답에서 한 번만 나온다. 서버에는 SHA-256 만 남는다.
- 회수는 `CanAdmin` 만 한다. `DELETE /api/v1/play/invites/<이름>` 와 TUI `/play revoke <이름>`.
  - 같은 Auth credential transaction 안에서 현재 이름과 역할을 확인하고
    `Auth.delete_credential_in_transaction`으로 지운다. 그 transaction 안에서 조종권도 푼다.
    실제 이름 파일이 없을 때만 이미 회수된 것으로 처리한다. 파일을 읽을 수 없거나 다른 이름의
    credential로 풀리면 503으로 거절하고 credential과 조종권을 보존한다. 다른 역할은 409로 거절한다.
  - 그 이름이 조종권을 쥐고 있으면 같이 비운다. `Dos_lane.release_left ~holder ~announce` 가 이미
    "holder 가 아직 쥐고 있으면 비운다"를 한다. 떠난 사람이 쥔 조종권은 이 회수와 §2.8 의
    "떠난 조종자" 규칙으로만 푼다. 오래 가만히 있었다고 푸는 규칙은 두지 않는다.
  - credential 을 먼저 지우고 조종권을 푼다. 초대받은 사람이 지우기 전에 보낸 요청이 푼 뒤에 기계에
    닿으면 빈 조종권을 다시 잡을 수 있다. 그 이름은 더 요청을 보내지 못하므로 조종권이 묶인다.
    이 경우와 기한 지난 초대는 "떠난 조종자" 규칙이 푼다(§2.8).
- 목록: `GET /api/v1/play/invites` (`CanAdmin`). 이름, 기한, 지금 조종자인지.
  - 현재 이름 credential 의 역할과 기한을 읽는다. 이름 binding 이 사라진 뒤 남은 UUID·alias 데이터는
    초대나 넘길 대상으로 취급하지 않는다. 발견된 소유자의 현재 binding 을 읽을 수 없으면 503 으로
    답하고 조종권을 바꾸지 않는다. 소유자를 확정하지 못하는 데이터 행은 기존 발견 정책대로 제외한다.

### 2.5 DOS 사람 입력 라우트

- `POST /api/v1/dos/press`, `/type`, `/step`, `/pass`. 각각 `with_tool_actor_auth` 로
  같은 이름의 도구 권한을 건다. 몸통 모양과 오류는 `/api/v1/msx/press` 를 따른다.
  잘못된 타입의 필드는 400 으로 필드 이름을 알려 주고 기본값으로 바꾸지 않는다.
- 끝나면 도구와 같은 활동 알림을 한 번 낸다(RFC-machine-spectating-goes-through-lanes §2.2).
- 입력 추상화는 하지 않는다. 같은 RFC §3 의 이유가 그대로 맞다.

### 2.6 플레이 페이지

- 주소: `<base>/play`. HTML 과 스크립트는 공개 읽기 경로로 둔다(`Server_auth.is_public_read_path`
  에 `/play` 를 더한다). 데이터는 전부 `Authorization: Bearer` 로 부른다. 쿠키를 쓰지 않는다.
- 페이지는 외부 스크립트를 불러오지 않는다. token 을 메모리에 쥐고 있는 페이지라서다.
- 페이지가 열리면 `location.hash` 에서 token 을 읽고 바로 주소창에서 지운다
  (`history.replaceState`). token 은 메모리에만 둔다.
- 하는 일:
  - live 를 주기적으로 읽어 canvas 에 그린다. `since`·`incarnation` 을 넘겨 바뀔 때만 받는다.
  - 지금 조종자와 최근 활동을 보여 준다. 조종권이 내 이름으로 오면 "내 차례" 를 알린다.
    지금 `pass` 는 Board @mention 으로만 알리므로, 바깥 사람에게는 이 표시가 알림이다.
  - 입력: masc 패드(§2.9), 글자 입력 칸, 데스크톱 키보드. 모두 §2.5 라우트로 보낸다.
  - "넘기기": 초대된 이름과 keeper 목록에서 골라 `pass` 한다.
- 프레임은 v1 에서 `rgb8` 그대로 받는다. 320x200 이면 원본 192,000바이트, base64 로 약 256KB 이고
  압축을 거친다. 턴제라 바뀔 때만 오므로 v1 은 이대로 간다. PNG 형식은 실제 크기를 잰 뒤 따로 정한다.

### 2.7 외부 에이전트

- 초대 credential 은 `/mcp/play` 로 MCP 에 붙는다. 이 문은 `CanPlayMachine` 을 요구한다.
  `/mcp` 는 계속 `CanReadState` 를 요구하므로 초대 credential 로는 열리지 않는다.
- `/mcp/play` 는 catalog 권한이 `CanPlayMachine` 인 도구만 `tools/list` 에 보여 주고, 보여 준 도구만 부를 수 있다.
- `/mcp/play` 는 `initialize`, `server/discover`, `ping`, `tools/list`, `tools/call` 만 받는다.
  다른 메서드는 유효한 credential 이면 누구나, 또는 credential 없이도 받는 것이라 이 문에서는 거절한다.
- `/mcp/play` 는 서버 스트림을 열지 않는다. GET agent stream 과 `subscriptions/listen` 은
  작업공간 전체의 이벤트를 나른다.
- `masc_dos_screen` 은 keeper 호출에만 PNG 를 붙인다(`lib/keeper/keeper_dos_screen.ml`). 초대 credential 호출에도 프레임 이미지를
  돌려준다. 삼국지3 메뉴는 그래픽 한글이라 이미지가 없으면 읽을 수 없다.
- 외부 에이전트는 기계 입력 이름(`["down","return"]`)을 그대로 쓴다. 패드는 사람을 위한 층이다.
- 에이전트가 받는 것도 사람과 같은 링크 하나다. 링크를 열면 `/play` 페이지가 뜨고, 페이지 맨 아래 줄이
  `GET /play/agent.md`(`Play_invite.agent_guide_path`)를 가리킨다. 스크립트를 돌리지 않고 페이지를
  읽는 에이전트도 이 줄은 본다.
  - 안내문은 공개다. 토큰도 워크스페이스 상태도 담지 않는다. `#` 뒤가 bearer 토큰이라고 알려 줄 뿐이다.
  - 글은 프롬프트 `play.agent_guide`(`config/prompts/play.agent_guide.md`)에 둔다. 운영자가 override 로 고칠 수 있다.
  - 주소와 스키마는 서버가 채운다: `MASC_HTTP_BASE_URL` 뒤에 `/mcp/play`, seat, `screen.png`, §2.5 이동
    라우트 네 개. 이동마다 그 라우트가 본문을 검사하는 도구 스키마를 그대로 싣는다
    (`Server_routes_http_routes_dos.moves`). 복사본이 아니라서 스키마가 바뀌면 안내문도 같이 바뀐다.
  - `MASC_HTTP_BASE_URL` 이 없으면 들어올 주소가 없으므로 `409 not_ready` 다. 초대 발급 조건과 같다.
  - MCP 클라이언트는 Streamable HTTP 로 붙는다. 안내문에는 확인한 두 클라이언트(Claude Code, Codex)의 명령만 적고,
    나머지는 "같은 URL 과 헤더"로 적는다. MCP 를 못 쓰거나 세션 중에 서버를 더할 수 없는 에이전트(pi 등)는
    같은 자리를 HTTP 로 쓴다: seat 읽기, `screen.png`, `/api/v1/dos/{press,type,step,pass}`.

### 2.8 차례

- 차례는 `pass` 로만 바뀐다. 화면을 읽어 누구 차례인지 추측하지 않는다.
- `masc_dos_pass` 의 `to` 는 keeper 이름, 운영자(`Admin`) 이름, 기한이 남은 초대 이름을 받는다
  (`Play_seat.hand_to`, 플레이 페이지가 보여 주는 목록과 같다). 다른 이름은 거절하고 아무것도 바꾸지 않는다.
- 이 검사는 모든 요청이 credential 을 가져야 하는 워크스페이스(인증 켜짐, `require_token = true`)에서만 한다.
  초대 발급 조건과 같다. 그렇지 않은 곳에서는 이름을 스스로 정할 수 있어 명단이 없으므로 지금처럼 넘긴다.
- Keeper 가 움직이든, 플레이 페이지 라우트든, MCP 클라이언트든 같은 실행 경계
  (`Keeper_dos_controller.execute`)을 지난다.
- handoff 대상 명단 조회·떠난 조종권 해제·실제 `Dos_lane.pass`는 하나의 Auth credential transaction 안에서 진행한다.
  대상 회수가 먼저 끝나면 명단에서 빠져 거절한다. handoff가 먼저 admission을 얻으면 회수는 handoff가 끝날 때까지 기다린 뒤 그 대상의 조종권을 푼다.
  실제 DOS 변경 중에는 알림을 큐에 넣기만 하고, Board 전송은 Auth 잠금을 놓은 뒤 한다. HTTP 본문을 기다리며 이 잠금을 잡지 않는다.
  이미 인증한 요청의 주체를 다시 인증하거나 이미 발송된 요청을 취소하는 정책을 추가하지 않는다(§2.4).
- 비어 있는 조종권은 지금처럼 다음에 움직이는 쪽이 가져간다.
- "떠난 조종자"(`Keeper_dos_controller.holder_left`)는 다음 움직임 전에 풀린다.
  - 멈춘 keeper.
    - 영구히 지운 keeper(meta 삭제: `remove_meta` 종료, supervisor 정리, purge)는 다음 움직임이 알아보지 못한다.
      Keeper 자기 credential 은 만료가 없어서, meta 가 없으면 돌아올 에이전트처럼 보인다.
      그래서 그 keeper 를 지우는 종료 마무리(`Keeper_shutdown_finalize`)가 조종권을 바로 푼다(`Keeper_dos_controller.release_retired`).
  - 기한이 지난 초대. 기한은 토큰 검사와 같은 규칙(`Play_invite.expired`: 초 단위, 지금 > 기한)으로 판단해서,
    기한이 끝나는 그 초 동안은 아직 움직일 수 있는 것으로 본다.
  - 인증이 켜지고 토큰이 필수인 워크스페이스에서, keeper 가 아닌 이름 중 credential 파일이 없는 이름(회수된 초대).
    이런 곳에서는 credential 없이 기계를 움직일 수 없으므로 따로 회수 기록을 남기지 않는다.
    파일이 있는데 읽지 못하면 떠났다고 볼 근거가 없으므로 조종권을 지킨다.
    발급·회수와 같은 Auth credential transaction의 이름 파일 조회를 쓴다. ENOENT만 없는 파일이고,
    dangling symlink·대상 없는 redirect와 조회 I/O 오류는 조종권을 지킨다.
    이 경계까지 전파된 읽기 I/O 예외와 이름 파일 조회 오류는 원인을 로그에 남긴다.
  - 기한이 지난 운영자(`Admin`)·에이전트(`Worker`) credential도 인증이 강제되는 곳에서는 푼다.
    credential 갱신과 떠남 판단·조종권 해제는 같은 Auth transaction으로 직렬화된다.
    갱신이 먼저 완료되면 새 기한으로 판단하고, 해제가 먼저 완료되면 갱신된 참가자는 빈 조종권을 다시 잡는다.
  - 인증이 꺼진 곳에서는 이름을 스스로 정할 수 있어 떠났는지 알 수 없으므로, credential 이 없는 이름도 조종권을 지킨다.

### 2.9 masc 패드

바깥 사람은 기계마다 다른 입력을 몰라도 된다. 문 앞에 패드 하나를 두고, 게임마다 패드를
그 기계의 입력으로 옮긴다.

- **기계 입력은 그대로다.** 패드는 문 앞에서 기계 입력으로 바뀐 뒤 §2.5 라우트를 부른다.
  ledger 에는 지금처럼 기계 입력이 남는다.
- **버튼 이름은 Linux gamepad 규격을 따른다.** RFC-machine-spectating-goes-through-lanes §3 이
  "축·조이스틱이 필요하면 evdev 모양을 따른다"고 정해 두었다. 닫힌 타입:
  `BTN_SOUTH | BTN_EAST | BTN_NORTH | BTN_WEST | BTN_DPAD_UP | BTN_DPAD_DOWN | BTN_DPAD_LEFT
  | BTN_DPAD_RIGHT | BTN_START | BTN_SELECT | BTN_TL | BTN_TR`.
- **게임마다 배치를 둔다.** 버튼마다 `기계 입력(키 이름 목록)` 또는 `비어 있음`, 그리고 사람이
  읽을 이름. 예: `BTN_SOUTH = ["return"], "결정"`, `BTN_EAST = ["esc"], "취소"`.
  - 비어 있는 버튼을 누르면 거절하고 이유를 말한다. 기본값으로 무언가를 누르지 않는다.
  - 배치가 없는 프로그램에서는 패드가 열리지 않고 이유를 말한다. 키보드와 글자 입력 칸은 열린다.
  - 배치는 `<.masc>/dos/pads/<saves 이름>.toml` 에 둔다. 체크포인트(`<.masc>/dos/checkpoints/`)와
    같은 층이다. 프로그램 디렉터리 안에는 두지 않는다. `masc_dos_load` 는 실행 파일 옆 파일을
    DOS 에 마운트하므로, 거기 두면 배치 파일이 게임 안에서 보인다.
  - "프로그램 이름" 은 부팅한 파일이 아니라 saves 이름(`masc_dos_load` 에 준 인벤토리 이름)이다.
    Koei 의 DOS 게임은 여러 편이 같은 `KOEI.COM` 으로 부팅한다. `Dos_lane.observation.saves_name` 이 이 이름이다.
  - 워크스페이스 파일이 없으면 masc 에 들어 있는 기본 배치를 쓴다. 첫 기본 배치는 `samguk3` 하나다.
    답은 어느 쪽 배치인지(`source: workspace | builtin`) 말한다. 워크스페이스 파일이 깨져 있으면
    기본 배치로 넘어가지 않고 오류다.
  - 게임 지식(메뉴 순서, 저장 키)은 지금처럼 Skill 에 둔다. 배치는 버튼과 키의 짝만 담는다.
  - 배치 파일은 읽을 때 닫힌 타입으로 파싱한다. 모르는 버튼 이름이나 `Dos_machine.key_of_string`
    이 모르는 키 이름은 로드 오류다.
- **패드로 안 되는 입력.** 삼국지3 은 병력·금 같은 숫자와 이름을 입력한다. 글자 입력 칸
  (화면 키패드 → `/api/v1/dos/type`)을 패드 옆에 둔다.
- 폰이 주 무대다. QR 을 찍으면 화면과 터치 패드가 뜬다.
- 실제 게임패드도 같은 버튼으로 읽는다. 브라우저 Gamepad API 의 표준 매핑(0 South, 1 East, 2 West,
  3 North, 4·5 어깨, 8 Select, 9 Start, 12–15 십자키)만 읽고, 버튼을 누를 때 한 번 보낸다.

## 3. 범위

- v1 은 DOS 다. MSX 는 Lane 호출 몇 개가 아직 `~who` 를 받지 않는다
  (`server_routes_http_routes_lane_addons.ml` `with_activity` 주석). 누가 눌렀는지 남고
  차례를 가를 수 있게 된 뒤에 같은 역할·라우트·페이지로 붙인다.
- 첫 배치는 삼국지3 하나다.

## 4. 하지 않는 것

- 방 키로 봉인하는 릴레이. 서버가 곧 호스트이고 공개 주소로 닿는다.
- keeper 대화 공유와 게스트 프롬프트. 공동 플레이에 필요하지 않다.
- 화면 OCR 로 차례를 판단하는 일.
- 기계 아래의 공통 입력 이벤트.

## 5. 테스트

- 권한 표: `Player` 는 §2.3 의 다섯 도구와 live 만 통과하고, 다른 모든 도구와 읽기 라우트는
  거절된다. `Worker`·`Admin` 의 결과는 바뀌지 않는다.
- 조종자가 아닌 초대 credential 의 press 는 `Held_by` 로 거절되고 기계는 그대로다.
- `pass` 로 넘긴 뒤에는 넘겨받은 쪽의 press 만 그 이름으로 ledger 에 남는다.
- `pass` 의 `to` 에 keeper 도 초대도 아닌 이름을 주면 거절된다.
- 회수하면 다음 요청부터 거절되고, 그 이름이 쥐던 조종권이 비워진다.
- 인증이 꺼져 있거나, `require_token = false` 이거나, `MASC_HTTP_BASE_URL` 이 없으면 발급이 거절된다.
- keeper 나 기존 credential 과 같은 이름의 초대는 거절된다.
- 패드 버튼 하나는 배치가 가리키는 기계 입력으로 ledger 에 남는다. 비어 있는 버튼은 거절되고
  기계는 그대로다. 모르는 버튼 이름이 있는 배치 파일은 로드 오류다.
- 플레이 페이지: 링크로 열면 주소창에서 token 이 사라지고, 화면이 그려지고, 내 차례에 누른 키가
  들어간다.

## 6. 단계

각 PR 은 첫 단계로 손댈 자리를 코드에서 찾아 PR 본문에 적는다.

1. **역할·권한.** `Player`·`CanPlayMachine`, §2.2 의 컴파일러 자리, §2.3 의 catalog 권한
   (`lib/tool/tool_catalog.ml` `explicit_metadata`)과 live 권한.
2. **초대 발급·회수.** §2.4 의 라우트, TUI 명령, 회수 시 조종권 비우기.
3. **DOS 입력 라우트와 `pass` 대상.** §2.5, §2.8. 찾을 자리: `masc_dos_pass` 핸들러가 `to` 를 검사하는 곳.
4. **masc 패드.** 버튼 타입, 배치 파서, 삼국지3 배치 하나.
5. **플레이 페이지.** §2.6, TUI QR. 찾을 자리: 대시보드나 TUI 에 이미 있는 live 그리기 코드.
6. **MCP.** §2.7. `/mcp/play` 문(프로필 `Seat`)과 `masc_dos_screen` 이 PNG 를 붙이는 조건.

## 7. 나중에 볼 것

- live 프레임을 PNG 로 줄지. 삼국지3 화면으로 압축 뒤 크기를 잰 다음 정한다.
- MSX 참여(§3).
- 공개 릴레이. 서버에 직접 닿을 수 없는 호스트가 생기면 따로 설계한다.
