---
rfc: "0236"
title: "Voice input transport: browser-captured speech-to-text for the dashboard composer"
status: Draft
created: 2026-06-14
updated: 2026-06-14
author: vincent
supersedes: []
superseded_by: null
related: ["0235", "0223"]
implementation_prs: []
---

# RFC-0236: Voice input transport — browser-captured speech-to-text for the dashboard composer

Status: Draft · The inverse of RFC-0235. RFC-0235 carries server-synthesized audio
to the browser; this RFC carries browser-captured speech back to the server for
transcription, so the operator can speak to a keeper instead of typing on a mobile
browser. Reuses the existing ElevenLabs Scribe STT endpoint and the existing
`transcribe_audio` path — no new STT engine, no config change.

> Anchors cited as `file:line` were read against the 0235 branch tip
> (`319a3db96`, = `origin/main` `a76d22deb` + RFC-0235 P1) on 2026-06-14.

## §1 Problem — the operator must type; on a mobile browser that is impractical

The dashboard's keeper-chat composer (`dashboard/src/components/chat/primitives.ts:770`,
`chat-composer`) accepts typed input only. There is no `MediaRecorder` /
`getUserMedia` / `SpeechRecognition` anywhere in `dashboard/src`. On a mobile browser,
typing a keeper instruction is slow and error-prone.

### 1.1 The server already has a working STT path — it is just unreachable from the browser

`Voice_bridge.transcribe_audio ~audio_file ?language_code ()`
(`lib/voice/voice_bridge.ml:19`) selects the first enabled STT endpoint and POSTs the
file via `transcribe_via_http_stt` (`voice_bridge_transport.ml:206`). The request for
the `Elevenlabs_direct` kind is built by `stt_request_for_endpoint`
(`voice_runtime_overlay.ml:372`) as `POST {base_url}/speech-to-text` with header
`xi-api-key` and form fields `model_id` + `file` — exactly the ElevenLabs Scribe
contract.

### 1.2 The live config already provisions Scribe v2

`$MASC_BASE_PATH/voice_config.json` (read 2026-06-14):

```json
"stt": { "default_model": "scribe_v2", "endpoints": [
  { "id": "elevenlabs-stt", "kind": "elevenlabs_direct",
    "api_key_env": "ELEVENLABS_API_KEY", "enabled": true,
    "timeout_seconds": 35.0, "max_retries": 2 }] }
```

`scribe_v2` is a valid ElevenLabs `model_id` (official API reference: only `scribe_v1`
and `scribe_v2` are accepted). So transcription is already provisioned end to end —
only the browser→server upload half is missing. **No config change is part of this RFC.**

### 1.3 keeper_voice_listen is a different path, not this

`keeper_voice_listen` (`lib/keeper/keeper_tool_voice_runtime.ml:198`) records from the
**server host microphone** via `Voice_bridge.record_and_transcribe`
(`lib/voice/voice_bridge.ml:855`). It serves the keeper listening to its local room,
not the operator speaking to the keeper from a browser. This RFC does not touch it.

### 1.4 The only missing link is an HTTP route

RFC-0235 added `GET /api/v1/voice/audio/:token` (browser-bound output). The inverse —
`POST /api/v1/voice/transcribe` (browser-bound input) — does not exist. Everything
downstream of it already works.

## §2 Design principles

1. **Mirror RFC-0235.** Input is the dual of output: one new route, reusing the
   existing engine. No new store, no new engine, no config change.

2. **Owner-gated, not capability-gated.** RFC-0235's audio route is `with_public_read`
   because the token is an unguessable capability. Transcription has no such token —
   it spends an ElevenLabs API call per request. It must be gated by the authenticated
   dashboard owner (the same gate every dashboard write route uses). An unauthenticated
   client must not be able to spend the owner's STT quota.

3. **Text, not audio, crosses the boundary.** The browser captures audio, the server
   transcribes, and only `{text}` returns. The operator reviews the text in the
   composer draft and sends via the existing path. Audio is a transient temp file,
   deleted after transcription — it is not persisted (unlike RFC-0235 output clips,
   which are SSOT chat records).

4. **Fill the draft, do not auto-send (P1).** The operator can correct a transcription
   error before it reaches the keeper. Auto-send is a P2 option, off by default.

