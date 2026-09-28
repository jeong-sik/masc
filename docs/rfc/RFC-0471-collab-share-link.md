---
rfc: "0471"
title: "Keeper live-session 공유 — /collab 링크·QR·join (oh-my-pi §07)"
status: Draft
created: 2026-09-28
updated: 2026-09-28
author: muse
supersedes: []
superseded_by: null
related: []
---

# RFC-0471: /collab — 링크를 건네면 들어온다

## 0. Summary

Keeper live session 을 링크 하나로 공유한다. 호스트 TUI 에서 `/collab` 을 치면
방(room)이 열리고 join 링크 + 브라우저 링크 + QR 이 출력된다. 게스트는 다른
터미널에서 `masc collab join` 으로, 또는 브라우저로 들어온다. 링크는 2종이다:
보기(view, 읽기 전용)와 조종(control, 읽기-쓰기). 세션 페이로드는 방 키로
AES-256-GCM sealed 되며, 릴레이는 불투명 바이트만 중계한다. 이 RFC 는 설계
SSOT 이고, 구현은 §6 의 stacked PR 로 나눈다. TUI join 우선, 브라우저는 그 다음이다.

Prior art: oh-my-pi README §07 (`/collab`, `omp join`, `/collab view`),
`packages/coding-agent/src/collab/` (host/guest/controller/relay-client/
protocol/crypto/registry) 및 `@oh-my-pi/pi-wire` 릴레이 규격. 토폴로지·프레임·
링크 형식은 이를 따르고, MASC 서버 내장 릴레이·Keeper chat tap·Gate 규칙은
MASC 에 맞게 둔다.

## 1. 왜 이렇게 하는가

- MASC 는 이미 서버를 돌린다(화면·MCP·대시보드가 같은 `.masc/` 를 본다).
  omp 처럼 호스트가 NAT 뒤 CLI 라서 공개 릴레이가 필수인 구조가 아니다.
  그래서 릴레이는 masc 서버 안의 라우트로 시작한다. 서버에 닿는 게스트는
  그 위치가 LAN 이든 인터넷이든 링크 하나로 들어온다.
- 진짜 NAT-traversal(양쪽 다 사설망, outbound 만으로 중계) 은 managed 공개
  릴레이가 필요하고 운영 커밋(호스팅·도메인·유지)이 따른다. §5 래더의 3단계로
  미루고, v1 은 (1) 내장 라우트 + (2) 같은 lib 를 쓰는 독립 Eio 릴레이
  바이너리(LAN/VPS 자가 호스팅)까지만 간다.
- 호스트가 권위자다. 게스트끼리는 peer 하지 않는다. 에이전트 실행·도구·모델
  호출은 전부 호스트 머신에서 돌고, 게스트는 프롬프트·중단·조회만 보낸다.
- 코어 내장이다, Lane Addon 이 아니다. 워커는 Docker 안 MCP stdio 프로세스라
  게스트를 받는 소켓을 열 수 없고, Keeper 입력 주입·TUI 표면도 기여 범위
  (observe/act, Lane row) 밖에 있다. 방 관측 지표를 Lane row 로 내보내는
  주변 패키지는 나중에 가능하다.

## 2. 설계

### 2.1 토폴로지·접속

- 릴레이 라우트: masc 서버에 `/r/<roomId>` WebSocket 라우트 추가.
  전송은 pinned `ws-direct-eio` / `httpun-ws` (`dune-project` 실측).
- 호스트 = Keeper session 을 연 TUI. 방 생성 시 relay 에 room 등록.
- 게스트 = `masc collab join <link>` TUI replica, 또는 대시보드 web viewer.
- 방 생명주기: 호스트 접속 중 유지, 호스트 종료 시 `bye` 뿌리고 닫는다.
  wall-clock 만료 없음(종료는 상태 전이이지 시간 경과가 아니다).

### 2.2 링크 형식

- `roomId` 16B, 방 키 32B, 쓰기 토큰 16B, 모두 `lib/crypto_rng` 생성.
- 터미널 링크: `<roomId>.<b64url(secret)>`
  - secret 32B(방 키만) = 보기 링크, 48B(방 키+쓰기 토큰) = 조종 링크.
  - b64url = `Base64.uri_safe_alphabet`, pad 없음
    (선례: `lib/keeper/keeper_github_app_broker.ml:57`).
- 웹 링크: `<base>/#<terminal-link>` — secret 은 fragment 에만 두어 서버·
  릴레이 로그에 남지 않는다.
