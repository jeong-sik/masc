# Gate-Connector Protocol Specification (Refined + Extended)

## 1. Overview
이 문서는 **Gate**와 외부 **Connector**(Discord, Telegram, Slack 등) 및 **MASC** 간의 양방향/멀티모달 통신을 위한 통합 프로토콜 스펙을 정의합니다.
핵심 설계 원칙은 다음과 같습니다:
- **Decoupling:** MASC는 외부 채널(Connector)의 존재를 모르며, Connector도 MASC를 모릅니다. 오직 Gate만이 두 영역을 중개합니다.
- **Multi-Protocol:** Connector의 특성과 요구사항에 맞춰 SSE, Webhook, WebSocket, HTTP REST 등 다양한 전송 계층을 지원합니다.
- **Multi-Modal:** 텍스트(Text)뿐만 아니라 음성(Voice), 이미지(Image/Video) 등 다양한 미디어 타입을 수용합니다.
- **Channel Control:** MASC(또는 시스템 운영자)가 특정 채널에 대해 Mute(음소거), Unmute, Rate-limit 등의 제어를 수행할 수 있습니다.

## 2. Architecture Diagram
```text
[ Connectors ]                     [ Gate ]                        [ MASC ]
(Discord, Slack, Web)

  (Inbound) HTTP POST       -->    +------------+                  +------------------+
  (Outbound) SSE / Webhook  <--    | Event      |  --- Dispatch -> | Tool_keeper      |
                                   | Router     |                  | Event_bus        |
  (Control) WebRTC / WS     <-->   | & Bridge   |  <-- Subscribe - | Board / Broadcast|
                                   +------------+                  +------------------+
```

## 3. Data Models

모든 데이터는 JSON(또는 WebRTC Signaling 페이로드) 형식으로 직렬화되어 교환됩니다.

### 3.1. Inbound Event (Connector -> Gate)
Connector에서 발생한 사용자의 입력(또는 이벤트)을 Gate로 전달합니다.

```json
{
  "event_id": "uuid-v4",
  "channel": "discord",
  "channel_room_id": "123456789",
  "channel_user_id": "user_001",
  "channel_user_name": "Alice",
  "type": "message", // "message", "voice_chunk", "presence", "webrtc_signal"
  "content": {
    "text": "Hello, Keeper!",
    "media_urls": [], // optional image/file URLs
    "audio_blob": "base64...", // optional for short audio
    "webrtc_session_id": "uuid-v4", // mandatory for WebRTC signaling
    "webrtc_payload": {} // SDP or ICE candidate data
  },
  "metadata": {}
}
```

### 3.2. Outbound Event (Gate -> Connector)
MASC에서 발생한 응답이나 프로액티브 메시지를 Gate가 Connector로 푸시합니다.

```json
{
  "event_id": "uuid-v4",
  "target_channel": "discord",
  "target_room_id": "123456789", // optional: 특정 방으로 지정, 생략 시 채널 브로드캐스트
  "source_agent": "dreamer",
  "type": "message", // "message", "voice_chunk", "typing_indicator", "webrtc_signal"
  "content": {
    "text": "I found the answer.",
    "media_urls": [],
    "audio_url": "https://...", // TTS stream URL
    "webrtc_session_id": "uuid-v4", // mandatory for WebRTC signaling
    "webrtc_payload": {} // SDP or ICE candidate data
  },
  "metadata": {
    "turn_stats": { ... }
  }
}
```

### 3.3. Channel Control Event (MASC -> Gate -> Connector)
MASC 에이전트 또는 오퍼레이터가 외부 채널의 상태를 제어합니다. Gate가 해당 이벤트를 수신하면 자체적으로 Inbound를 차단(Mute)하거나, Connector에 상태 변경을 통보합니다.

```json
{
  "event_id": "uuid-v4",
  "target_channel": "discord",
  "target_room_id": "123456789",
  "type": "control",
  "action": "mute", // "mute", "unmute", "pause", "set_rate_limit"
  "params": {
    "duration_sec": 3600, // optional, TTL for mute
    "reason": "Automated cooldown applied"
  }
}
```

## 4. Deep Dives & Refinements

### 4.1. Voice & Multi-Modal Streaming (음성/멀티모달 상세화)
- **Voice Chunking:** `audio_blob` 필드를 사용하여 짧은 음성 단편(Chunk)을 전송할 수 있습니다. 100ms~500ms 단위의 Base64 인코딩된 오디오 청크를 SSE나 WebSocket을 통해 지속적으로 주고받음으로써 실시간 음성을 모사합니다.
- **WebRTC Signaling 브릿지:** 고품질 실시간 음성 통화(Low Latency Audio)가 필요한 경우, WebRTC SDP Offer/Answer 및 ICE Candidate 교환을 지원합니다. 비동기로 도착하는 여러 세션의 엉킴을 방지하기 위해, 모든 WebRTC 관련 페이로드에는 반드시 `webrtc_session_id` (또는 `peer_id`)를 포함하여 명확한 세션 경계(Correlation)를 보장해야 합니다.
- **멀티모달 락(Lock):** 동시에 여러 미디어가 전송되는 상황을 피하기 위해, "지금 말하는 중(Typing/Speaking Indicator)" 이벤트를 명확히 하여 UI에서 시각적으로 표현할 수 있도록 합니다.