5. **Transient lifecycle, no TTL knob needed.** Input audio is a one-shot temp file
   (`Filename.temp_file`, like `record_and_transcribe` at `voice_bridge.ml:857`),
   removed on every exit path. There is no 1h fetch window like RFC-0235's output
   clips, because nobody fetches the input audio — only the text returns.

## §3 Model

### 3.1 Route — `POST /api/v1/voice/transcribe`

- **auth**: dashboard owner bearer gate (the same middleware the chat-send route uses;
  not `with_public_read`). Unauthenticated → 401/403, no API spend.
- **body**: `multipart/form-data`, field `audio` (the recorded blob), optional
  `language_code`.
- **handler**: write the upload to a temp file, call
  `Voice_bridge.transcribe_audio ~audio_file ?language_code ()`, delete the temp file
  on every exit path (Eio `Switch.on_release`; for the `Fun.protect` caveat see
  CLAUDE.md §OCaml — finally must absorb exceptions internally).
- **success**: `200 {"text": "..."}`.
- **failure**: `400 {"error": "<reason>"}` (`"no enabled STT endpoints configured"`,
  STT HTTP error, parse error, empty/oversized upload).

### 3.2 Composer — microphone button in `chat-composer`

- `navigator.mediaDevices.getUserMedia({ audio: true })` + `MediaRecorder`.
- On stop, `POST /api/v1/voice/transcribe` with the blob; show a "transcribing" state.
- On `{text}`, set the composer `draft` (replace) or append at the caret (P2). The
  existing `draft` → send path is untouched.
- Recording state reflected on the button; permission denial and network failure
  surface inline (no silent drop).

### 3.3 Format

`MediaRecorder` default (`audio/webm;codecs=opus` on Chrome, `audio/mp4` on Safari) is
accepted by ElevenLabs Scribe. No client-side transcoding in P1.

### 3.4 Auth boundary — why this differs from RFC-0235

| | RFC-0235 output (`GET /audio/:token`) | RFC-0236 input (`POST /transcribe`) |
|---|---|---|
| Capability | token = unguessable filename | none |
| Cost per request | bandwidth (file already exists) | one ElevenLabs API call |
| Gate | `with_public_read` (token is the key) | dashboard owner bearer |
| Persistence | clip is a SSOT chat record | audio is transient; only text returns |

## §4 Changes, by phase (each independently shippable)

### P1 — Speak to compose

- `POST /api/v1/voice/transcribe` route in `lib/server/server_routes_http_routes_voice.ml`
  (the module RFC-0235 introduced), registered in `server_routes_http.ml` next to the
  output route.
- Owner auth gate (mirror the chat-send route's middleware).
- Composer microphone button + `MediaRecorder` + draft fill
  (`dashboard/src/components/chat/primitives.ts`).
- Unit test for the route (stub `transcribe_audio`, assert `{text}` / 400 shapes),
  composer a11y/unit test (button states).

### P2 — Quality of life

- `language_code` picker (Scribe v2 auto-detects, but explicit helps low-resource
  pairs).
- Auto-send toggle (draft → send after a configurable hold).
- Realtime transcription (Scribe v2 Realtime, ~150ms) instead of batch upload.
- Device-routing parity with RFC-0235 P2 (so "speak" only routes to the active device).

## §5 Non-goals / deferred

- TTS output — RFC-0235.
- `keeper_voice_listen` / server-room microphone.
- Persistent audio uploads (input audio is transient; only the resulting text, already
  persisted as a chat message by the existing send path, is kept).
- Wake-word / always-on listening.
- In-browser STT via `SpeechRecognition` (rejected: iOS Safari support is unstable,
  Korean quality is OS-dependent, Firefox unsupported; the server engine is already
  provisioned and provider-consistent with TTS).

## §6 Validation

- `dune build @install test/` green (route compiles; transcribe path exercised via stub).
- Composer: mic button renders with recording state; draft fills from a stubbed
  `{text}` (unit test). Live STT is a manual smoke against the provisioned endpoint.
- Auth: unauthenticated `POST /api/v1/voice/transcribe` → 401/403 with no API spend.

## §7 Workaround self-check (CLAUDE.md signatures)

This RFC reuses the existing STT engine and adds one route + one composer button. It is
not telemetry-as-fix (the route returns a typed `{text}` or `400`, calling the existing
transcribe path — it does not make a silent failure visible instead of fixing it), not a
string classifier, not an N-of-M patch, not a cap/cooldown/dedup/repair. No signature
applies.
