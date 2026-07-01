# RFC-0301: Keeper 생성 미디어(이미지/오디오) 대시보드 노출

- Status: Draft
- Author: codex-mcp-client (Claude Opus 4.8)
- Date: 2026-06-30
- Related: RFC-0235 (voice-output browser transport), RFC-0236 (voice-input browser transport), RFC-0164 (voice tool abstraction integrity), RFC-0037 (board multimedia/vision)
- Tracking: task-1590

## 1. 문제

모델이 생성한 미디어(이미지/오디오/문서)가 키퍼 채팅 대시보드에 **표시되지 않는다**. 텍스트/thinking/tool은 노출되는데 생성 미디어만 누락된다.

### 1.1 경계 분석 — 데이터는 어디까지 오는가

OAS는 미디어 데이터를 **완전히 surface한다** (MASC는 OAS를 소비; OAS는 MASC를 모름):

- 스트리밍 델타: `oas/lib/llm_provider/types.ml:462-471` `MediaDelta { media_type; source_type; data : string }` — 주석: "Carries the block-level media_type and source_type alongside the data payload ... the accumulator records the metadata (idempotent across chunks) and concatenates data."
- 최종 content block: 동 `types.ml:278-292` `Image / Document / Audio of { media_type; data : string; source_type }`.
- `media_source_kind = Base64 | Url | File_id` (`types.ml:225-228`).

즉 **OAS는 실제 페이로드(base64/url/file_id)를 전달**한다. OAS 측 변경은 필요 없다.

### 1.2 근본 원인 — MASC 브릿지가 데이터를 카운트로 축소

MASC가 OAS 스트림을 키퍼 채팅 이벤트로 변환하는 브릿지에서 **데이터를 byte-count로 축소**한다:

```
lib/keeper/keeper_chat_oas_stream_bridge.ml:85-91
| ContentBlockDelta { index; delta = MediaDelta { media_type; source_type; data } } ->
    { bridge_state;
      chat_events =
        [ Oas_media_delta { index; media_type; source_type; bytes = String.length data } ] }
```

타입 자체가 카운트만 운반한다:

```
lib/keeper/keeper_chat_events.ml:50-54
| Oas_media_delta of { index : int; media_type : string;
                       source_type : Agent_sdk.Types.media_source_kind; bytes : int }
```

이후:
- SSE emit `lib/server/server_routes_http_keeper_stream.ml:1179-1192`가 `{index,media_type,source_type,bytes}`(카운트)를 KEEPER_MEDIA_DELTA로 전송.
- frontend `dashboard/src/keeper-stream.ts:321-322` `KEEPER_MEDIA_DELTA` 핸들러가 `setAssistantStreamState(...'streaming')`만 호출하고 이벤트를 **폐기**(return null). media accumulator 없음, 블록 emission 없음.
- `dashboard/src/types/core.ts:837,835`의 `ChatImageBlock`/`ChatVoiceBlock`는 존재하나 생성 미디어 경로에서 아무도 populate하지 않음.

이는 **"telemetry-as-fix" 안티패턴이 프로토콜 shape에 박힌 형태**다 — 데이터 채널이어야 할 자리에 카운트(관측치)를 넣었다. 데이터는 OAS에서 가용했으나 경계에서 의도적으로 버려졌다.

### 1.3 영향 범위

- 모델 생성 이미지/오디오/문서가 키퍼 채팅에 0% 노출.
- 멀티모달 출력 기능이 end-to-end로 비가시 (입력 경로는 wired: `dashboard/src/api/keeper.ts:502-564`).

## 2. 목표 / 비목표

목표:
1. 모델 생성 미디어를 키퍼 채팅에 라이브 + reload 양쪽에서 노출.
2. 경계 규칙 준수: OAS 변경 없이 MASC 소비 측에서 해결.
3. count-only 안티패턴 제거 (augment가 아니라 replace).

비목표:
- 멀티모달 **입력**(이미 wired) 변경.
- 미디어 편집/변환/썸네일.
- 텍스트 인터리빙(task-1592) / reload-thinking(task-1591) — 별도 트랙.

## 3. 설계 옵션

### Option A — base64 데이터를 스트림으로 관통

`Oas_media_delta`가 `bytes:int` 대신 `data:string`을 운반. SSE가 base64 청크를 전달, frontend가 `Oas_content_block_stop`에서 누적해 `ChatImageBlock`/`ChatVoiceBlock` emit. 페르시스턴스는 `keeper_chat_blocks.ml`의 기존 `Image`/`Voice` 블록(:93,:95)에 base64 data URL로 저장.

- 장점: 새 스토리지/route 불필요. 데이터 흐름 단순. 라이브 즉시 동작.
- 단점: base64를 SSE inline 전송 → 스트림 페이로드 비대(메모리/대역). chat store JSONL에 base64 저장 → history 파일 비대, dedup 없음. data: URL이 DOM에 인라인.

### Option B — 미디어를 persist하고 URL/token emit (권장)

