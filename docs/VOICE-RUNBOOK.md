---
status: runbook
---

# Voice Runbook

Speech into and out of MASC: which endpoints carry it, what an operator has to
run locally, and the two calls an external device makes. Everything here was
measured on one workstation (M3 Max, macOS) on 2026-09-03/04; numbers are from
that machine and say so where they matter.

## Starting from nothing on a new mac

Measured on macOS 26 / M3 Max, 2026-09-12. A machine that has just been
unboxed can speak without installing anything, and needs two downloads to
hear.

### What is already there

`/usr/bin/say` listed **nine Korean voices** among 184 total on the measured
machine. Installed voices vary; use the catalogue on the actual server.
Nothing in the base system transcribes: macOS dictation is not
scriptable, so hearing is the half that has to be fetched.

### The two downloads

```
masc prerequisite-actions whisper
```

answers with both steps and asks before running either:

| Step | What it fetches |
|---|---|
| `brew install whisper-cpp` | 8.9MB bottle; its `whisper-cli` transcribes a file |
| the model | `ggml-large-v3-turbo.bin`, 1,624,555,275 bytes |

Neither starts a server. `say` and `whisper-cli` each run once and exit, so
masc runs them the way it runs `curl` for the endpoints that are addresses:
there is no port to pick, nothing to start before speaking, and nothing left
running afterwards. Installing them is still the operator's step, which is what
`prerequisite-actions` is — it names the commands and asks.

Without a `HOME` to build a cache path from, the second step opens the model
downloads page instead of offering a command with nowhere to write. On Linux
both steps are a link: whisper.cpp is built rather than packaged, and naming an
apt package would install something else or nothing.

### Doing it from the TUI instead

`p` to the voice pane, then `e`. Speech out starts on ElevenLabs, which does
not assume a macOS server. On a Mac, select `macos_say` at the provider step.

Five questions, walked in a terminal and counted there:

```
step 1/5  Is this endpoint for speech out or speech in?
step 2/5  Which provider serves this endpoint?      macos_say
step 3/5  What should this endpoint be called?
step 4/5  Which voice should speech out use by default?
step 5/5  Here is what will change.                 enter saves this
```

No address, no credential, no model. say is found under the name its kind
knows, nothing leaves the machine, and it is asked for a voice rather than a
model. Its generated clip is PCM WAV; the capability URL, HTTP content type,
keeper metadata and history expiry use that format. HTTP TTS clips remain MP3.

Changing providers changes the questions and the counter. ElevenLabs has seven
steps; say has five because it needs neither a credential nor a model.

The say save carries a `put_endpoint` of kind `macos_say` with its own `default_voice`, and
**no `set_default_model`** — a blank model written there would land on a
section a sibling endpoint shares. Neither `base_url` nor `api_key_env`
appears at all.

For speech in the wizard leads with whisper-cli, which is asked for the model
and nothing else.

### Giving each keeper its own voice

`a` on the voice pane. Two lists: the keepers this workspace has, and the
voices the section's **first enabled** endpoint answers to — first rather than chosen,
because a section's endpoints are a fallback chain for one voice and the one in
front is whose vocabulary the assignment has to speak. If that endpoint has
`default_voice`, it overrides keeper assignments, so the modal refuses to
open. Remove that fixed endpoint voice before using keeper assignments.
The setup wizard writes a fixed endpoint voice to keep provider-specific IDs
apart; its saved endpoint therefore needs that edit before assignment.

```
keeper  (up/down)          voice  (left/right)
  ▸ alpha                    ▸ Korean Bright Voice  (ko)
    beta                       Han Aim  (ko)
    gamma                      English Narrator
```

The axes move separately. A provider without a catalogue accepts a typed or
pasted voice ID instead. `enter` writes one line of
`[voice.tts.agent_voices]`; `esc` leaves.

Each save carries the revision the pane read and takes back the one it answers
with, so assigning several voices in a row does not tell the second one it is
stale.

The offered voices are the ones the configured server actually lists.

### What the configuration then says

```toml
[voice.tts]
default_voice = "Yuna"       # no default_model: nothing in this section is asked for one

[[voice.tts.endpoints]]
id = "macos-say"
kind = "macos_say"

[voice.tts.agent_voices]      # what `a` on the voice pane writes
alpha = "Yuna"
beta = "Eddy (한국어(한국))"

[voice.stt]
default_model = "/Users/you/.cache/whisper/ggml-large-v3-turbo.bin"

[[voice.stt.endpoints]]
id = "whisper-local"
kind = "whisper_cli"
```