- 파서는 32|48B strict decode, 실패는 `None`/typed error. 닫힌 합타입
  `View | Control` 로만 분기한다.

### 2.3 프레임·암호

- sealed JSON, envelope `[4B BE peerId][AES-256-GCM [12B IV][ct+tag]]`.
  host→relay 는 peerId 0(전체 방송)|N(지정), guest→relay 는 항상 0 이고
  릴레이가 송신자 id 로 rewrite 한다.
- 닫힌 variant + `COLLAB_PROTO` 상수:
  `hello | welcome | prompt | abort | ui-request | ui-response | agent-cmd |
  fetch-transcript | snapshot-chunk | entry | state | agents | bye | error`.
- GCM 은 `mirage-crypto` (GCM 모듈 경로는 스택 1 에서 핀).

### 2.4 호스트 tap + 스냅샷

- live tap: Keeper chat 이벤트 버스 어댑터 파이버
  (`lib/keeper/keeper_chat_broadcast.mli` 계열, 스택 3 에서 핀).
- 스냅샷: `lib/keeper/keeper_chat_event_log.mli` 저널 replay.
- `welcome{header, state, entryCount, readOnly}` 후 512KB 단위
  `snapshot-chunk{entries, final}` 전송, 이후 live `entry`/`state`/`agents`.
- `stop()` 은 `bye` 방송 후 방을 닫는다.
- 스택 3 구현 기록 (`Server_collab_host`):
  - tap 위치는 chat-stream route 의 `on_publish` (저널 append 직후,
    journal-first — 스냅샷/drain join 이 이 순서에 의존).
  - 스냅샷 op 선택: 부팅 이후 publish 를 본 keeper 는 hook 기록 exact id,
    아니면 최근 수정(mtime, 동점은 이름순) 저널. 저널 8MB 초과분은 tail
    window 만 스냅샷 (hello 한 방에 GB 를 읽지 않는다).
  - `active` 는 live 스트림에서만 추적하고 스냅샷에서 seed 하지 않는다
    (seed 레이스가 finish 를 영구히 삼키는 것보다, 다음 boundary 에서
    자가치유되는 bounded lie 가 낫다).
  - live 큐 4096, 초과분은 newest-drop + 경고 (overflow episode 당 1회).
    느린 게스트가 keeper 턴을 막지 않는다.
  - 게스트 envelope 의 sender 0·범위 밖은 drop (릴레이 rewrite 산출물만
    신뢰 — 0 을 받으면 welcome 이 broadcast 로 나가는 버그 방지).
  - 서버 종료 시 `Shutdown.register ~name:"collab_bye" ~priority:10
    stop_all` 로 게스트에게 `bye` 를 먼저 보낸다 (state flush 20-30 보다 앞).
  - 리뷰 대응 (F2/F3/F5/F6/F7/F8): forwarder 는 stop 을 보면 배치 잔량을
    버린다 (bye 뒤 entries 방지; 소켓에 이미 들어간 1건은 어쩔 수 없어서
    게스트는 post-bye 프레임을 무시한다). welcome 은 장벽이 아니다 —
    게스트는 welcome 이전 live entry 를 버퍼 후 `(op, op_seq)` 로 join
    해야 한다. tail 판독 실패는 locked 전체 판독으로 폴백, 토큰은 22자
    선검사, hello 는 세션당 직렬화, 종료 훅은 Cancel 을 삼켜 뒷 훅을
    살린다. F1(스냅샷 경로)은 양쪽 동일 sanitize 로 불일치 없음 — 기각.

### 2.5 게스트 입력 주입

- `prompt`/`abort` 는 기존 chat/stream 경로로 주입
  (`parse_keeper_chat_stream_request` → `process_single_turn`,
  `channel_user_*` speaker). 게스트 프롬프트도 모델 호출 전에 chat entry 로
  영속화된다.
