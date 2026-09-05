---
status: runbook
---

# Voice Runbook

Speech into and out of MASC: which endpoints carry it, what an operator has to
run locally, and the two calls an external device makes. Everything here was
measured on one workstation (M3 Max, macOS) on 2026-09-03/04; numbers are from
that machine and say so where they matter.

## Configuration

One section in `runtime.toml`, read by `Voice_config`:

```toml
[voice.tts]             default_model, default_voice, agent_voices, endpoints
[voice.stt]             default_model, endpoints
[voice.session]         endpoints          # realtime; empty unless configured
[voice.local_playback]  enabled, agents
[voice.capture]         calibration_seconds, trigger_margin_db, trailing_silence_seconds, speech_margin_db, noise_reduction
[voice.gate]            always_allow, exempt_agents
```

`[voice.tts]` and `[voice.stt]` are optional. Absent, the speak and transcribe
paths refuse by name before any endpoint is asked. Present, each must name its
`default_model`; a blank one fails the load, because it used to reach providers
as `model_id ""`. `[voice.capture]` is read as strictly as an endpoint is: a key
it does not know, or a value of the wrong type, fails the load naming
`root.capture.<key>`, and an absent key takes the measured default.

An endpoint declares a `kind`, and the kind decides the request that gets
built — not a string match on the URL:

| `kind` | TTS | STT | Auth |
|---|---|---|---|
| `elevenlabs_direct` | `POST <base>/text-to-speech/<voice_id>` | `POST <base>/speech-to-text` | `xi-api-key` |
| `openai_compat` | `POST <base>/audio/speech` | `POST <base>/audio/transcriptions` | `Authorization: Bearer`, omitted entirely when no `api_key_env` |
| `voice_mcp` | MCP tool call | — | — |

`voice_tuning` (stability / similarity_boost / style) is ElevenLabs vocabulary
and is not sent to an `openai_compat` endpoint, which never asked for it.
A voice id is provider-specific in the same way, so the fallback chain resolves
the voice per endpoint rather than carrying the first endpoint's id onward.

### The endpoint list is a real fallback chain

`lib/voice/voice_bridge.ml`'s `try_endpoints` advances to the next endpoint when one
fails, so a local server that is not running costs a fallback rather than
stopping voice. This is **not** how `runtime.exact_output_lanes.*.slots`
behaves — there, a connection failure folds the lane. Do not carry an
intuition from one to the other.

Advancing is refused for `Outcome_unknown`: a TTS call whose result is unknown
may already have played audio, and retrying would speak twice.

### There is no retry count

No reader consumes one. `call_voice_mcp_endpoint` runs a single attempt, and
recovery is the endpoint chain. `max_retries` in an endpoint table is rejected
by the field whitelist, which is correct — see the incident below.

## Local STT

`scripts/whisper-server.sh` (in the `me` repo) wraps whisper.cpp:

```sh
scripts/whisper-server.sh start     # :2022, /v1/audio/transcriptions, lang=ko
scripts/whisper-server.sh status    # includes resident size
scripts/whisper-server.sh test      # says a phrase, prints the transcript
scripts/whisper-server.sh stop
```

whisper.cpp serves `/inference` by default; the script moves it with
`--inference-path` so `<base_url>/audio/transcriptions` lands, which is the
path `openai_compat` builds.

```toml
[[voice.stt.endpoints]]
id = "whisper-local"
kind = "openai_compat"
base_url = "http://127.0.0.1:2022/v1"
enabled = true
timeout_seconds = 60.0

[[voice.stt.endpoints]]
id = "elevenlabs-stt"     # fallback
```

Measured with `ggml-large-v3-turbo` on a real Korean utterance: **0.85 s**,
transcript correct. The STT `default_model` is workspace-wide rather than
per-endpoint, so `scribe_v2` rides along to whisper, which ignores it.

The server holds its model resident for as long as it runs — **1.8 GB** for
large-v3-turbo — with no idle unload of the kind ollama does. Stop it when
speech is infrequent.

## Capture thresholds

`record_and_transcribe` decides where a recording starts and ends itself. sox
records; it no longer judges.

It used to. The recorder ran with sox's `silence` filter, which took a fixed
1% of full scale — about −40 dBFS. Measured on one workstation 2026-09-03:

| | |
|---|---|
| Noise floor, pass one | −37.2 dB |
| Noise floor, pass two, minutes later, same room | −26.3 dB |
| The constant that was the threshold | −40.0 dB |

Both floors sit above it, so the filter heard sound continuously: recording
began at once, the trailing-silence condition never came true, and every
capture ran to its timeout and handed the transcriber a room.

Making the threshold follow the room fixed that and exposed the next problem.
The filter compares **peak**, and peak is an unstable basis — across five
probes of the same idle room a minute apart it moved 1.9x while RMS moved
1.2x. A threshold derived from it wandered on a room that had not changed.

And nothing could watch it happen. **With the `silence` filter the output file
stays at zero bytes until the trigger fires** — not even a WAV header, so
`sox stat` on it fails with "RIFF header not found". A level meter reading
that file reported nothing for exactly as long as the operator needed to see
something.

So the decision moved (2026-09-04). The recorder writes continuously, the
level is read straight from the growing file ten times a second, and one
number drives the trigger, the end, and the bar the operator watches.

| | |
|---|---|
| Level basis | RMS, over the newest 0.3 s |
| Poll interval | 0.1 s |
| Recorded format | 16 kHz, mono, **16-bit signed** — pinned, because sox picks 32-bit when it is not told |
| Room | the quietest reading during `calibration_seconds`, taken from the capture's own opening |

