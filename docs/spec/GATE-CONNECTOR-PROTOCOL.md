# Gate-Connector Protocol Specification (Refined + Extended + Adversarial Checked)

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
- **WebRTC Signaling 브릿지:** 고품질 실시간 음성 통화(Low Latency Audio)가 필요한 경우, WebRTC SDP Offer/Answer 및 ICE Candidate 교환을 지원합니다. 비동기로 도착하는 여러 세션의 엉킴을 방지하기 위해, 모든 WebRTC 관련 페이로드에는 반드시 `webrtc_session_id` (UUID v4)를 포함하여 명확한 세션 경계(Correlation)를 보장해야 합니다.
- **멀티모달 락(Lock):** 동시에 여러 미디어가 전송되는 상황을 피하기 위해, "지금 말하는 중(Typing/Speaking Indicator)" 이벤트를 명확히 하여 UI에서 시각적으로 표현할 수 있도록 합니다.

### 4.2. Control State Management (채널 제어 상태 관리)
- **Distributed State First:** 로드밸런서 뒤에 다수의 Gate 인스턴스(Scale-out)가 존재하는 환경에서의 TOCTOU(Time-Of-Check to Time-Of-Use) 취약점 및 Rate-limit 우회를 방지하기 위해, Mute 및 Rate-Limit 상태는 Redis(또는 PostgreSQL 기반 Lock) 등 **분산 영속성 저장소에서 일원화하여 관리하는 것을 원칙(Required)**으로 합니다.
- **Fail-Closed on Store Unavailability:** 분산 저장소(Redis 등)에 접근할 수 없는 경우, Gate는 인메모리 Fallback으로 전환하지 않고 **`503 Service Unavailable`을 반환하여 요청을 거부(Fail-Closed)**합니다. 인메모리 Fallback은 다중 인스턴스 환경에서 Rate-limit 우회를 허용하므로 금지합니다. 단일 인스턴스 개발 환경에서는 `GATE_SINGLE_INSTANCE=true` 플래그로 인메모리 모드를 명시적으로 활성화할 수 있습니다.
- **Connector 연동:** Gate가 Inbound 요청을 받을 때 상태를 검사하고, Muted 상태거나 한도를 초과하면 즉각 `429 Too Many Requests` 상태 코드를 반환하여 Connector 측이 스스로 메시지를 Drop하도록 유도합니다.

### 4.3. Connection Stability & Reliability (연결 안정성 및 에러 복구)
- **SSE Reconnect & 410 Gone Recovery:** Connector는 SSE 연결 시 `Last-Event-ID`를 명시하여 재연결을 시도합니다. 단, 클라이언트의 연결 단절 기간이 길어 Gate의 인메모리 이벤트 버퍼에서 해당 이벤트가 이미 Eviction(삭제)된 경우, Gate는 묵인하지 않고 **HTTP 410 Gone** 상태 코드를 반환하거나, **Full-state snapshot(초기화 동기화 이벤트)**을 내려주어 클라이언트가 누락된 상태를 즉시 복구할 수 있는 Error Path를 강제합니다.
- **Webhook Retry & DLQ Policy:** Webhook 방식으로 설정된 Connector가 응답하지 않는 경우(예: 5xx 에러 또는 타임아웃), 지수 백오프(Exponential Backoff) 방식으로 최대 3회 재시도합니다. 3회 모두 실패한 이벤트는 조용히 버려지지(Swallow) 않고, **Dead-Letter Queue (DLQ)**에 저장되며 MASC 오퍼레이터 또는 `Board`로 전송 실패 알림(Alert)이 브로드캐스트됩니다.
- **Deduplication:** Inbound 메시지는 `idempotency_key`를 활용하여 중복을 필터링하며, Outbound 이벤트 역시 `event_id`를 기준으로 Connector가 중복 수신(Idempotent 처리)을 보장해야 합니다.

### 4.4. Large Media Architecture (대용량 미디어 처리: URL TTL 엣지 케이스 방어)
- **Pre-signed URL Pattern:** 이미지, 비디오, 대용량 파일 등은 **Gate를 직접 통과(Pass-through)하지 않는 것**을 원칙으로 합니다.
- **TTL (Time-To-Live) 방어:** Pre-signed URL의 만료 시간은 **15분~60분**으로 설정합니다. 장기간 유효한 URL(예: 7일)은 유출 시 공격 표면이 크므로 금지합니다. MASC 에이전트의 처리 지연으로 URL이 만료(403 Expired)될 경우, Gate는 Connector에게 **URL 갱신 요청(refresh request)**을 발행하여 새 URL을 수신합니다. 갱신 실패 시 해당 파일 처리를 Graceful Failure로 포기하고, 실패 사유를 DLQ에 기록합니다.

### 4.5. MASC Internal Data Translation (변환 계층의 데이터 정제 및 스팸 방지)
- **Decoupled Boundary:** `gate_outbound_bridge.ml`는 MASC의 도메인 모델(`Room_task.t`, `Keep_record` 등)을 범용 `outbound_event` JSON으로 변환합니다.
- **Visibility & Sanitization (보안 정제):** 에이전트의 내부 사고 과정(Internal Thoughts), 에러 스택 트레이스, 보안 민감 정보 등은 절대로 외부 채널(Discord 등)로 브로드캐스트되어서는 안 됩니다. 변환 계층에서는 오직 `visibility: public` 또는 `visibility: channel` 로 명시된 이벤트만 추출(Whitelist 방식)하며, 민감 필드는 강력히 마스킹(Sanitize)해야 합니다.
- **State Flapping Debounce (스팸 방지):** `Room_task.t`의 상태가 짧은 시간에 수시로 변경(Claimed -> In-Progress -> Claimed)되는 플래핑(Flapping) 현상이 발생하면 외부 채널이 메시지 스팸으로 도배됩니다. 변환 계층은 상태 변경 알림에 대해 **디바운스(Debouncing)** 로직을 적용하거나 핵심 마일스톤(Task Done 등)만 전파하도록 필터링을 강제합니다.

## 5. Security & Authentication (인증 및 권한 고도화)
- **Token Rotation & SSE Expiry:** Gate는 `Connector_ID` 별로 단기 토큰(Short-lived JWT)을 발급합니다. 만약 열려있는 SSE 스트림 도중 JWT가 만료되면, Gate는 스트림을 강제로 종료(또는 `401 Unauthorized` 이벤트 전송 후 종료)하여 Connector가 새 토큰을 갱신하고 재연결(Reconnect)하도록 강제합니다.
- **Scoped Access:** 발급되는 각 토큰에는 자신이 접근할 수 있는 `channel` 이름(e.g., `"discord"`)에 대한 **Scope**가 포함되어야 합니다. 다른 채널로 보내거나 구독하려고 하면 `403 Forbidden`을 반환하여 폭발 반경(Blast Radius)을 최소화합니다.
- **Webhook Signature Verification (Outbound Auth):** Gate가 Webhook으로 Connector에게 POST를 날릴 때, Gate는 HTTP Header에 페이로드의 **HMAC-SHA256 Signature** (`X-Gate-Signature`)와 **타임스탬프** (`X-Gate-Timestamp`, Unix epoch seconds)를 반드시 포함시켜야 합니다. 서명 대상은 `timestamp + "." + payload_body`이며, Connector는 타임스탬프가 **5분 이내**인지 먼저 확인한 후 서명을 검증합니다. 5분 초과 시 replay attack으로 간주하고 `403 Forbidden`을 반환합니다.