- `ui-response` 는 호스트의 `ui-request` 에 답한다.
- `fetch-transcript` 는 event log 에서 읽어 `transcript` 로 답한다.
- 스택 4 구현 기록 (`Server_collab_inject` + `Collab` continuation):
  - prompt 는 `dispatch` 가 아닌 `Keeper_owner_registry.submit_operation`
    직접 호출로 Owner FIFO 에 넣는다 (세션은 `Workspace.config` 없이
    `base_dir` 만 들고 있어서). source/input 조립은
    `Gate_keeper_backend.accept_connector` 와 동일: Gate surface,
    external speaker (`guest-<peer>`), `Needs_append`.
  - chat-stream 의 dashboard continuation 은 external speaker 를 거부해서
    (`keeper_chat_operation_payload` 검증), iMessage 선례대로
    `Keeper_continuation_channel.Collab { room; user_id }` 를 신설하고
    `Gate{label="collab"}` 와 짝짓는 검증 arm 을 뒀다. 채널·게스트·방
    workspace 가 셋 다 일치해야 통과한다.
  - Collab 턴의 delivery adapter 는 fork 하지 않는다: 답은 방 live 버스로
    이미 보이므로 settle 즉시 `Ok` + `reader_gone` (reader 슬롯 누수 방지).
  - abort 는 세션이 직접 본 최신 op id 정확히 하나만 interrupt
    (mailbox-linearized; 후속 턴을 죽이지 않는다). 본 적 없으면 조용히
    `Nothing_running`.
  - prompt/abort 실패는 unicast `error`, 성공은 무음 (live 스트림이 알린다).
    transcript 조회는 view 허용: 최신 `max_bytes` (줄경계, 안 맞으면
    하드컷) + 전체 바이트 + cap 초과 플래그.
  - `ui-response` 배선은 연기: 현재 keeper 에 `ui-request` 발행자가 없어서
    답할 대상이 없다. 프레임 variant 는 예약 유지.

### 2.6 인증·Gate (v1)

- `hello` 의 쓰기 토큰을 저장 토큰과 `Eqaf` timing-safe 비교 → peer 별
  `canWrite`. 읽기 전용 peer 의 mutating 프레임은 호스트가 `error` 로 거절.
- **v1: 게스트는 `keeper_approval_queue`/`keeper_tool_approval_gate` 를 settle
  하지 않는다.** 승인은 호스트 측 `keeper_gate_mode` 대로 호스트에서만
  해결되고, 게스트 화면에는 읽기 전용으로 투영된다. (2026-09-28 사용자 확정.)
- 릴레이 계층에는 인증이 없다 (accepted risk, 리뷰 F4). 방 id 를 아는 누구든
  `?role=host` 로 방을 선점하거나 게스트 슬롯을 채울 수 있다. 읽기·조종
  권한은 sealed 계층(방 키·쓰기 토큰)이 강제하므로 ciphertext 이상은
  새나가지 않는다. 선점당하면 새 방을 열면 된다 (`/collab` 재실행).
  릴레이 계층 호스트 증명(key-commitment challenge 등)은 향후 과제 (§7).
- 스택 4 구현 기록: collab 경로에는 승인 settle 진입이 없다
  (`resolve_with_policy`/tool gate 호출 없음, 구조적으로 불가).
  게스트 턴이 승인을 만나면 호스트 표면에서만 풀리고, 게스트는 live
  `Tool_approval_requested`/`Tool_approval_settled` 로 읽기 전용 투영을 본다.

### 2.7 TUI UX (TUI 우선)

- 호스트: `/collab` → 방 생성, join 링크 + OSC-8 웹 링크 + QR(half-block
  렌더, 미지원 터미널은 URL-hint fallback) 출력. `/collab view` 는 보기 링크만.
- 게스트 replica: `bin/masc_tui_keeper_chat_{projection,live,queue}` 렌더러
  재사용. 보기 모드는 입력 레인 없이 렌더만.
- 스택 5 구현 기록 (TUI 호스트 `/collab` + QR):
  - 트리거는 HTTP: `POST /api/v1/collab/host {keeper, base_url?}` →
    `{room_id, view/control 링크, web/control_web 링크, base_url,
    resumed}`, `POST /api/v1/collab/stop {keeper}` → `{stopped}`.
    둘 다 CanAdmin. TUI 는 loader→decode→share card notice 로 그린다.
  - `base_url` 은 게스트가 다이얼하는 공개 릴레이 주소. 생략하면 요청
    authority 로 폴백 (loopback이면 카드에 경고 + `/collab
    https://host:port` 재실행 안내; live 방은 resume 되고 링크만
    다시 찍힌다).
  - `/collab` 재실행은 방을 복제하지 않는다: `live_for_keeper` 최신
    세션을 resume (`resumed:true`). `/collab view` 는 같은 방의 보기
    링크+QR 만 찍는다 (control 유출 방지용).
  - QR 인코더는 opam `qrc`(dbuenzli, pure OCaml) + `Qrc_fmt.pp_utf_8_half`
    로 결정 (§7). 미지원 터미널 fallback 은 별도 모드 없이 카드에 찍힌
    URL 텍스트 자체 (TUI 가 이미 레일 박스문자를 가정한다).
  - OSC-8: TUI 에 하이퍼링크 렌더가 없어 plain URL 을 찍는다. 터미널이
    linkify 한다.