- **Trigger**: room + `trigger_margin_db`. Speech read 20 dB above the room on
  the same microphone, so this only has to clear the room.
- **End**: the level falls back under room + `speech_margin_db` and stays
  there for `trailing_silence_seconds`. A shorter pause is inside a sentence.
- **Gate**: a capture in which no reading ever cleared the trigger is not sent.
  It says so in the transcript, with the room it measured and the level speech
  had to clear -- an empty draft looks the same whether the microphone heard
  nothing, the room sat above the threshold, or the transcriber failed, and
  those two numbers are what separates them.
- All four are `[voice.capture]` keys in `runtime.toml`.

Stopping the recording is a cancel. The cancelled spawn sends sox `SIGTERM`,
then waits for sox to close its pipes — up to
`Process_eio.child_exit_grace_seconds` (2 s) — and only then lets `SIGKILL`
follow. sox flushes and closes the WAV on `SIGTERM`, writing the length into
the header, so the recording read back is the whole capture.

Before the wait existed the `SIGKILL` arrived in the same instant as the
`SIGTERM`: a recording stopped at two seconds read back as 1.75 s, and the
missing quarter second matches sox's unflushed stdio buffer. The 1.75 s figure
was measured 2026-09-04 under that shape; the full-length claim for the current
shape has not been re-measured on a live microphone.

### Why the gate exists

Whisper answers silence with a sentence. Three captures of an empty room, sent
to the local endpoint, returned `"감사합니다."`, `"감사합니다."` and `"네"` —
fluent Korean for an operator who said nothing. The only previous guard was
`st_size > 100`, and a capture that ran to its timeout on room tone is large,
so size cannot tell the two apart.

The refusal has to happen before the endpoint chain: once audio reaches an STT
endpoint, a hallucinated transcript is indistinguishable from a real one.

### Device timings

| | |
|---|---|
| `rec` open overhead, warm | 0.5–0.8 s |
| `rec` open overhead, first call after idle | ~2.5 s |
| Trailing-silence wait | 2.0 s |
| Local transcription | 0.85 s |

A level meter therefore reads the recording as it grows rather than opening a
second capture device. `Voice_pcm.tail_rms` reads the samples directly — sox
cannot answer this, because `stat` on a file whose header carries no length
fails and `trim -0.4` needs a length that header does not yet have. Reading
the bytes also keeps a subprocess out of a loop that runs ten times a second;
it agrees with sox to six decimal places on a finished file.

## TUI

`Ctrl-Y` in a focused composer row starts a capture, and pressing it again
stops one, keeping what was said up to that point -- the usual reason to stop
is that the sentence is finished and the trailing-silence wait is two seconds
away. `Esc` abandons the recording instead, which is the only place in the
capture path where the operator says what they want rather than the levels
inferring it. Either key before any speech aborts and yields nothing, so
reaching for the wrong one costs nothing. The transcript is appended to the
draft, not sent. A meter runs in the prompt while it records, because a
dead input device and a quiet room both end as an empty draft and nothing else
separates them.

The binding is a control code because every printable key in a focused row is
draft text.

## External devices

Any device that can make two HTTP calls can speak to a keeper. No MASC change
is needed; this was verified end to end on 2026-09-04.

```sh
TOKEN=$(cat ~/me/.masc/auth/admin.token)

# 1. audio in, text out
curl -X POST "$MASC/api/v1/voice/transcribe" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: audio/wav' \
  --data-binary @utterance.wav
# {"status":"transcribed","text":"...","endpoint_id":"whisper-local"}

# 2. text to a keeper
curl -X POST "$MASC/api/v1/keepers/chat/stream" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"request_id":"<uuid>","name":"sangsu","message":"<the text>"}'
# 200, then an SSE stream: KEEPER_CHAT_OPERATION_ACCEPTED, RUN_STARTED, ...
```

Notes that cost time to rediscover:

- The audio goes in the **raw body**, not as multipart. `Content-Type` names
  the format.
- The keeper field is `name`, not `keeper_name`.
- `request_id` is **required**; omitting it returns 400.
- `/transcribe` is admin-gated. `/api/v1/voice/audio/<token>` is not — that
  token is a capability, which is why TTS clips can be fetched by a browser.
- The transcribe response names `endpoint_id`, so it is visible whether a call
  was served locally or fell back.

## Incident: voice was down for six days and said nothing

`runtime.toml [voice]` carried `max_retries` on both endpoint lists.
`lib/voice_config/voice_config.ml` arrived on 2026-08-28 with a field whitelist that does not
accept it, so every voice read failed from that day until 2026-09-03.

It went unnoticed because four readers in `voice_bridge_core` matched
`Error _` and substituted defaults — the hardcoded agent-voice map, 0.5/0.75/0.0
tuning, playback off, the `"Sarah"` fallback voice. `Voice_config.load_detailed`
separates `Not_configured` from `Invalid` precisely so the second reaches an
operator, and its interface says so; those four collapsed both.

The only surface that reported it was `GET /api/v1/voice/config`, which returns
500 and no turn calls.

Fixed in #32881: `Invalid` is logged per read, naming which reader fell back.
`Not_configured` stays silent, since an environment without voice is not a
fault.

**If voice behaves oddly, read `GET /api/v1/voice/config` first.** It is the
one surface that distinguishes "not configured" from "configured and broken".
