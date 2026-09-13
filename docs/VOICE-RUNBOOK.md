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

`/usr/bin/say` is in the base system and carries **nine Korean voices** among
184 total. Nothing in the base system transcribes: macOS dictation is not
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
| `brew install sox` | 2.4MB installed, 14.4.2; its `rec` makes the file to transcribe |

The third one is easy to leave out and was. Transcribing a file and making one
are different halves: masc records a capture with sox's `rec` and marks the
start and end of a recording with sox's `play`. Neither is in the base system.

The tones say nothing when `play` is missing — they are swallowed at debug
level. The recorder used to say a number. Measured 2026-09-13 by running the
real capture with `PATH` pointed at an empty directory:

| Build | What the capture answered |
|---|---|
| before | `rec exit 127` |
| after | `rec is not installed; it comes with sox. `masc prerequisite-actions whisper` names the install.` |

The number was not only unhelpful but ambiguous. The process runner the
recorder used folds every failure before a process exists — not found, a
denied permission, a working directory that would not open — into exit 127,
so reading 127 as "not installed" would have given some of those the wrong
cause. The recorder now uses the runner that returns the refusal as a value,
names sox only for `Executable_not_found`, and keeps the runner's own sentence
for everything else. Both runners spawn through the same drain, so the cancel
grace that keeps the end of a recording is unchanged.

`test/voice_capture_without_sox` is that measurement kept: it runs
`record_and_transcribe` with an empty `PATH`, so no microphone is opened and
the answer does not depend on whether the machine running it has sox. Putting
the old recorder branch back turns it red with `rec exit 127`.

A device that posts audio to `POST /api/v1/voice/transcribe` needs none of
this; a person speaking into the TUI does.

Neither starts a server. `say` and `whisper-cli` each run once and exit, so
masc runs them the way it runs `curl` for the endpoints that are addresses:
there is no port to pick, nothing to start before speaking, and nothing left
running afterwards. Installing them is still the operator's step, which is what
`prerequisite-actions` is — it names the commands and asks.

Without a `HOME` to build a cache path from, the second step opens the model
downloads page instead of offering a command with nowhere to write. On Linux
both steps are a link: whisper.cpp is built rather than packaged, and naming an
apt package would install something else or nothing.

### Setup asks for a voice on the way past

A fresh install does not have to be told about any of this. The journey asks
as step 3, between the model connection and the sandbox. Walked on this
machine 2026-09-13 in a `TERM=dumb` terminal, which is why the options are
numbered; on a real terminal they are arrow keys:

```
3 · Give imp a voice (optional)
  1) Eddy (한국어(한국)) — ko_KR
  2) Flo (한국어(한국)) — ko_KR
  3) Grandma (한국어(한국)) — ko_KR
  4) Grandpa (한국어(한국)) — ko_KR
  5) Reed (한국어(한국)) — ko_KR
  6) Rocko (한국어(한국)) — ko_KR
  7) Sandy (한국어(한국)) — ko_KR
  8) Shelley (한국어(한국)) — ko_KR
  9) Yuna — ko_KR
  10) Show every voice on this computer (184)
  11) Stay text only
```

Nine rows because the terminal says Korean — read from `LC_ALL`,
`LC_MESSAGES`, `LANG` in that order. An English terminal leads with `en_*`
and the other 175 are one keystroke away.

Picking 2 wrote eight lines and nothing else:

```toml
[[voice.tts.endpoints]]
id = "macos-say"
kind = "macos_say"
enabled = true

[voice.tts]
default_voice = "Flo (한국어(한국))"
```

The parenthesis is part of the name, kept whole. `masc voice-verify` against
that workspace answered `108466 bytes of audio`.

The write goes through `masc voice-local-setup`, which is the same writer the
HTTP route uses — the same revision guard, and the same refusal to publish a
section the loader would reject.

### Hearing is a second question

It is the half that needs the 1.6GB download, so it is asked only after the
first is answered:

```
Let imp hear you too? whisper-cli transcribes locally; the model it reads is 1.6GB.
  1) Speak to imp as well
  2) Speaking only for now
```

Saying yes opens the prerequisite menu — the same one `masc
prerequisite-actions whisper` prints. Leaving it without downloading is not a
failure:

```
Install or start the selected prerequisite
  1) Install whisper.cpp with Homebrew
  2) Download the whisper model masc asks for
  3) Refresh detection
  4) Back to setup choices

→ The model file is not there yet, so imp will speak but not listen.
  Run masc voice-local-setup --model <file> once it is downloaded.
  voice is configured
```

Speaking stayed on. The model path is read from the action that downloads it
rather than spelled here, so the section cannot name a file the download put
somewhere else.

### Cancelling here does not cancel setup

`q` at the voice question prints

```
setup cancelled; existing connections were preserved
Continuing without voice. Run masc voice-local-setup to turn it on later.
```

and the journey goes on to the sandbox, exit 0, `runtime.toml` untouched. An
optional step cannot fail the thing it is optional to — and by this point the
workspace and the model connection are already saved.

### The whole loop, on a fresh workspace, with nothing running

Walked end to end 2026-09-13 on M3 Max / macOS 26. No server was started, and
nothing listened on a port at any point.

```
masc init --base-path /tmp/fresh                      0.79s   1,504 lines written
masc voice-local-setup --base-path /tmp/fresh \
     --list-voices                                    3.05s   184 voices, 9 Korean
masc voice-local-setup --base-path /tmp/fresh \
     --voice Yuna                                     0.59s   9 lines added
masc voice-local-setup --base-path /tmp/fresh \
     --model ~/models/whisper/ggml-large-v3-turbo.bin 0.37s   7 lines added
```

`voice-local-setup` added 16 lines in total and changed none of the 1,504 that
`init` wrote. Then, with `alpha` mapped to a Korean voice by hand:

```
masc voice-verify --agent alpha --audio utterance.wav --message "안녕하세요 키퍼입니다"

tts
  macos-say       macos_say     answered: 119044 bytes of audio in "Eddy (한국어(한국))"

stt  (utterance.wav, 144,276 bytes)
  whisper-local   whisper_cli   answered: heard 안녕하세요. 오늘 음성 설정을 마쳤습니다.
```

| Leg | Wall |
|---|---|
| speak only | 0.75s |
| speak and hear | 3.79s |

The sentence came back exactly as it was spoken, including the full stop. The
transcript is whisper's own; masc passed `-l auto` and did not name a language.