### 4.2. Control State Management (채널 제어 상태 관리)
- **Distributed State First:** 로드밸런서 뒤에 다수의 Gate 인스턴스(Scale-out)가 존재하는 환경에서의 TOCTOU(Time-Of-Check to Time-Of-Use) 취약점 및 Rate-limit 우회를 방지하기 위해, Mute 및 Rate-Limit 상태는 Redis(또는 PostgreSQL 기반 Lock) 등 **분산 영속성 저장소에서 일원화하여 관리하는 것을 원칙(Required)**으로 합니다.
- **In-Memory Fallback:** 단일 인스턴스 환경이거나 분산 저장소 장애 시에만 Gate의 인메모리(RAM) 상태를 Fallback으로 활용합니다. 
- **Connector 연동:** Gate가 Inbound 요청을 받을 때 상태를 검사하고, Muted 상태거나 한도를 초과하면 즉각 `429 Too Many Requests` 상태 코드를 반환하여 Connector 측이 스스로 메시지를 Drop하도록 유도합니다.

### 4.3. Connection Stability & Reliability (연결 안정성 및 에러 복구)
- **SSE Reconnect & 410 Gone Recovery:** Connector는 SSE 연결 시 `Last-Event-ID`를 명시하여 재연결을 시도합니다. 단, 클라이언트의 연결 단절 기간이 길어 Gate의 인메모리 이벤트 버퍼에서 해당 이벤트가 이미 Eviction(삭제)된 경우, Gate는 묵인하지 않고 **HTTP 410 Gone** 상태 코드를 반환하거나, **Full-state snapshot(초기화 동기화 이벤트)**을 내려주어 클라이언트가 누락된 상태를 즉시 복구할 수 있는 Error Path를 강제합니다.
- **Webhook Retry & DLQ Policy:** Webhook 방식으로 설정된 Connector가 응답하지 않는 경우(예: 5xx 에러 또는 타임아웃), 지수 백오프(Exponential Backoff) 방식으로 최대 3회 재시도합니다. 3회 모두 실패한 이벤트는 조용히 버려지지(Swallow) 않고, **Dead-Letter Queue (DLQ)**에 저장되며 MASC 오퍼레이터 또는 `Board`로 전송 실패 알림(Alert)이 브로드캐스트됩니다.
- **Deduplication:** Inbound 메시지는 `idempotency_key`를 활용하여 중복을 필터링하며, Outbound 이벤트 역시 `event_id`를 기준으로 Connector가 중복 수신(Idempotent 처리)을 보장해야 합니다.

### 4.4. Large Media Architecture (대용량 미디어 처리)
- **Pre-signed URL Pattern:** 이미지, 비디오, 대용량 파일 등은 **Gate를 직접 통과(Pass-through)하지 않는 것**을 원칙으로 합니다. 이는 Gate 서버의 인메모리 버퍼와 네트워크 대역폭 고갈을 방지하기 위함입니다.
- **Inbound (Connector -> MASC):** Connector 측에서 미디어 파일을 자체 Storage나 S3(Supabase Storage 등)에 업로드한 뒤, **접근 가능한 URL**(`media_urls`)만을 `inbound_event` 페이로드에 담아 Gate로 전달합니다.
- **Outbound (MASC -> Connector):** MASC 에이전트에서 생성된 이미지나 대용량 파일 역시 S3나 내부 CDN에 업로드된 후, 발급된 **Pre-signed URL** 형태(`media_urls`)로 Gate를 거쳐 Connector로 전달됩니다. Connector는 이 URL에서 파일을 직접 다운로드하여 채널(Discord 등)에 렌더링합니다.

### 4.5. MASC Internal Data Translation (내부 데이터 맵핑 룰)
- **Decoupled Boundary:** `gate_outbound_bridge.ml`는 MASC의 도메인 모델(예: `Room_task.t`, `Keep_record`)을 외부 Connector가 이해할 수 있는 순수 JSON(`outbound_event`)으로 번역하는 어댑터(Adapter) 역할을 수행합니다.
- **Translation Mapping:**
  - `Room_task` 상태 변경 (Claimed -> Done): `type: "message"`, `content: {"text": "Task [ID] status changed to Done"}` 형태의 시스템 메시지로 변환.
  - `Keep_record` 저장 완료: `type: "message"`, `content: {"text": "New memory stored: <title>"}`.
  - `Turn_stats` 추출: MASC 내부의 모델 사용량, 토큰 수, 소요 시간을 `outbound_event`의 `turn_stats` 객체로 직접 매핑하여 전달.

## 5. Security & Authentication (인증 및 권한 고도화)
- **Token Rotation & Lifecycle:** Gate는 단일 `GATE_API_TOKEN`으로 모든 것을 통제하는 대신, `Connector_ID` 별로 독립된 **단기 토큰(Short-lived JWT)** 또는 언제든 **회전(Rotation) 가능한 API Key**를 발급하여 보안 사고 시 폭발 반경(Blast Radius)을 최소화합니다.
- **Scoped Access (채널 격리 권한):** 발급되는 각 토큰에는 자신이 접근할 수 있는 `channel` 이름(e.g., `"discord"`, `"slack"`)에 대한 **Scope(권한 범위)**가 반드시 포함되어야 합니다. 만약 `"discord"` 권한만 가진 Connector가 `target_channel: "telegram"`으로 Inbound 메시지를 보내거나 스트림을 구독하려고 하면, Gate는 이를 거부하고 `403 Forbidden`을 반환합니다.
- **Header Specification:** 모든 요청에는 `Authorization: Bearer <TOKEN>` 뿐만 아니라, 감사(Audit) 로깅 및 디버깅을 위한 `X-Connector-ID: <UUID>` 헤더를 필수로 요구합니다.
