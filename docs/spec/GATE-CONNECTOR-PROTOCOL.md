# Gate-Connector Protocol Specification (Refined)

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
  "type": "message", // "message", "voice_chunk", "presence"
  "content": {
    "text": "Hello, Keeper!",
    "media_urls": [], // optional image/file URLs
    "audio_blob": "base64..." // optional for short audio
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
  "type": "message", // "message", "voice_chunk", "typing_indicator"
  "content": {
    "text": "I found the answer.",
    "media_urls": [],
    "audio_url": "https://..." // TTS stream URL
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
- **WebRTC Signaling 브릿지:** 고품질 실시간 음성 통화(Low Latency Audio)가 필요한 경우, `Gate_protocol` 내부에 WebRTC SDP Offer/Answer 및 ICE Candidate 교환을 위한 별도 페이로드 타입을 정의합니다. (e.g., `type: "webrtc_signal"`).
- **멀티모달 락(Lock):** 동시에 여러 미디어가 전송되는 상황을 피하기 위해, "지금 말하는 중(Typing/Speaking Indicator)" 이벤트를 명확히 하여 UI에서 시각적으로 표현할 수 있도록 합니다.

### 4.2. Control State Management (채널 제어 상태 관리)
- **Gate In-Memory State:** Mute(음소거) 및 Rate-Limit 상태는 우선적으로 **Gate의 인메모리(RAM)**에서 관리됩니다. TTL(Time-To-Live) 기반으로 `duration_sec`이 지나면 자동 해제됩니다.
- **Redis/PostgreSQL Persistence (Optional):** 다중 Gate 인스턴스(Scale-out) 환경이나 영속성이 보장되어야 하는 강력한 글로벌 Mute의 경우, Redis나 PostgreSQL 테이블(`channel_control_state`)을 활용하여 동기화합니다.
- **Connector 연동:** Gate가 Inbound 요청을 받을 때 먼저 상태를 검사하고, Muted 상태라면 `429 Too Many Requests` 상태 코드를 반환하여 Connector 측이 스스로 메시지를 Drop하거나 사용자에게 피드백을 줄 수 있도록 합니다.

### 4.3. Connection Stability & Reliability (연결 안정성 및 에러 복구)
- **SSE Reconnect & Last-Event-ID:** Connector는 SSE 연결 시 `Last-Event-ID`를 명시하여 재연결을 시도합니다. Gate 내부의 SSE 버퍼 모듈(현재 `Sse.ml` 활용)이 보관 중인 누락 이벤트를 즉시 재전송합니다.
- **Webhook Retry Policy:** Webhook 방식으로 설정된 Connector가 응답하지 않는 경우(예: 5xx 에러 또는 타임아웃), Gate는 지수 백오프(Exponential Backoff) 방식으로 최대 3회 재시도합니다.
- **Deduplication:** Inbound 메시지는 기존의 `idempotency_key`를 활용하여 중복을 필터링하며, Outbound 이벤트 역시 `event_id`를 기준으로 Connector가 자체적으로 중복 수신(Idempotent 처리)을 하도록 명세합니다.

### 4.4. MASC Internal Event Mapping (내부 이벤트 맵핑)
- **Event Bus Subscription:** Gate는 MASC의 메인 Event Bus나 `Board`의 새 게시물 이벤트를 구독합니다.
- **Filtering Logic:** 구독된 이벤트 중에서 `agent_name = "gate:<channel_name>:*"` 형태이거나 `target_channel` 속성이 명시된 브로드캐스트 이벤트만을 필터링합니다.
- **Data Translation:** MASC 내부에서 쓰이는 `Room_task.t`나 `Keep_record` 등의 데이터 구조를 Connector가 소비할 수 있는 순수한 `outbound_event` JSON으로 맵핑(Translation)하는 어댑터 레이어(`gate_outbound_bridge.ml`)를 거칩니다.

## 5. Security & Authentication
- 모든 Gate 엔드포인트는 `Authorization: Bearer <GATE_API_TOKEN>` 헤더를 요구합니다.
- 각 Connector는 고유한 Channel Name과 Token을 가지며, 자신이 권한을 가진 채널의 이벤트만 구독/수신할 수 있습니다.