**What this does and does not prove.** It is the two halves a voice turn needs
— a keeper's words become audio in that keeper's voice, and a recording becomes
text a keeper can be sent. It is not a keeper turn: no model was called and no
message was appended to a chat. The turn itself is the two HTTP calls under
[External devices](#external-devices), and the reply comes back as a clip on
the chat line, announced as whatever container it is (see [The announcement has
to agree with it](#the-announcement-has-to-agree-with-it)).

Two downloads stand between a new machine and the hearing half — the 8.9MB
brew bottle and the 1.6GB model, both named by `masc prerequisite-actions
whisper`. Speaking needs neither: every number in the `tts` row above came off
a machine with nothing installed for it.

### Where the chosen voice is written, and why it matters

Walked on a fresh workspace 2026-09-13, `masc init` then
`masc voice-local-setup --voice Yuna`, then one keeper mapped by hand:

```toml
[[voice.tts.endpoints]]
id = "macos-say"
kind = "macos_say"
enabled = true

[voice.tts]
default_voice = "Yuna"

[voice.tts.agent_voices]
alpha = "Eddy (한국어(한국))"
```

```
masc voice-verify --agent alpha  →  119044 bytes of audio in "Eddy (한국어(한국))"
masc voice-verify --agent beta   →   85908 bytes of audio in "Yuna"
```

The mapped keeper gets its own voice; an unmapped one gets the workspace
default. That is the order a reader expects, and it is not free — it depends
on the chosen voice being written to `[voice.tts]` and **not** to the
endpoint.

A voice on the endpoint outranks `agent_voices`. Measured on the same
workspace with the one line `default_voice = "Yuna"` added under
`[[voice.tts.endpoints]]`:

| Endpoint line | keeper `alpha` (mapped to Eddy) | keeper `beta` (unmapped) |
|---|---|---|
| present | **Yuna**, 85,908 bytes — the mapping is ignored | Yuna |
| absent | **Eddy**, 119,044 bytes | Yuna, 85,908 bytes |

Nothing is logged in the first row. The keeper speaks, the bytes are real, and
the voice is simply not the one that was assigned.

The field exists for a reason and is not going away: a voice name is
provider-shaped — `say` takes a label, ElevenLabs a 20-character `voice_id` —
so a workspace that already has a `[voice.tts]` section has a default that
belongs to the other provider, and adding `say` alongside it has to carry its
own. So `voice-local-setup` writes the endpoint voice only in that case
(`Voice_setup.voice_placement`), and a fresh mac — one provider, no section
yet — gets the section default with per-keeper voices layered over it.

The cost of the remaining case is worth stating plainly: on a workspace with
two TTS providers, `agent_voices` does not reach the second one. There is no
per-provider agent mapping. A keeper mapped to an ElevenLabs `voice_id` would
otherwise have that id handed to `say`, which does not fail on a name it does
not have — it speaks in the system voice.

### Outside the journey

```
masc voice-local-setup --list-voices
masc voice-local-setup --voice "Yuna" --model ~/.cache/whisper/ggml-large-v3-turbo.bin
```

### What the configuration then says

```toml
[voice.tts]
default_model = "-"          # say takes no model; the section still needs the key
default_voice = "Yuna"

[[voice.tts.endpoints]]
id = "macos-say"
kind = "macos_say"

[voice.tts.agent_voices]
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

A `base_url` on either endpoint is refused when the configuration loads. These
kinds run a command; an address on one would be read by nothing, and a field
that is silently dropped reads as a setting that took.

### What it costs, measured

The two commands masc runs, verbatim:

```
say -v Yuna --file-format=WAVE --data-format=LEI16@22050 -o clip.wav
  "안녕하세요 키퍼입니다"                               →  111KB, immediate
whisper-cli -m ggml-large-v3-turbo -l auto -nt -f clip.wav
  → auto-detected language: ko (p = 0.998641)
  → " 안녕하세요. 키퍼입니다."                          →  5.1s wall
```

The recording masc makes is already 16 kHz mono 16-bit WAV, which is what
whisper.cpp requires, so nothing is converted between the microphone and the
transcript. And `-l auto` detects Korean, so there is no language to configure.

### Checking one keeper's voice

The section default is not what a keeper speaks in — a keeper mapped under
`[voice.tts.agent_voices]` gets its own. `--agent` probes with that mapping:

```
masc voice-verify --agent sangsu --json
```

Measured on one workstation 2026-09-13, with `sangsu` mapped to a voice that
exists and `nowhere` to a name that does not:

| Probe | Answer |
|---|---|
| (no `--agent`) | `79758 bytes of audio in "Yuna"` |
| `--agent sangsu` | `124690 bytes of audio in "Flo (한국어(한국))"` |
| `--agent nowhere` | `79758 bytes of audio in "NoSuchVoice"` |

All three say `answered`, because `say` answers a name it does not have by
speaking in the system voice. The byte counts cannot separate them either —
the third is the same 79,758 as the default. **The voice name in the report is
what separates them**, and a name that is not in `say -v '?'` is a mapping
that never took.

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

### The second trap: a wrong container is silent too

`say` picks its encoder from the output file name, and it has no MP3 one. It
does not say so:

| Command | Result |
|---|---|
| `say -o clip.mp3 "..."` | **exits 0**, 16 bytes — an empty MP3 tag frame |
| `say -o clip.wav "..."` | exits 1, `Opening output file failed: fmt?` |
| `say --file-format=WAVE --data-format=LEI16@22050 -o clip.wav "..."` | 111KB of 16-bit mono WAVE |

masc names every clip `<token>.<extension>` where the token is also the HTTP
capability the dashboard fetches it by, so for a while the whole `macos_say`
path wrote 16 bytes of silence and reported success. Fixed 2026-09-13: the
container is named in the argv, `Voice_bridge_core.clip_format` carries which
one a clip is in, and the serve route answers the content type of the format
it found rather than `audio/mpeg` for everything.

`masc voice-verify` catches this class on its own — it refuses any clip below
a believable size rather than counting a 0 exit as success:

```
{"tts":[{"endpoint_id":"macos-say","kind":"macos_say",
         "state":"answered","detail":"113528 bytes of audio"}],
 "stt":[{"endpoint_id":"whisper-local","kind":"whisper_cli",
         "state":"answered","detail":"heard 오늘 음성 설정을 마쳤습니다."}]}
```

3.7s wall for both halves on an M3 Max, 2026-09-13.

A failed command reports the **end** of its output, not the start: whisper-cli
prints nine lines about which Metal library it loaded before it says which
model file it could not open.

## Configuration

One section in `runtime.toml`, read by `Voice_config`:

```toml
[voice.tts]             default_model, default_voice, agent_voices, endpoints
[voice.stt]             default_model, endpoints, send_on_stop
[voice.session]         endpoints          # realtime; empty unless configured
[voice.local_playback]  enabled, agents
[voice.capture]         calibration_seconds, trigger_margin_db, trailing_silence_seconds, speech_margin_db, noise_reduction
[voice.gate]            always_allow, exempt_agents
```

### `[voice.stt] send_on_stop`

Whether ending a capture also sends what was heard, instead of leaving it in
the draft for the operator to press Enter on. Off by default: the draft is
also where a spoken half-sentence waits for typing, so sending without a
confirmation step is something to ask for.

A configuring surface can set it, which is the point of it living here:

```json
{"changes":[{"change":"set_send_on_stop","send":true}]}
```

through `POST /api/v1/voice/setup` — the same revision-guarded writer every
other voice change goes through.

> Until 2026-09-13 this setting had two spellings that never met. The TUI read
> `[tui] voice_send_on_stop`, which no surface published; `[voice.stt]
> send_on_stop` was published by `GET /api/v1/voice/config` and by the setup
> route and read by nothing. Both arrived in the same commit, each side had
> tests, and both sides passed. A file that still carries the `[tui]` one now
> gets the default — move the line into `[voice.stt]`.

`[voice.tts]` and `[voice.stt]` are optional. Absent, the speak and transcribe
paths refuse by name before any endpoint is asked. Present, each must name its
`default_model`: a blank one fails the load naming `tts.default_model` or
`stt.default_model`, since a blank name would reach providers as `model_id ""`.
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

### Speaking without touching the keyboard

`Ctrl-Y` records one sentence and appends the transcript to the draft. The
mode that lets a conversation run is a different key:

| Key | What it does |
|---|---|
| `Ctrl-Y` | start a capture; press again to stop and keep what was said |
| `Ctrl-A` | continuous mode on/off — after each capture settles, the next one starts |
| `Esc` | discard a running capture (the draft keeps what was there before) |

Continuous mode measures the room's noise floor **once** when it turns on,
which is what keeps the gap between sentences short enough to speak across; it
measures again if the mode is turned off and on in a different room. Silence
re-arms too, so a pause longer than the trailing-silence window does not end
the mode. Only the key that started it ends it.

Both are control codes rather than letters because every printable key in a
focused composer row is draft text.

That still leaves an Enter per sentence. `[voice.stt] send_on_stop` removes
it: ending a capture hands the draft to the same send path Enter uses. Off by
default, and described under Configuration below.

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

### "Not installed" means not there

For the two command kinds, a `refused` line names why the command did not
run. Measured 2026-09-13 with `voice-verify --audio` on a `whisper_cli`
endpoint whose `command` was pointed at each case in turn:

| `command` points at | Before | After |
|---|---|---|
| a name nothing installs | `… is not installed` | `… is not installed` |
| a file with no execute bit | `… is not installed` | `… could not start: spawn of "…" failed: Permission denied` |
| the real `whisper-cli` | `heard 안녕하세요. 오늘 음성 설정을 마쳤습니다.` | the same sentence |

The second row was the wrong advice. Reinstalling whisper-cpp does not add an
execute bit to a file somewhere else, so the operator would follow the message
and meet it again.

The cause was reading exit 127 as the reason. The process runner these
commands used returns 127 for a program that is not there, and also for every
other failure before a process exists — a permission denied, a working
directory that would not open. The speak, transcribe and voice-listing commands
now use the runner that returns that refusal as a value, and only
`Executable_not_found` is called not installed. A child that runs and itself
exits 127 is reported as an exit with the end of its output, which is what it
is.

`test/voice_command_refusal` spawns both failing cases for real; putting the
127 reading back turns the permission case red with `… is not installed`.

### Setting voice up over HTTP, measured end to end

Run on this machine 2026-09-13 (macOS 26, M3 Max) against a scratch workspace,
every line below copied from the terminal. The token is the workspace's own:

```sh
MASC=http://127.0.0.1:8971
TOKEN=$(cat "$MASC_BASE_PATH/.masc/auth/admin.token")
```

**1 — what is configured now.** A fresh workspace has nothing:

```
GET /api/v1/voice/setup
{"revision":"623b8dbc…","tts":null,"stt":null,"session":null,
 "capture":null,"local_playback":null,"gate":null}
```

**2 — which voices this machine has**, asked before anything is written:

```
POST /api/v1/voice/voices   {"kind":"macos_say"}
→ 184 rows, 9 of them ko_KR
  {"id":"Eddy (한국어(한국))","name":"Eddy (한국어(한국))","language":"ko_KR"}
```

**3 — turn speaking on.** The revision from step 1 goes back as
`expected_revision`, so a second writer cannot be overwritten:

```json
{"expected_revision":"623b8dbc…",
 "changes":[{"change":"put_endpoint","section":"tts",
             "endpoint":{"id":"macos-say","kind":"macos_say"}},
            {"change":"set_tts_default_voice","voice":"Yuna"}]}
```
```
POST /api/v1/voice/setup
→ {"applied":true,"revision":"436a6857…"}
```

No `default_model` anywhere, and the section loads. Against a build without
that narrowing the same request answered
`the edit does not load as a voice configuration, so it was not written:
runtime.toml [voice]: tts.default_model is required` — measured on both, an
hour apart.

**4 — make it speak, for real:**

```
POST /api/v1/voice/probe/tts   {"message":"음성 연결을 확인합니다"}
→ {"endpoints":[{"endpoint_id":"macos-say","kind":"macos_say",
                 "state":"answered","detail":"79758 bytes of audio"}]}
   2.4s wall
```

**5 — turn listening on and make it hear:**

```json
{"changes":[{"change":"put_endpoint","section":"stt",
             "endpoint":{"id":"whisper-local","kind":"whisper_cli"}},
            {"change":"set_default_model","section":"stt",
             "model":"~/models/whisper/ggml-large-v3-turbo.bin"}]}
```
```
POST /api/v1/voice/probe/stt   (raw wav body)
→ {"endpoints":[{"endpoint_id":"whisper-local","kind":"whisper_cli",
                 "state":"answered","detail":"heard 오늘 음성 설정을 마쳤습니다."}]}
   3.1s wall
```

The transcript is the sentence that was spoken, word for word.

Both probe routes answer over HTTP/1.1 and over h2c, because the HTTP/2
gateway carries them too. `curl` speaks HTTP/1.1 unless told otherwise, so the
commands above reach the HTTP/1.1 router. The rest of `/api/v1/voice` is
HTTP/1.1 only — `/voice/transcribe` and `/voice/audio/<token>` return 404 to an
h2c client, which #35592 tracks.

**What the public config then says.** `GET /api/v1/voice/config` needs no
token and carries no model where none was named:

```json
{"status":"ok",
 "tts":{"default_model":null,"default_voice":"Yuna",
        "available_voices":["Yuna"],"available_models":[], …},
 "stt":{"default_model":"…/ggml-large-v3-turbo.bin", …}}
```

`null` and `[]`, not `""` and `[""]` — a model named `""` would read as a
model that exists.

### The clip is served as whatever it is

`GET /api/v1/voice/audio/<token>` needs no bearer token — the 128-bit
filename is the capability, because a browser's `<audio>` element cannot put
a header on its request. What it answers is the format that is on disk, not a
fixed one. Both clips planted by hand and fetched, 2026-09-13:

| On disk | Answer |
|---|---|
| `<token>.wav` (a real `say` clip) | `200`, `content-type: audio/wav`, `content-length: 77580` |
| `<token>.mp3` | `200`, `content-type: audio/mpeg` |
| a token nobody wrote | `404` |
| `not-a-token` | `400` |

This is the reading half of the container fix: for a while every clip was
named `.mp3` whatever was in it, so a say clip either did not exist (16 bytes
of silence) or would have been announced as MP3. A player told the wrong
type either refuses or plays nothing, and neither says why.

### The announcement has to agree with it

The route above is what a clip is **served** as. What a keeper's spoken reply
is **announced** as is a separate field, written when the reply is appended to
the chat, and for a while it was the literal `audio/mpeg` for every clip:

```json
{ "audio": { "token": "9f3c…", "audio_url": "/api/v1/voice/audio/9f3c…",
             "mime": "audio/mpeg" } }
```

A fresh mac speaks through `say`, which writes WAVE. So the route answered
`audio/wav` for bytes the same chat line called MP3: two fields about one
file, disagreeing.

**What this did and did not break, traced 2026-09-13.** The dashboard's
`<audio>` element is given `src` and no `type`, so the browser picks its
decoder from the route's `content-type` and plays the clip correctly. The
field is not decorative either: `normalizeAudioClip` drops a clip that has no
`mime` at all, and the value it keeps is persisted on the chat line and
emitted on the SSE payload. So the cost is not a silent player today — it is
a wrong answer on the wire and in the history to anything that reads it
instead of fetching: an external device following the SSE stream, an export,
a player that picks a decoder from the field rather than the response.

The cause is worth naming because it is not a typo. The path already knew the
container: the helper that turned `…/9f3c.wav` into a token **matched that
extension and then dropped it**, handing back the token alone. The caller,
left holding half the answer, filled in the other half with a constant. Both
halves now come back together (`clip_of_path`), and the record is built in one
place (`Keeper_chat_store.audio_clip_of_synthesized_file`) rather than field
by field at the call site.

`test/voice_clip_announcement` writes a real file and checks that what the
announcement says and what `find_clip` would serve are the same string —
asserting the literal alone would pass again if only one side moved, which is
how this started. Planting `mime = "audio/mpeg"` back turns that suite red on
the WAVE case and nothing else.

A clip under a container masc does not write (`.ogg`, say) is now announced as
no clip at all, with a line in the log, because the serving route resolves a
token by trying each container it knows and would answer `404` for it however
it was labelled. The reply is still recorded as text.

### Speaking to a keeper, not just probing it

The probe and the turn are different code paths, and for a while only the
probe worked. `POST /api/v1/voice/transcribe` — the route a browser capture
goes through — reached for HTTP whatever the endpoint kind was, so the one a
fresh mac has answered:

```
{"error":"all enabled STT endpoints failed:
          whisper-local: voice config endpoint whisper-local missing base_url"}
```

while `voice-verify --audio` on the same configuration transcribed it fine.
That is the shape worth naming: **a check that passes about a path that does
not exist.** Fixed in #35627; measured on that build, same workspace, same
`probe.wav`:

```
POST /api/v1/voice/transcribe   (raw wav body)
→ {"status":"transcribed","text":"오늘 음성 설정을 마쳤습니다.",
   "language_code":"unknown","endpoint_id":"whisper-local"}
   6.9s wall (first call — the 1.6GB model is loaded per invocation)
```

`language_code` is `unknown` because the command answers with its transcript
and no such field. whisper-cli was asked to detect the language (`-l auto`)
and it does, but on its own stderr rather than on the wire. A caller that
names a language is answered with that name.

### What each route refuses, measured

| Request | Answer |
|---|---|
| `voices` with no bearer token | `401` |
| `voices` with `{"kind":"kokoro"}` | `400` — the kind is quoted back with the five that exist |
| `probe/tts` with `{}` | `400 a probe needs a non-empty "message" …` |
| `probe/stt` with an empty body | `400` |

Every one of them is a sentence rather than a shape, and none of them is an
empty success: a probe of the empty sentence and a transcript of silence are
both answers a reader would believe.

The audio goes in the **raw body**, not as multipart — the same as
`/voice/transcribe`, and the same trap that costs time to rediscover.

`state` is one of `answered`, `refused`, `skipped`. A reader that meets a
fourth has a result this path did not write, and should say so rather than
treating it as a success.

Both probe routes and the catalogue are `CanAdmin`, for the reason
`/voice/transcribe` is: a TTS probe synthesizes for real, and on a metered
provider that spends a credit. The catalogue reaches a provider with the
operator's credential. Only `GET /api/v1/voice/config` and the clip URL are
open, and the clip URL is a 128-bit unguessable token.

A catalogue request carries the kind and, at most, the **name** of the
variable holding the provider's key — never a value, because `runtime.toml`
is committed. It carries no address and no command path: a route cannot check
where one points, so the read uses the kind's own destination.

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