`default_model` on the speech-in section is a **file path** here rather than a
name, which is what the model means to a command that takes `-m`. A blank one
is refused by name rather than defaulted to a path that may not exist.

The speaking section above names no model at all, and that loads. The rule is
not "a section names a model" but "a section names one when any endpoint in it
would be asked for it by name" — and say is never asked. Put one ElevenLabs or
OpenAI-compatible endpoint in the same section and the requirement comes back,
because the section is shared.

A `base_url` on either endpoint is refused when the configuration loads. These
kinds run a command; an address on one would be read by nothing, and a field
that is silently dropped reads as a setting that took.

### What it costs, measured

```
say -v Yuna -o out.aiff "안녕하세요 키퍼입니다"        →  84KB, immediate
whisper-cli -m ggml-large-v3-turbo -l auto -nt -f out.wav
  → auto-detected language: ko (p = 0.998641)
  → " 안녕하세요. 키퍼입니다."                          →  5.1s wall
```

The recording masc makes is already 16 kHz mono 16-bit WAV, which is what
whisper.cpp requires, so nothing is converted between the microphone and the
transcript. And `-l auto` detects Korean, so there is no language to configure.

### The trap: a wrong voice name is silent

`say` does not fail on a voice it does not have. It exits 0 and speaks in the
system voice. Worse, a name that exists in several languages picks one of them
without saying which:

| Command | Result on a Korean sentence |
|---|---|
| `say -v NoSuchVoice` | exits 0, 91,028 bytes in the system voice |
| `say -v Eddy` | 4.7KB — an English voice reading Korean |
| `say -v "Eddy (한국어(한국))"` | 72KB — the Korean voice |

So a voice name typed from memory is a coin flip. Take it from the list:

```
say -v '?'
```

The id to put in the configuration is the **whole printed label**, parentheses
included. `say` adds them to names that exist in several languages; trimming
them selects a different language without saying so.

Two shapes in that list will break a parser written from one example: the
columns are space-padded rather than tabbed, and the locale is not always two
letters and two letters — `ar_001` is in it.

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
paths refuse by name before any endpoint is asked. STT requires its
`default_model`. TTS requires a model when an endpoint consumes one; a
say-only or MCP-only section can omit it. A malformed supplied model is rejected.
`[voice.capture]` and `[voice.gate]` are read as strictly as an endpoint is: a
key the section does not know, or a value of the wrong type, fails the load
naming `capture.<key>` or `gate.<key>`, and an absent key takes the default.
For capture that is the measured value; for gate it is `always_allow = false`
and no exemptions, so every speak goes to the Gate: `auto_judge` allows it as
a local output without a judge turn, `manual` parks it for the operator.
`gate.exempt_agents` is a list of agent ids, and an element that is not a
non-blank string is refused by its index, as `gate.exempt_agents[1]`. Field
errors name `<section>.<key>`; a section that is not a table is named
`root.<section>`.

### A load failure is reported per call, not at boot

Nothing reads `[voice]` when the server starts. The first speak, transcribe or
capture after a change is what refuses, and each says so in its own words:

| Path | Refusal |
|---|---|
| speak, transcribe | `voice config load failed: <reason>` |
| capture (TUI `Ctrl-Y`, `keeper_voice_listen`) | `voice config is invalid, so no capture was started: <reason>` |
| `keeper_voice_speak` | `<reason>` itself, as the tool's error `message`, from the one read that decided the Gate route. The Gate is not asked to review a speak that cannot reach a provider |
| `GET /api/v1/voice/config` | 500 carrying the reason, at any time |

`<reason>` is the loader's sentence: the key, the type it wanted, and what it
got, as `capture.trigger_margin_db must be a number, got string: "6"`.

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
the header. The wait is what keeps the tail: a `SIGKILL` in the same instant
as the `SIGTERM` loses about one stdio buffer, a quarter second of a
two-second recording (measured 2026-09-04). That the recording read back is
the whole capture with the wait in place has not been measured on a live
microphone.

`Esc` pays the same wait although the recording is deleted right after:
`Process_eio` stops a cancelled spawn one way, and a kill that skips the grace
is not a path it offers.

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

### What a capture answers

Every capture — `Ctrl-Y` in the TUI and `keeper_voice_listen` — returns one
JSON object whose `status` is one of three words, spelled in
`Voice_bridge.capture_status` and read back by `capture_outcome_of_json`:

