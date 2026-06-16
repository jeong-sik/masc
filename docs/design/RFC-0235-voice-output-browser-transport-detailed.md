---
doc: "RFC-0235 detailed design"
title: "RFC-0235 상세 설계 — voice output browser transport"
status: Draft
created: 2026-06-14
rfc: "RFC-0235"
parent: "docs/rfc/RFC-0235-voice-output-browser-transport-device-routing.md"
base_ref: "origin/main a76d22deb"
---

# RFC-0235 상세 설계 — voice output browser transport

본 문서는 [RFC-0235](../rfc/RFC-0235-voice-output-browser-transport-device-routing.md)의
구현 명세다. RFC가 "무엇을 왜"를 합의한다면, 본 문서는 "어느 파일의 어느 함수를
어떻게"를 다룬다. 모든 anchor는 `origin/main` (`a76d22deb`) 기준이다.

---

## §0 현재 코드 정밀 지도 (변경 전)

| 관심 | 파일:라인 | 현재 동작 |
|---|---|---|
| TTS 진입 | `lib/voice/voice_bridge.ml:618` `agent_speak` | dedup → cleanup → endpoint fan-out → playback (성공 파일은 유지, 서빙불가만 삭제) |
| dedup | `voice_bridge.ml:619` `is_dedup_hit` | 동일 메시지 최근 재생 스킵 |
| stale 파일 정리 | `voice_bridge.ml:152-175` `cleanup_old_audio_files` | mtime > 1h (`Masc_time_constants.hour`) 파일 삭제, heartbeat에서도 호출 |
| 합성 | `lib/voice_bridge_core/voice_bridge_transport.ml:138` `speak_via_http_tts_to_file` | ElevenLabs/OpenAI → 파일 |
| 파일 경로 생성 | `voice_bridge_transport.ml:19-24` `make_audio_file` | `$MASC_BASE_PATH/audio/<ts>_<agent>.mp3` |
| 서버 재생 | `lib/voice_bridge_core/voice_bridge_core.ml:256` `run_local_playback` | afplay/ffplay/mpg123/play/open exec |
| per-agent 게이트 | `voice_bridge_core.ml:262` + `lib/voice_config/voice_config.mli:158` | `local_playback_enabled_for_agent` |
| 삭제 (서빙불가 파일만) | `voice_bridge.ml:384,451` `Sys.remove audio_file` | 384=dedup mutex hit, 451=합성실패 — 둘 다 서빙 불가. **성공 파일은 Sys.remove 없이 유지됨**. 879는 agent_speak 무관한 tone/recording 함수 |
| keeper 발화 → 브라우저 | `lib/keeper/keeper_chat_broadcast.ml:6-31` `chat_appended` | `{type;name;connector;ts_unix}` SSE, **모든 authenticated session** |
| dashboard 수신 | `dashboard/src/sse-store.ts:547-561` | `noteKeeperChatAppended(name)` 호출 → chat panel refresh |
| SSE subscriber registry | `lib/sse.mli:113-116`, `lib/types/types_core.ml:906-911` `sse_session` | `{agent_name;connected_at;last_activity;is_listening}` |
| auth 게이트 | `lib/server/server_auth.ml:21-50` | `is_loopback_host`, `base_url_has_non_loopback_host` |
| HTTP route 패턴 | `lib/server/server_dashboard_http_keeper_api.ml` | `/api/v1/keepers/:name/...` |

---

## §1 P1 상세 — 브라우저 오디오 도달 (sound reachable)

### 1.1 unguessable token 파일명 — **구현 완료 (dune build EXIT=0)**

**변경**: `make_audio_file` (`voice_bridge_transport.ml:19-24`). 시그니처 `agent_id:string -> string` → `unit -> string` (agent_id는 파일명에서 제거되어 더 이상 입력일 이유 없음).

```ocaml
let make_audio_file () =
  Voice_bridge_core.ensure_audio_dir ();
  (* token = 파일명이자 HTTP capability. agent_id는 의도적 배제: 한 keeper 운영자가
     다른 keeper 클립을 <ts>_<agent> 추측으로 열거하지 못하게. 16 bytes = 128-bit. *)
  let token = Random_id.hex ~bytes:16 in
  Filename.concat (Filename.concat (Voice_bridge_core.masc_base_dir ()) "audio") (token ^ ".mp3")
```

