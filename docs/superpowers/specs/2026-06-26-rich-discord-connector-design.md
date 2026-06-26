# Rich Discord Connector — Phase 1~3 Design

## Context

MASC의 Discord 커넥터는 이미 in-process gateway, REST 발신, 타이핑 표시, 스트리밍 메시지 수정, presence 연동까지 갖추고 있다. 최근 `<@snowflake>` 멘션을 `@DisplayName`으로 치환하는 작업(#22400)을 통해 사용자 멘션은 해결했지만, 역할/채널 멘션, 첨부파일, embed, slash command 등은 여전히 미지원 또는 부분 지원 상태다. 이 문서는 Discord 연동을 "스펙 오버구현" 수준으로 끌어올리기 위한 3단계 설계를 정의한다.

## Goals

1. **Phase 1 — Live guild cache + 멘션 렌더링**
   - Gateway 이벤트로 guild, role, channel, member 이름을 캐시한다.
   - `<@user>`, `<@!user>`, `<@&role>`, `<#channel>`을 모두 사람이 읽을 수 있는 형태로 해석한다.
   - 대시보드에서 멘션에 Discord 딥링크 + 원본 ID fallback UI를 제공한다.

2. **Phase 2 — 풍부한 아웃바운드 메시지**
   - keeper 출력의 rich blocks(image, audio, file, link, tool result)를 Discord embed/attachment로 변환한다.
   - multipart file upload를 지원한다.
   - 마크다운 구조를 해치지 않는 청킹과 Discord embed 한도(10 embeds, 25 fields, 6000 chars)를 준수한다.

3. **Phase 3 — 슬래시 커맨드 + 인터랙션**
   - 부팅 시 Discord에 slash command를 등록하고, `INTERACTION_CREATE`를 수신한다.
   - Deferred response + webhook edit로 긴 keeper 턴을 처리한다.
   - `/ask <keeper> <prompt>`, `/status` 등의 명령을 지원한다.

## Non-goals

- Discord bot이 아닌 third-party OAuth/로그인 기능은 다루지 않는다.
- Voice channel 입장/송출은 다루지 않는다(RFC-0235 영역).
- Gateway zlib-stream 압축은 별도 RFC로 분리한다(성능 최적화이며 기능 추가가 아님).

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────────┐
│                        Discord Gateway                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ GatewayState  │  │ DiscordCache │  │ DiscordInteractions  │  │
│  │  (decode)     │  │ (guild/role/  │  │  (slash commands)    │  │
│  │               │  │  channel/user)│  │                      │  │
│  └──────┬────────┘  └──────┬───────┘  └──────────┬───────────┘  │
└─────────┼──────────────────┼─────────────────────┼──────────────┘
          │                  │                     │
          ▼                  ▼                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                 lib/server/server_discord_in_process_gateway.ml  │
│                      (trigger policy + dispatch)                  │
└─────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│              lib/gate/channel_gate_discord_state.ml              │
│         (binding resolution + Discord REST call orchestration)    │
└─────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│              lib/gate/discord_rest_client.ml                     │
│    (send_message, edit_message, multipart upload, embed builder) │
└─────────────────────────────────────────────────────────────────┘
```

새로 추가할 핵심 모듈은 다음 세 가지다.

- `Discord_cache`: Eio 스위치 기반 in-memory cache. guild/role/channel/member 데이터를 보관하고 TTL + evict 정책을 가진다.
- `Discord_renderer`: MASC rich blocks → Discord payload(embeds, components, attachments) 변환. chunking과 budget enforcement도 담당.
- `Discord_interactions`: slash command 등록, interaction signature 검증, deferred response 관리.

## Phase 1 — Live Guild Cache + 멘션 렌더링

### 1.1 Gateway 이벤트 수집

`discord_gateway_state.ml`의 `dispatched_event`에 아래 이벤트를 추가한다.

```ocaml
type dispatched_event =
  | ...
  | Guild_available of { guild_id : string; name : string; roles : role list; channels : channel list }
  | Guild_unavailable of { guild_id : string }
  | Role_update of { guild_id : string; role : role }
  | Role_delete of { guild_id : string; role_id : string }
  | Channel_update of { guild_id : string option; channel : channel }
  | Channel_delete of { channel_id : string }
  | Guild_member_update of { guild_id : string; user_id : string; nickname : string option; user_name : string option }
```

`Guild_available`은 `GUILD_CREATE` 대신 `READY` 이후의 `GUILD_CREATE`와 별개로, bot이 접속한 guild의 스냅샷을 제공한다. `GUILD_UPDATE`는 무시하고 `GUILD_DELETE`/`GUILD_UNAVAILABLE`는 evict trigger로 사용한다.

### 1.2 Cache module

```ocaml
(* lib/gate/discord_cache.mli *)

type t

val create : sw:Eio.Switch.t -> env:<clock : _ Eio.Time.clock> -> ttl_seconds:int -> t

val record_guild : t -> guild_id:string -> name:string -> unit
val record_role : t -> guild_id:string -> role_id:string -> name:string -> unit
val record_channel : t -> guild_id:string option -> channel_id:string -> name:string -> kind:string -> unit
val record_member : t -> guild_id:string -> user_id:string -> display_name:string option -> username:string option -> unit

val evict_guild : t -> guild_id:string -> unit
val evict_channel : t -> channel_id:string -> unit
val evict_role : t -> guild_id:string -> role_id:string -> unit

val resolve_user_name : t -> user_id:string -> string option
val resolve_role_name : t -> guild_id:string -> role_id:string -> string option
val resolve_channel_name : t -> guild_id:string -> channel_id:string -> string option
```

- `resolve_user_name`은 길드 멤버 캐시를 먼저 확인하여 nickname 또는 global name을 반환하고, 없으면 `Discord_gateway_state`가 이미 해석한 `mentions` 배열의 사용자 이름을 사용한다.
- TTL은 기본 1시간. `Guild_unavailable`/`Channel_delete`/`Role_delete` 수신 시 즉시 evict.
- 모든 lookup은 fiber-safe한 `Eio.Mutex`로 보호한다.

### 1.3 멘션 해석 확장

`discord_gateway_state.ml`의 `resolve_mentions`에 `Discord_cache.t option`을 인자로 추가한다.

```ocaml
val resolve_mentions :
  ?cache:Discord_cache.t ->
  mentions:(string * string) list ->
  guild_id:string option ->
  string ->
  string * resolved_mention list
```

- `<@user>` / `<@!user>`: `mentions` 배열 → cache → fallback to raw id.
- `<@&role>`: cache lookup. 이름이 없으면 raw 유지하되 `resolved_mention`에는 `Role_mention`으로 기록.
- `<#channel>`: cache lookup. 이름이 없으면 raw 유지하되 `Channel_mention`으로 기록.

`Message_create` 레코드는 이미 `raw_content`와 `resolved_mentions`를 포함하고 있으므로, `content`만 바뀌고 메타데이터는 그대로 활용 가능하다.

### 1.4 대시보드 렌더링

`dashboard/src/components/chat/primitives.ts`의 `ChatMessageBubble`에서 `entry.resolved_mentions`가 있으면:

- `@이름` 링크 클릭 시 `https://discord.com/users/<id>` 또는 `https://discord.com/channels/<guild>/<channel>`로 이동.
- 툴팁에 원본 raw 멘션(`<@14899...>`) 표시.
- 이름을 모를 때는 `@unknown-user` 스타일로 회색 처리.

Phase 1 마무리 기준:
- `<@&role>`와 `<#channel>`도 `<@user>`처럼 이름으로 표시된다.
- 대시보드에서 멘션 위에 마우스를 올리면 원본 ID가 보인다.

## Phase 2 — 풍부한 아웃바운드 메시지

### 2.1 Rich blocks → Discord payload

`lib/keeper/keeper_chat_discord.ml`은 레거시 어댑터 루프용이고, in-process gateway는 `server_discord_in_process_gateway.ml`에서 직접 발신한다. 두 경로를 통일하기 위해 `Discord_renderer` 모듈을 추가한다.

```ocaml
(* lib/gate/discord_renderer.mli *)

type discord_payload =
  { content : string option
  ; embeds : Yojson.Safe.t list
  ; attachments : attachment_spec list
  ; components : Yojson.Safe.t list option
  }

val render_blocks :
  ?max_content_length:int ->
  ?max_embeds:int ->
  ?max_total_chars:int ->
  Block.t list ->
  discord_payload list
```

- `TextBlock` → `content` 또는 `embed.description`
- `LinkBlock` → embed with URL + description
- `ImageBlock` → embed image URL 또는 multipart upload
- `AudioBlock`/`FileBlock` → multipart upload
- `ToolResultBlock` → embed with fields(title, output, status color)
- `ImageBlock`이 URL이 아닌 바이너리로 전달되면 multipart upload

### 2.2 Multipart upload

`discord_rest_client.ml`에 추가:

```ocaml
val send_message_multipart :
  t ->
  channel_id:string ->
  content:string option ->
  embeds:Yojson.Safe.t list ->
  attachments:attachment_stream list ->
  (message_response, _) result
```

- `attachment_stream`은 `Eio.Flow.source` + filename + content_type + optional description.
- 8MB(guild 부스트 없는 일반 서버) 또는 25MB(Nitro 부스트) 제한은 `Discord_renderer`에서 사전 검사. 초과 시 URL만 embed로 남기고 파일은 보관 링크로 fallback.

### 2.3 마크다운-aware chunking

현재 `send_message`는 2000 Unicode scalar 기준으로 자른다. 이를 개선하여:

- 코드 펜스(```), 인라인 코드(`), 링크 `[text](url)`, 리스트, 표 경계를 넘지 않도록 분할.
- embed description은 4096자, field value는 1024자, 전체 embed 총합 6000자 제한 준수.
- chunking 단위는 `Discord_payload_chunk.t`로 추상화하여 나중에 다른 connector에서도 재사용 가능.

### 2.4 Embed budget enforcement

`Discord_renderer.render_blocks`는 다음을 보장한다.

- embed 개수 ≤ 10
- field 개수 ≤ 25
- embed 전체 문자 ≤ 6000
- 초과 시 "... 외 N개" 축약 메시지 추가

Phase 2 마무리 기준:
- keeper가 이미지/파일/오디오/툴 결과를 출력하면 Discord에서 embed 또는 첨부파일로 보인다.
- 2000자 넘는 답변도 코드 블록이 안 찢어지고 여러 메시지로 나뉜다.

## Phase 3 — Slash Commands + Interactions

### 3.1 Command registration

부팅 시(`server_discord_in_process_gateway.start` 또는 별도 `Discord_interactions.register_commands`) Discord에 길드 명령(guild commands)으로 등록한다. 길드 명령은 전역 슬래시 커맨드보다 테스트와 롤아웋이 쉽고, `/bind`처럼 서버별 권한이 필요한 명령에 적합하다. `DISCORD_APPLICATION_ID`는 env에서 읽어온다.

```json
{
  "name": "ask",
  "description": "Ask a keeper a question",
  "type": 1,
  "options": [
    { "name": "keeper", "description": "Keeper name", "type": 3, "required": true },
    { "name": "prompt", "description": "Your question", "type": 3, "required": true }
  ]
}
```

추가 명령:
- `/status` — 현재 bound keeper 목록과 상태
- `/bind <keeper> <channel>` — dashboard 외에도 채널 바인딩(권한 체크 필요)

등록은 멱등적으로 수행: 기존 command hash 비교 후 변경 시에만 `PUT`.

### 3.2 Interaction 수신 및 검증

`discord_gateway_state.ml`에 `Interaction_create` 이벤트 추가.

```ocaml
| Interaction_create of
    { interaction_id : string
    ; application_id : string
    ; interaction_token : string
    ; guild_id : string option
    ; channel_id : string
    ; user_id : string
    ; user_name : string option
    ; command_name : string
    ; options : (string * string) list
    }
```

`Discord_interactions.verify_signature`는 Ed25519로 `X-Signature-Ed25519` + `X-Signature-Timestamp` + body를 검증. HTTP webhook 수신 시에도 동일 검증 적용.

### 3.3 Deferred response flow

1. Gateway/HTTP가 `INTERACTION_CREATE` 수신.
2. 즉시 `POST /interactions/{id}/{token}/callback`로 `type: 5`(DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE) 회신.
3. keeper 턴 시작.
4. `Channel_gate_discord_state`에서 `PATCH /webhooks/{app_id}/{token}/messages/@original`로 streaming edit.
5. 턴 종료 후 final edit. overflow는 follow-up webhook message로 분리.

### 3.4 권한 및 보안

- slash command는 bound channel에서만 keeper를 호출할 수 있다. unbound 채널에서는 `/status`만 가능.
- `/bind`는 서버 관리자 권한(`MANAGE_CHANNELS`) 또는 dashboard 인증된 operator만 사용 가능.
- interaction signature 검증 실패 시 401 Unauthorized.

Phase 3 마무리 기준:
- 사용자가 `/ask sangsu 오늘 뭐 먹을까?`라고 치면 keeper 턴이 시작된다.
- 긴 답변도 "sangsu is thinking..." deferred 메시지를 수정하며 표시된다.

## Cross-cutting Concerns

### Rate limiting

Phase 2에서 `discord_rest_client.ml`에 Discord `X-RateLimit-*` 헤더 파싱을 추가한다.

- `X-RateLimit-Remaining: 0`이면 `Retry-After` ms만큼 sleep 후 재시도.
- edit/send queue는 Eio fiber + `Eio.Stream` 기반. global, guild, channel bucket을 분리.
- observability counter: `masc_discord_rate_limit_wait_seconds_total`.

### Observability

`discord_observability.ml`에 추가:

- `discord_cache_hit_total{kind="user|role|channel"}`
- `discord_cache_miss_total{kind="user|role|channel"}`
- `discord_render_fallback_total{reason="embed_limit|file_size|unsupported_block"}`
- `discord_interaction_latency_seconds`
- `discord_multipart_upload_bytes_total`

### Testing strategy

각 phase마다 다음 테스트 추가.

1. **Pure unit tests**
   - `test_discord_cache.ml`: TTL, evict, hit/miss
   - `test_discord_renderer.ml`: block → payload, budget enforcement, chunking
   - `test_discord_interactions.ml`: signature verification, command parsing

2. **Fixture-based gateway tests**
   - `test_discord_gateway_state.ml`: `GUILD_CREATE`, `INTERACTION_CREATE` 디코딩

3. **Integration-shaped tests**
   - `test_channel_gate_discord_state.ml`: mock REST client로 multipart upload, deferred response 검증

### Security

- Ed25519 public key는 `DISCORD_PUBLIC_KEY` env var로 주입.
- multipart filename은 sanitize(`..`, `/`, null byte 제거).
- `/bind`는 반드시 interaction의 `member.permissions`를 확인.

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Guild cache memory growth | per-guild TTL + max entry limit; evict on `GUILD_DELETE` |
| Slash command registration delay | async registration; failure는 non-fatal warning |
| Interaction signature complexity | `Discord_interactions` 모듈에 집중; libsodium/mirage-crypto-ed25519 사용 |
| Markdown chunking edge cases | AST 기반 파서 대신 safe boundary set 사용; fuzz fixture 추가 |
| Rate-limit queue blocking | timeout + circuit breaker; dashboard에 health 표시 |

## Success Criteria

- Phase 1: `<@&role>`와 `<#channel>`이 대시보드에서 이름으로 표시되고, `@이름` 클릭 시 Discord 딥링크가 열린다.
- Phase 2: keeper가 이미지/파일/툴 결과를 출력하면 Discord에서 정상 렌더링되며, 2000자 이상 답변도 코드 블록이 안 찢긴다.
- Phase 3: `/ask <keeper>`로 keeper 턴 시작, deferred response + streaming edit 동작.

## Appendix: Type Summary

```ocaml
type role = { role_id : string; name : string; guild_id : string }
type channel = { channel_id : string; name : string; kind : string; guild_id : string option }
type guild_member = { user_id : string; guild_id : string; display_name : string option; username : string option }

type resolved_mention =
  { mention_id : string
  ; mention_name : string option
  ; mention_kind : mention_kind (* User_mention | Role_mention | Channel_mention *)
  ; raw_mention : string
  }

type discord_payload =
  { content : string option
  ; embeds : Yojson.Safe.t list
  ; attachments : attachment_spec list
  ; components : Yojson.Safe.t list option
  }
```