| `status` | `text` | `message` |
|---|---|---|
| `transcribed` | the transcript, with `endpoint_id` naming the endpoint that answered; empty when it answered with nothing | — |
| `no_audio` | `""` | why nothing was sent: the room level and the level speech had to clear, when they were measured, or that the recorder produced no audio |
| `discarded` | `""` | the operator discarded a recording that had speech in it |

`/api/v1/voice/transcribe` takes audio it did not record and answers only
`transcribed`. A reader that meets any other word, or no `status` at all, has
a result the bridge did not write, and says so rather than reading it as a
silence.

## TUI

`Ctrl-Y` in a focused composer row starts a capture, and pressing it again
stops one, keeping what was said up to that point -- the usual reason to stop
is that the sentence is finished and the trailing-silence wait is two seconds
away. `Esc` discards the recording instead, which is the only place in the
capture path where the operator says what they want rather than the levels
inferring it; after speech the result is `discarded`, so the transcript says a
sentence was thrown away rather than that nothing was heard. Either key before
any speech aborts and yields `no_audio`, so reaching for the wrong one costs
nothing. The transcript is appended to the
draft, not sent. A meter runs in the prompt while it records, because a
dead input device and a quiet room both end as an empty draft and nothing else
separates them.

The binding is a control code because every printable key in a focused row is
draft text.

## External devices

Any device that can make two HTTP calls can speak to a keeper. No MASC change
is needed; this was verified end to end on 2026-09-04.

```sh
TOKEN=$(cat "${MASC_BASE_PATH:?set it to the base path the server runs with}/.masc/auth/admin.token")

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

## Checking that voice actually answers

`GET /api/v1/voice/config` says whether the configuration loads. It does not say
whether any endpoint responds, and the fallback chain hides the difference: it
stops at the first endpoint that answers, so a chain that works says nothing
about the endpoints behind it. A dead fallback looks exactly like a healthy one
until the endpoint in front of it goes away.

`masc voice-verify` asks every endpoint separately and reports each.

```sh
masc voice-verify                          # TTS only
masc voice-verify --audio utterance.wav    # TTS and STT
masc voice-verify --json                   # one JSON object instead of the report
masc voice-verify --message "확인합니다"     # say it in the language you actually use
```

Exit status is 0 when at least one endpoint answered, 1 when none did. A
configuration that does not load is reported as the loader's own sentence, the
same one the speak and transcribe paths would have refused with.

Each TTS probe is a real synthesis request. On a metered provider that costs
what one short sentence costs; the audio is discarded once its size is counted.

### Making an utterance to probe STT with

macOS ships a Korean voice, so no recording is needed:

```sh
say -v Yuna "음성 연결을 확인합니다" -o probe.aiff
afconvert -f WAVE -d LEI16@16000 -c 1 probe.aiff probe.wav
masc voice-verify --audio probe.wav
```

16 kHz mono 16-bit is what the capture path records and what whisper.cpp wants.

### What a working workstation answered

Measured 2026-09-12 on one workstation (M3 Max, macOS) with
`scripts/whisper-server.sh start` running:

```
tts
  elevenlabs-direct      elevenlabs_direct  answered: 24285 bytes of audio

stt  (probe.wav)
  whisper-local          openai_compat      answered: heard 음성 연결을 확인합니다.
  elevenlabs-stt         elevenlabs_direct  answered: heard 음성 연결을 확인합니다.
```

Both STT endpoints transcribed the Korean correctly. That agreement is the thing
worth having before trusting a chain — the local endpoint and the hosted one
heard the same sentence, so a failover between them does not change what a
keeper receives.

### Reading the report

| Word | Means |
|---|---|
| `answered` | the endpoint was reached and did the work |
| `refused` | the endpoint said no, in its own words rather than a summary |
| `not asked` | disabled in the configuration, or a kind that does not do this |

An empty transcript reads as `answered: reached, and heard nothing in the audio`
rather than as a refusal. The endpoint was there and the audio had nothing in
it, and those two are exactly what an empty composer draft cannot tell apart on
its own.

`voice_mcp` endpoints are `not asked` for transcription: that kind synthesizes
through an MCP tool call and has no transcribe path, as the kind table above
says.

### The same probes over HTTP

The wizard calls these rather than shelling out. Both are admin-gated, for the
reason `/voice/transcribe` is: a TTS probe spends a credit on a metered
provider.

```sh
TOKEN=$(cat "${MASC_BASE_PATH:?}/.masc/auth/admin.token")