- **의존 해결**: 기존 `lib/random_id` (`Random_id.hex ~bytes:n`, Mirage_crypto_rng 기반) 재사용. 새 난수 유틸 불필요.
- **caller 1곳** (`voice_bridge.ml:368` `let audio_file = make_audio_file ()`) + alias(`:6`) + mli 시그니처 → 마이그레이션 완료. N-of-M 리스크 없음.
- **token 추출**: 페이로드에 token이 필요한 곳은 `Filename.basename path |> Filename.chop_extension` (§1.4). record가 아닌 string 경로 유지 + derive — 더 작은 변경.
- dune: `lib/voice_bridge_core/dune` libraries에 `masc.masc_random_id` 추가.

### 1.2 파일 라이프사이클 — **변경 불필요 (정정)**

초기 진단("합성→재생→즉시 삭제")이 틀렸음. 실제:

| 라인 | 동작 | P1 처리 |
|---|---|---|
| 384 (dedup mutex hit) | `Sys.remove` — 서빙 불가 파일 | **유지** (dedup 스킵된 발화는 브라우저로도 가면 안 됨) |
| 451 (합성 실패 error) | `Sys.remove` — 불완전 파일 | **유지** (서빙되면 안 됨) |
| 성공 path (Played/Opened/Failed/Skipped, 392/413/432) | `Sys.remove` **없음** — 파일 유지 | 변경 없음 |
| 879 | `agent_speak` 무관한 tone/recording 함수 | 무관 |

- **cleanup_old_audio_files (1h TTL)** 가 성공 파일의 실제 reaper이며, 1h은 브라우저 fetch window로 충분. heartbeat + agent_speak 시작(`:641`)에서 호출 유지.
- **결론**: P1은 라이프사이클 변경이 **필요 없다**. "이미 유지되는 파일에 HTTP 서빙만 추가"하면 끝. 근본 변경이 예상보다 작다.

### 1.3 HTTP audio route — 새 모듈

**새 파일**: `lib/server/server_voice_audio_route.ml` (+ `.mli`)

```ocaml
(** GET /api/v1/voice/audio/:token — serve synthesized clip by capability token.

    Auth: 동일 dashboard API 게이트 (server_auth.ml is_loopback /
    base_url_has_non_loopback_host). non-loopback 요청은 dashboard와 동일
    credential 요구.

    404: token 불일치 또는 reaped. 403: non-loopback 미인증. 200: audio/mpeg. *)
val handler :
  sw:Eio.Switch.t ->
  token:string ->
  headers:(string * string) list ->
  unit -> [ `Ok of string * string  (* body, mime *)
         | `NotFound
         | `Forbidden ]
```

- `server_dashboard_http_keeper_api.ml`와 같은 등록 패턴(`/api/v1/...`)으로 라우트
  테이블에 추가.
- 파일은 `$MASC_BASE_PATH/audio/<token>.mp3`에서 직접 읽기. DB 매핑 불필요(token=
  파일명).
- MIME 고정 `audio/mpeg` (현재 합성 결과가 전부 mp3). 향후 포맷 확장 시 `mime`
  메타데이터를 파일 옆에 저장 검토 — P1 non-goal.

### 1.4 `keeper_chat_appended` 페이로드 확장

**변경**: `lib/keeper/keeper_chat_broadcast.ml:6` `chat_appended` 시그니처 + payload.

```ocaml
(* 현재 *)
val chat_appended : keeper_name:string -> source:string -> unit

(* 변경 후 — audio는 선택. None이면 텍스트 전용 이벤트(기존과 동일). *)
type audio_clip = {
  token : string;             (* 1.1의 token. url은 dashboard base에서 조립 *)
  mime : string;              (* "audio/mpeg" *)
  duration_sec : float option;
  message_text : string;      (* 자막/접근성 fallback *)
}

val chat_appended :
  keeper_name:string ->
  source:string ->
  ?audio:audio_clip ->
  unit -> unit