브릿지/핸들러가 미디어 청크를 누적→미디어 스토어에 persist→토큰 URL 발급. `Oas_media_delta`가 카운트 대신 **token/url + media_type**을 운반. frontend가 URL로 `ChatImageBlock`/`ChatVoiceBlock` 렌더. 기존 voice-clip 토큰 경로를 확장.

선례(완비, 재사용 가능):
- route: `GET /api/v1/voice/audio/<token>` (`lib/server/server_routes_http_routes_voice.ml:130`, RFC-0235 P1).
- auth: `GET /api/v1/media/<token>` is a normal `CanReadState` route. The token is
  a content locator, not a public bearer capability.
- 토큰 검증 + GC: `lib/keeper/keeper_chat_store.ml:948` `valid_audio_token`, :960 만료 GC.
- URL 생성: `lib/voice/voice_bridge.ml:17`; persist+emit 패턴: `lib/keeper/keeper_tool_voice_runtime.ml:149-159`.

- 장점: 스트림은 URL만(가벼움). reload 자연 동작(URL은 chat store에 persist). 브라우저 캐시. 기존 voice 패턴과 일관. dedup 가능.
- 단점: 미디어 스토어 + 보존/GC 정책 필요. 이미지/문서용 route 일반화(`/api/v1/media/<token>`?) 및 read-auth 필요.

### 권장: Option B

근거: (a) 라이브와 reload를 한 메커니즘으로 처리(URL persist), (b) 스트림/히스토리 비대화 회피, (c) **이미 프로덕션에서 동작하는 voice-clip 토큰 경로의 직접 일반화**라 신규 표면 최소. 트레이드오프: 미디어 스토어/GC/route 일반화 비용이 base64보다 크나, reload 노출과 스트림 경량성을 동시에 얻는다. 어느 옵션이든 `bytes:int`는 **replace**한다(augment 금지).

## 4. 구현 범위 (Option B)

1. `lib/keeper/keeper_chat_events.ml` — `Oas_media_delta`의 `bytes:int`를 제거하고 `media_ref`(token/url) + `media_type` + `source_type`로 교체. (closed variant, 컴파일러가 모든 소비자 강제 갱신.)
2. `lib/keeper/keeper_chat_oas_stream_bridge.ml:85-91` — `MediaDelta.data`를 청크 누적(`bridge_state`)하고 `Oas_content_block_stop`에서 미디어 스토어에 persist + 토큰 발급.
3. 미디어 스토어 모듈 — voice-clip persist(`keeper_tool_voice_runtime.ml`) 일반화. 이미지/오디오/문서 media_type 지원.
4. HTTP route — `GET /api/v1/media/<token>` (voice route 일반화) + normal read-auth gate.
5. `lib/server/server_routes_http_keeper_stream.ml:1179` — URL emit.
6. `keeper_chat_blocks.ml` / `keeper_chat_store.ml` — 생성 미디어를 기존 `Image`/`Voice` 블록(+필요시 문서)으로 persist (reload 노출).
7. frontend `dashboard/src/keeper-stream.ts` — KEEPER_MEDIA_DELTA 핸들러가 URL로 `ChatImageBlock`/`ChatVoiceBlock` emit.

## 5. 의존성 / 경계

- OAS: 변경 없음 (데이터 이미 surface). pin bump 불요.
- RFC-0235/0236 voice transport 인프라 재사용/일반화. RFC-0164 voice tool 추상화와 토큰/route 정합 유지.
- 경계: MASC↔OAS 브릿지(`keeper_chat_oas_stream_bridge`)가 유일한 변경 진입점. lane-per-keeper 격리 불변.

## 6. 검증 방법

- bridge unit: `MediaDelta{data}` 입력 → 데이터 보존(persist 호출) + token emit, **count 미생성** 단언.
- media store round-trip: persist→token→fetch가 동일 바이트 반환.
- SSE: KEEPER_MEDIA_DELTA가 url을 운반(bytes 아님) 단언.
- chat store: 생성 미디어가 `Image`/`Voice` 블록으로 persist, reload 시 재현.
- frontend: KEEPER_MEDIA_DELTA → ChatImageBlock/ChatVoiceBlock 렌더 (가능한 테스트 하네스 내).
- TLA+ 불요 (상태 머신/동시성 프로토콜 아님).

## 7. 마이그레이션 / 롤백

- `Oas_media_delta.bytes` 소비자는 SSE emit 1곳뿐(`server_routes_http_keeper_stream.ml:1179`) + discord/slack stub(`keeper_chat_discord.ml:430`, `keeper_chat_slack.ml:288`, `_ ->` no-op). closed variant 교체라 컴파일러가 전수 강제.
- count 필드에 의존하는 소비자 없음 → 제거가 안전.
- 롤백: 변경 revert. 미디어 스토어는 GC로 자동 정리(voice-clip과 동일 정책).

## 8. 워크어라운드 거부 점검

- count-only shape를 **제거(replace)**한다 — augment(텔레메트리 추가) 아님.
- typed closed variant로 모든 소비자를 컴파일 타임에 강제 — string match/catch-all 미추가.
- 단일 메커니즘(URL persist)으로 라이브+reload 처리 — N-of-M 분할 아님.