curl -sX POST "$MASC/api/v1/voice/probe/tts" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"message":"음성 연결을 확인합니다"}'

curl -sX POST "$MASC/api/v1/voice/probe/stt" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: audio/wav' \
  --data-binary @probe.wav
```

Both answer one shape:

```json
{"endpoints":[{"endpoint_id":"whisper-local","kind":"openai_compat",
               "state":"answered","detail":"heard 음성 연결을 확인합니다."}]}
```

`state` is one of `answered`, `refused`, `skipped`. A reader that meets a fourth
has a result this path did not write, and should say so rather than treating it
as a success.

The audio goes in the **raw body**, not as multipart — the same as
`/voice/transcribe`, and the same trap that costs time to rediscover.

## Setting voice up from the TUI

`p` until the pane strip reaches voice, then `e`.

The pane itself reads two routes. `/api/v1/voice/config` is public and answers
whether things load; `/api/v1/voice/setup` is admin-gated and names each
endpoint, so the pane lists them by id, kind and address. A chain that has
quietly gone dead looks healthy in the first and is visible in the second.

### The questions

| Step | Asked when |
|---|---|
| side | always — speech out or speech in |
| provider | always |
| name | always — how the entry is addressed later |
| address | not for ElevenLabs, which carries its own |
| credential variable | not for an MCP tool |
| model | always |
| voice | speech out only |
| review | always |

`enter` moves forward, `up` moves back, `esc` leaves without writing. The side
and the provider walk on `←` / `→` / space, because both are closed sets;
everything else is typed. `ctrl-u` clears a field.

Two blanks are real answers rather than unfinished ones:

- **a blank credential variable** sends no Authorization header, which is what a
  local server that never asked for one answers 200 to;
- **a blank address** offers the addresses a local server usually listens on, as
  starting points. The wizard cannot tell what is running on a port — the probe
  decides that.

### What saving does

The save carries the revision the pane read. A wizard left open while something
else wrote is told its read went stale rather than overwriting that writer.

On success the pane reloads, and for speech out every configured endpoint is
asked to say one sentence. Each answer is shown, **including the refusals** —
that is the part a fallback chain hides by stopping at the first endpoint that
answers.

Speech in is not probed there: transcription needs audio the pane does not have.
Use `masc voice-verify --audio FILE`, and see above for making a file.

### What it will not do

The wizard does not install or start anything. It registers an address and
checks whether something answers on it. Starting a local server is still
`scripts/whisper-server.sh start` in the `me` repo, or whatever that server's own
command is.

### How much of this was measured

The CLI numbers above came from real runs against the real endpoints. The
screen did not: nobody has opened this wizard in a terminal yet, because doing
so needs a server booted from this branch and a stray `--base-path` boot has
rewritten the recorded default workspace before (#35101).

What stands in for that, and what it is worth:

| Claim | Held by | What it cannot tell you |
|---|---|---|
| the questions, their order, and when a draft is enough | `test/voice_wizard` | nothing about the terminal |
| step position, typed text, and what survives going back | `test/voice_wizard_session` | nothing about the terminal |
| the pane hands over to the wizard; every mover has a key | `test/test_tui_voice_wizard_wiring.ml` | that the drawing is legible |
| the wire shape both ends agree on | save request → apply → loader, in `test/voice_wizard` | that the pane sends it |
| the wizard drawn and walked in a real terminal, and what it puts on the wire | `dune build @test/runtest-test_tui_keyboard_input-voice-wizard` | that a live server accepts it |

The last row is the one that found something. Everything above it was green
while typing an endpoint name containing `i` put the `i` into a keeper message
and sent the rest of the word after it: the composer sees every key before the
field does, and the list of places it must not do that named six fields by hand
and did not name this one. `whisper` reached the screen as `wh`.

That scenario now walks to the end and presses save, and reads the request the
wizard posts: the revision the pane was showing, a `put_endpoint` carrying the
name that was typed, the default model, the default voice — and the **name** of
the credential variable, never a value, which is asserted rather than assumed
because `runtime.toml` is committed. The other half, that such a request
actually writes a loadable `[voice]` section, is `save_request` → `apply` →
loader in `test/voice_wizard`.

So both ends of the wire are measured against the same shape. What nobody has
done is run the two against each other with a real server on the other side.

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
Then run `masc voice-verify`: the config route answers whether the settings
load, and that one answers whether anything on the other end responds.