```

- payload에 `?audio` present 시 `("audio", `Assoc [...])` 필드 추가. absent면 기존
  4-필드 이벤트와 bit-identical (후방호환).
- **필드명 주의**: 기존 `connector`/`source` boundary 규칙(`chat_appended` 주석 참조)
  준수. 새 `audio` 필드는 별개 boundary.
- emit 지점(`server_routes_http_keeper_stream.ml:669,716` 등 caller 전수)에 `?audio`
  전파. keeper가 `keeper_voice_speak`로 발화한 경우에만 `audio`를 채운다.

### 1.5 dashboard — decode + audio element

**변경**: `dashboard/src/sse-store.ts:547-561` + keeper chat panel.

- SSE edge에서 `audio` 필드를 **한 번** typed record로 decode:
  ```ts
  type AudioClip = { token: string; mime: string; durationSec: number | null; messageText: string }
  ```
- chat panel이 오디오가 있는 메시지를 렌더할 때:
  - 접근성 play 버튼 (`<button aria-label="재생">`) → 클릭 시 `new Audio(url).play()`.
  - 자막 = `messageText`.
  - **autoplay 금지**: 모바일 autoplay 정책 + 사용자 제스처 원칙. 자동 재생 코드 없음.
- url 조립: `${dashboardBase}/api/v1/voice/audio/${token}`. `dashboardBase`는 이미
  SSE/HTTP가 쓰는 base.

---

## §2 P2 상세 — 접속 디바이스 라우팅 ("connected device only")

### 2.1 `resolve_destination`

**새 모듈**: `lib/voice_destination.ml` (또는 `lib/sse_destination.ml`)

```ocaml
type playback_destination = Browsers | Local

(** keeper_name에 연결된 SSE subscriber ≥1 이면 Browsers, 아니면 Local.
    SSE registry (lib/sse.ml external_subscriber_count_with_prefix /
    sse_session.agent_name)에서 결정. stateless — 매 호출마다 registry 읽기. *)
val resolve_destination : keeper_name:string -> unit -> playback_destination
```

- 구현 전 확인: `external_subscriber_count_with_prefix`의 prefix가 keeper_name과
  어떻게 매핑되는지 (`rg 'prefix\|agent_name' lib/sse.ml`). subscriber 등록 시
  keeper_name이 prefix로 쓰이는지, 아니면 별도 인덱스인지.

### 2.2 라우팅 분기 — `agent_speak`

**변경**: `voice_bridge.ml` (합성 후, playback 전).

```ocaml
let dest = Voice_destination.resolve_destination ~keeper_name:agent_id in
match dest with
| Browsers ->
  (* audio_clip 생성 후 keeper_chat_appended ?audio 전파.
     run_local_playback 건너뜀 (정책 §1.5). *)
| Local ->
  (* 기존 run_local_playback 경로. audio_clip 없이 텍스트만 broadcast. *)
```

- `agent_speak`가 `keeper_name`을 알아야 함 — 현재는 `agent_id`만. agent_id ==
  keeper_name인지 확인 (`safe_agent_id` / keeper 매핑). 다르면 caller에서 keeper_name
  전파.

### 2.3 브로드캐스트 스코핑 — 핵심 트레이드오프 (owner 결정 필요)

현재 `chat_appended`는 **모든 authenticated session**에 브로드캐스트
(`keeper_chat_broadcast.mli` 명시, "low-frequency chat turns"에 적합). 오디오
이벤트의 "접속 디바이스만" 정책과 두 가지 충돌 해결:

| 옵션 | 동작 | 장점 | 단점 |
|---|---|---|---|
| **(a) keeper-scoped broadcast** | 오디오 이벤트를 해당 keeper 접속 session에만 전송 | 정책 정확히 부합; 메타데이터(발화 시각) 노출 최소 | `chat_appended` 설계 변경; RFC-0223 P4도 같은 채널 사용 — 영향도 확인 |
| **(b) 전송은 그대로, 브라우저 자체 필터** | 모든 session에 가되, 브라우저가 "내 keeper"일 때만 재생 | broadcast 변경 없음; 구현 단순 | 모든 운영자에게 token URL 노출(token 자체는 unguessable이라 접근 불가, but 메타데이터 노출) |

**권장**: (a). "접속 디바이스만"이 token 노출이 아니라 *이벤트 자체* 스코핑을 의미한다면
(a)가 정답. (a) 구현은 `Sse.broadcast`에 keeper_name scope 매개변수 추가 또는
subscriber registry에서 keeper_name match 필터.

**owner 결정 필요**: (a) vs (b). 이 결정이 P2 PR의 분기를 갈라놓는다.

### 2.4 local suppress 정책

`local_playback_enabled_for_agent` (`voice_config.mli:158`) 재해석:
- 현재: "이 agent는 local 재생 허용"
- 변경: "이 agent는 `Local` destination 허용" — destination이 `Browsers`면 이 플래그와
  무관하게 local 미실행. destination이 `Local`이고 플래그 true일 때만 local 실행.
- config escape hatch (RFC §4 P2 open question): owner가 "접속 디바이스 + local 동시"를
  원하면 별도 config `voice.playback.always_local: bool` 추가. RFC 기본값은 false.

---

## §3 테스트 명세 (구체적 케이스)

### Unit (OCaml, `dune runtest`)
1. `make_audio_file` token 길이 ≥ 16 bytes (128-bit), 두 호출이 다른 token.
2. `cleanup_old_audio_files`: 59분 파일 보존 / 61분 파일 삭제 (mtime mock).
3. `resolve_destination`: subscriber 0 → `Local`, subscriber 1 → `Browsers`.
4. `chat_appended ?audio:None` payload가 기존 4-필드와 동일 (후방호환).
5. `chat_appended ?audio:(Some clip)` payload에 `audio`_assoc 포함, 4필드 round-trip.

### 통합 (HTTP)
6. `GET /api/v1/voice/audio/<valid_token>` → 200 `audio/mpeg`, body = 파일 내용.
7. `GET /api/v1/voice/audio/<unknown>` → 404.
8. non-loopback 미인증 → 403 (dashboard auth 게이트와 동일).
9. reaped 파일 (cleanup 후) → 404.

### 통합 (라우팅, P2)
10. subscriber 등록 상태에서 `agent_speak` → `run_local_playback` 호출 안 됨 (mock으로
    검증), `chat_appended ?audio` 전파됨.
11. subscriber 없을 때 → `run_local_playback` 호출, `audio` None.

### 수동 (모바일, HTTPS tunnel)
12. 모바일 브라우저에서 keeper 발화 → play 버튼 클릭 시 재생.
13. 접속 중 서버 스피커 무음 (정책 확인).
14. 브라우저 탭 종료 후 다음 발화 → 서버 스피커 복원 (Local fallback).

### Dashboard (vitest)
15. `audio` 필드 있는 이벤트 decode → `AudioClip` record.
16. `audio` 없는 이벤트 → 기존 텍스트 전용 렌더 (회귀 없음).
17. play 버튼 클릭 → `Audio.play` 호출 (autoplay 아님).

---

## §4 구현 순서 + 파일 체크리스트

### P1 (한 PR)
1. `make_audio_file` record화 + caller 전수 마이그레이션 (`voice_bridge_transport.ml`,
   callers via `rg`).
2. `voice_bridge.ml:879` `Sys.remove` 제거 + 주석. (`:384` 제거, `:451` 유지)
3. `lib/server/server_voice_audio_route.ml` 새 모듈 + 라우트 등록 + auth 게이트.
4. `keeper_chat_broadcast.ml` `?audio` 확장 + caller에 `?audio` 전파
   (`server_routes_http_keeper_stream.ml:669,716` 등).
5. dashboard `sse-store.ts` decode + chat panel audio element + play 버튼.
6. 테스트: §3 케이스 1-9, 15-17.

### P2 (별도 PR, P1 머지 후)
7. `lib/voice_destination.ml` `resolve_destination`.
8. `agent_speak` 라우팅 분기 + `keeper_name` 전파.
9. 브로드캐스트 스코핑 (owner가 (a) 선택 시 `Sse.broadcast` keeper scope).
10. `local_playback_enabled_for_agent` 재해석 + config escape hatch.
11. 테스트: §3 케이스 10-11, 12-14 수동.

### 건드리지 않을 것 (보호)
- OAS (`lib/oas*`) — voice는 MASC 개념, 경계 유지.
- 기존 dedup (`is_dedup_hit`), duration probe (`audio_duration_seconds`) — 동작 변경 없음.
- `cleanup_old_audio_files` TTL 값 (1h) — 그대로.
- keeper_chat JSONL 스키마 — audio는 SSE 전용 페이로드, 디스크에 별도 저장 안 함.

---

## §5 열린 구현 질문 (owner 결정 필요)

1. **브로드캐스트 스코핑 (§2.3)**: (a) keeper-scoped vs (b) 브라우저 필터. **권장 (a)**.
2. **`Masc_random.token` 기존 유틸 존재 여부 (§1.1)**: 구현 전 `rg`로 확인. 없으면 추가.
3. **agent_id vs keeper_name (§2.2)**: `agent_speak`가 keeper_name을 알아야. 매핑 확인.
4. **config escape hatch (§2.4)**: "항상 local 추가 재생" config 필요 여부. RFC 기본 false.
5. **P1/P2 단일 PR vs 분리 (RFC §4)**: 분리 권장. 병렬 재생 상태를 main에 올리지 않으려면
   P1+P2 단일 PR도 가능 (PR 크기 증가).
