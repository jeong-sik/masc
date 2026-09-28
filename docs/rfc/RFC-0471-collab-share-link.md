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

### 2.5 게스트 입력 주입

- `prompt`/`abort` 는 기존 chat/stream 경로로 주입
  (`parse_keeper_chat_stream_request` → `process_single_turn`,
  `channel_user_*` speaker). 게스트 프롬프트도 모델 호출 전에 chat entry 로
  영속화된다.
- `ui-response` 는 호스트의 `ui-request` 에 답한다.
- `fetch-transcript` 는 event log 에서 읽어 `transcript` 로 답한다.

### 2.6 인증·Gate (v1)

- `hello` 의 쓰기 토큰을 저장 토큰과 `Eqaf` timing-safe 비교 → peer 별
  `canWrite`. 읽기 전용 peer 의 mutating 프레임은 호스트가 `error` 로 거절.
- **v1: 게스트는 `keeper_approval_queue`/`keeper_tool_approval_gate` 를 settle
  하지 않는다.** 승인은 호스트 측 `keeper_gate_mode` 대로 호스트에서만
  해결되고, 게스트 화면에는 읽기 전용으로 투영된다. (2026-09-28 사용자 확정.)

### 2.7 TUI UX (TUI 우선)

- 호스트: `/collab` → 방 생성, join 링크 + OSC-8 웹 링크 + QR(half-block
  렌더, 미지원 터미널은 URL-hint fallback) 출력. `/collab view` 는 보기 링크만.
- 게스트 replica: `bin/masc_tui_keeper_chat_{projection,live,queue}` 렌더러
  재사용. 보기 모드는 입력 레인 없이 렌더만.
- QR 인코더 dep 은 스택 5 에서 결정 (`ocaml-qr-code` vs vendored).

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

1. `collab-core`: 링크·envelope 코덱·GCM seal/open + 테스트.
2. 릴레이 라우트 `/r/<roomId>` + in-memory 테스트 helper.
3. 호스트 tap + 스냅샷(`welcome`→chunks→live).
4. 게스트 주입 + 읽기 전용 강제 + Gate 규칙.
5. TUI 호스트 `/collab` + QR 출력.
6. TUI guest replica + 대시보드 web viewer 링크.

## 7. 미결

- [x] Mirage_crypto GCM 모듈 경로 핀: `Mirage_crypto.AES.GCM`
  (`of_secret`/`authenticate_encrypt`/`authenticate_decrypt`, 12B nonce,
  mirage-crypto 1.2.0 소스 실측. 짧은 입력·태그 불일치는 `None`, 예외 없음).
- [ ] QR 인코더 dep 선택 (스택 5 에서).
- [x] v1 에서 조종 게스트의 승인 settle 금지 확정 (2026-09-28 사용자 확정: 호스트만 승인).
- [x] v1 릴레이 범위 확정 (2026-09-28 사용자 확정: 내장+자가, managed 공개 릴레이 deferred).
- [ ] 릴레이 close-code 를 omp(`4001/4004/4009/4029`) 미러 여부 (스택 2 에서).
