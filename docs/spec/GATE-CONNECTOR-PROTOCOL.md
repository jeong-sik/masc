# Gate-Connector Protocol Specification

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

## 4. Transport Interfaces

### 4.1. HTTP REST (Inbound & Sync Reply)
- **Endpoint:** `POST /api/v1/gate/message`
- **Description:** Connector가 텍스트나 메타데이터를 단발성으로 전송합니다. (현재 구현된 방식의 확장)

### 4.2. SSE (Outbound Streaming)
- **Endpoint:** `GET /api/v1/gate/stream?channel=discord`
- **Description:** Connector 봇이 시작될 때 이 엔드포인트에 연결합니다. Gate는 해당 채널(예: `discord`)로 향하는 모든 `Outbound Event`와 `Control Event`를 SSE 스트림으로 푸시합니다.

### 4.3. Webhook (Outbound Push)
- **Endpoint:** `POST /api/v1/gate/webhooks/register`
- **Description:** 서버리스 환경이나 클라우드 기반 Connector(예: Slack App)를 위해, Connector가 자신의 Webhook URL을 Gate에 등록합니다. Gate는 이벤트 발생 시 해당 URL로 POST 요청을 보냅니다.

### 4.4. WebSocket / WebRTC (Bi-directional & Low Latency Audio)
- **Endpoint:** `WS /api/v1/gate/ws` / `POST /api/v1/gate/webrtc/offer`
- **Description:** 실시간 음성(Voice) 대화나 연속적인 바이너리 스트리밍이 필요할 때 사용합니다. WebRTC의 경우 Gate 내부에 Media Server 브릿지를 두어 오디오 트랙을 중계합니다.

## 5. MASC Integration (Gate Internals)

- **Subscription:** Gate의 `gate_outbound_bridge.ml`(가칭)가 MASC의 `Event_bus`나 `Board` 이벤트를 구독합니다.
- **Routing Logic:** 이벤트의 목적지가 `gate:<channel>:<room>` 규칙에 일치하는 경우, 등록된 Transport (SSE, Webhook 등)를 통해 Connector로 라우팅합니다.
- **Control Enforcement:** Gate 자체적으로 `Rate Limiter`와 `Mute State`를 메모리에 유지합니다. Muted 상태인 채널/룸에서 들어오는 `Inbound Event`는 즉시 429(Too Many Requests) 또는 무시(Drop) 처리되며, MASC로 전달되지 않습니다.

## 6. Security & Authentication
- 모든 Gate 엔드포인트는 `Authorization: Bearer <GATE_API_TOKEN>` 헤더를 요구합니다.
- 각 Connector는 고유한 Channel Name과 Token을 가지며, 자신이 권한을 가진 채널의 이벤트만 구독/수신할 수 있습니다.