## 3. 구현이 건드리는 표면

- 신규: `lib/collab/` (link/codec/crypto, relay route+helper, host tap,
  guest inject, 세션 프레임 타입). 첫 `.mli` 부터 닫힌 variant·strict parse.
- 수정: HTTP 라우트 등록 1곳, TUI chat 화면(`/collab`, join replica),
  대시보드 web viewer 링크 수신(스택 6).
- 금지 준수: `View|Control`·프레임 전부 닫힌 합타입, wire 문자열 비교로 분기
  금지, 방 생명주기에 숫자 게이트·TTL 금지, 하드코딩 경로 금지.

## 4. 테스트

- `test/`: 링크 encode/decode 왕복 + 32|48B strict 거부, envelope pack/unpack,
  seal/open 왕복 + 변조 거부, 방 스냅샷→live 순서, 읽기 전용 peer mutating
  거절, 호스트 종료 시 `bye`+방 정리. 릴레이는 in-memory helper 로.
- 함수 단위가 아니라 §2 동작(feature_surface 식 검증: 공유·join·보기·조종·
  종료)을 테스트한다.

## 5. 릴레이 호스팅 래더

1. 내장 라우트, localhost-first (v1).
2. 같은 `lib/collab` 을 쓰는 독립 Eio 릴레이 바이너리 (LAN/VPS 자가 호스팅).
3. managed 공개 릴레이 (deferred — 운영 커밋 필요).

## 6. 스택 분해 (각 1 stacked PR, constitution work_unit ≤20k tokens)

1. `collab-core`: 링크·envelope 코덱·GCM seal/open + 테스트. (#39564)
2. 릴레이 라우트 `/r/<roomId>` + in-memory 테스트 helper. (#39565)
3. 호스트 tap + 스냅샷(`welcome`→chunks→live). (#39584)
4. 게스트 주입 + 읽기 전용 강제 + Gate 규칙. (#39594)
5. TUI 호스트 `/collab` + QR 출력.
6. TUI guest replica + 대시보드 web viewer 링크.
7. (스택 6 이후) 같은 `lib/collab` 을 쓰는 독립 Eio 릴레이 바이너리
   (§5 래더 2단계. 릴레이 코어가 순수하고 드라이버가 얇게 분리돼 있어
   바이너리는 소켓 수락+`Collab_relay` 호출 골격만 얹으면 된다).

## 7. 미결

- [x] Mirage_crypto GCM 모듈 경로 핀: `Mirage_crypto.AES.GCM`
  (`of_secret`/`authenticate_encrypt`/`authenticate_decrypt`, 12B nonce,
  mirage-crypto 1.2.0 소스 실측. 짧은 입력·태그 불일치는 `None`, 예외 없음).
- [x] QR 인코더 dep 선택: opam `qrc` + `Qrc_fmt.pp_utf_8_half` (스택 5).
- [x] v1 에서 조종 게스트의 승인 settle 금지 확정 (2026-09-28 사용자 확정: 호스트만 승인).
- [x] v1 릴레이 범위 확정 (2026-09-28 사용자 확정: 내장+자가, managed 공개 릴레이 deferred).
- [x] 릴레이 close-code: omp 미러로 확정 (4001 room closed / 4004 no such
  room / 4009 host conflict / 4029 room full, 문자열까지 동일). 브라우저
  WebSocket 은 거부된 upgrade 의 HTTP 상태를 볼 수 없어 close 코드로만
  진단되므로, join 거절도 upgrade 후 close 로 답한다.
- [ ] envelope peer 헤더 인증 바인딩 (리뷰 F8, 스택 4 로 연기). GCM 은
  payload 만 덮고 4B 타깃은 평문이라 비-TLS WS 의 MITM 이 broadcast↔target
  을 뒤집을 수 있다 (기밀성 영향 없음, room key 공유). guest→host 는
  릴레이가 헤더를 rewrite 해서 단순 AAD 바인딩이 안 맞는다 — hello 인증
  작업(스택 4)에서 발신자 귀속 방식으로 함께 설계한다.
- [ ] 릴레이 계층 호스트 증명 (리뷰 F4 follow-up, v1 이후).
