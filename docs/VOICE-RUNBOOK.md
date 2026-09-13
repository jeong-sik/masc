---
status: runbook
---

# Voice Runbook

Speech into and out of MASC: which endpoints carry it, what an operator has to
run locally, and the two calls an external device makes. Numbers were measured
on one workstation (M3 Max, macOS 26), and each section says when.

## Starting from nothing on a new mac

A mac that has just been unboxed can speak without installing anything, and
needs three installs to hear. Measured on macOS 26 / M3 Max, 2026-09-12 and
2026-09-13. The fresh-machine steps below were run with only `HOME` and `PATH`
set (`env -i`), so nothing a workstation already exports — `MASC_BASE_PATH`,
a Homebrew prefix, a model cache — stood in for the new machine.

### What is already there

`/usr/bin/say` is in the base system and carries **nine Korean voices** among
184. Nothing in the base system transcribes or records to a file masc can
read: macOS dictation is not scriptable.

### What hearing needs

```
masc prerequisite-actions whisper
```

names every step and runs none until one is chosen:

| Step | What it installs |
|---|---|
| `brew install whisper-cpp` | 8.9MB bottle; its `whisper-cli` transcribes a file |
| the model | `ggml-large-v3-turbo.bin`, 1,624,555,275 bytes, fetched to a `.part` and moved into place once complete |
| `brew install sox` | 2.4MB installed, 14.4.2; its `rec` records the file, its `play` sounds the start and end tones |

None of them starts a server. `say`, `rec` and `whisper-cli` each run once and
exit, so there is no port to pick and nothing left running.

Transcribing and recording are separate halves. A device that posts audio to
`POST /api/v1/voice/transcribe` needs only the first two; a person speaking
into the TUI needs `sox` as well. A capture with no `rec` on `PATH` answers

```
rec is not installed; it comes with sox. `masc prerequisite-actions whisper` names the install.
```

A new mac has no Homebrew, and two of the steps are Homebrew steps. Choosing
one answers

```
Homebrew is not installed (brew is not on PATH), so nothing ran. Install it from https://brew.sh, then retry.
```

and any other program that is not there is named the same way — `curl is not
on PATH, so nothing ran.` for the model download.

Without a `HOME` to build a cache path from, the model step opens the model
downloads page instead of offering a command with nowhere to write. On Linux
whisper.cpp is built rather than packaged, so its steps are links; `sox` is an
`apt-get` command on Debian and Ubuntu and a link elsewhere.

### The install journey asks

The journey asks as step 3, between the model connection and the sandbox.
Walked in a `TERM=dumb` terminal, which is why the options are numbered — a
real terminal uses arrow keys — answering 9, 1, 5:

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

Let imp hear you too? whisper-cli transcribes locally; the model it reads is 1.6GB.
  1) Speak to imp as well
  2) Speaking only for now

Install or start the selected prerequisite
  1) Install whisper.cpp with Homebrew
  2) Download the whisper model masc asks for
  3) Install sox, which masc records with
  4) Refresh detection
  5) Back to setup choices

imp can transcribe audio sent to it, but masc records from the microphone with sox's rec, which is not installed. Install sox (masc prerequisite-actions whisper names the command) before speaking into the TUI.
voice is configured
```

Nine rows because the terminal says Korean — read from `LC_ALL`,
`LC_MESSAGES`, `LANG` in that order. An English terminal leads with `en_*`.

Hearing is configured when `whisper-cli` is on `PATH` and the model file is
where the download step writes it; the step reads that path from the catalog's
`writes` field rather than from the download's argv. Otherwise the journey
says `Listening needs both whisper-cli and a model file, so imp will speak but
not listen` and configures speaking alone. The `sox` line above appears only
when `rec` is missing.

If the voice listing itself fails, the step prints the listing's own last
error line and moves on; it does not skip the question silently.

`q` at the voice question prints

```
setup cancelled; existing connections were preserved
Continuing without voice. Run masc voice-local-setup to turn it on later.
```

and the journey goes on to the sandbox with `runtime.toml` untouched. By this
point the workspace and the model connection are already saved.

The workspace this walk wrote answered:

```
masc voice-verify --base-path <workspace> --audio utterance.wav
  macos-say       macos_say     answered: 85908 bytes of audio in "Yuna"
  whisper-local   whisper_cli   answered: heard 안녕하세요. 오늘 음성 설정을 마쳤습니다.
```

### Outside the journey

```
masc init --base-path ~/work
masc voice-local-setup --base-path ~/work --list-voices
masc voice-local-setup --base-path ~/work --voice "Yuna" --model ~/.cache/whisper/ggml-large-v3-turbo.bin
masc voice-verify --base-path ~/work --audio utterance.wav
```

Every command names the workspace. The voice loader finds `runtime.toml`
through the environment, and a directory is not taken as a workspace just
because the command runs inside it: with no `--base-path`, no `MASC_BASE_PATH`
and no recorded default, `voice-verify` answers

```
voice config missing: no workspace is resolved (MASC_BASE_PATH and MASC_CONFIG_DIR are unset), and no <cwd>/.masc/voice_config.json
```

and names the lookup it did make in the other cases — `no masc configuration
at <base>/.masc/config` for a directory never initialized, `no [voice] section
in <base>/.masc/config/runtime.toml` for a workspace without one.

Voice is a section of the configuration `masc init` writes. On a directory
that was never initialized, `voice-local-setup --voice` answers, exit 1 and
nothing created:

```
No masc workspace at <base>: <base>/.masc/config/runtime.toml does not exist. Run masc init --base-path '<base>' first, then this again.
```

`--list-voices` reads `say` and nothing under the workspace, so an
uninitialized directory is enough — but, like every masc command, it needs a
base path:

| `voice-local-setup --list-voices` | exit | stdout |
|---|---|---|
| no `--base-path`, no `MASC_BASE_PATH`, no recorded default | 1 | 0 bytes |
| `--base-path` at a directory never initialized | 0 | 14,420 bytes |
| `--base-path` at an initialized workspace | 0 | 14,420 bytes |

The writer is the one the HTTP setup route uses: the same revision guard, and
the same refusal to publish a section the loader would reject.

### What the configuration says

After a voice, a model, and one keeper mapped by hand:

```toml
[[voice.tts.endpoints]]
id = "macos-say"
kind = "macos_say"
enabled = true

[voice.tts]
default_voice = "Yuna"

[voice.tts.agent_voices]
alpha = "Eddy (한국어(한국))"

[[voice.stt.endpoints]]
id = "whisper-local"
kind = "whisper_cli"
enabled = true

[voice.stt]
default_model = "/Users/you/.cache/whisper/ggml-large-v3-turbo.bin"
```

The speaking section names no `default_model`: `say` takes none, and the
section needs one only when it also holds a kind that is asked for a model by
name. The listening section always needs one, and for `whisper_cli` it is a
**file path** — what `-m` loads. A `base_url` on either command endpoint fails
the load, naming the endpoint and its kind:

```
runtime.toml [voice]: stt.endpoints[0].base_url means nothing for whisper_cli, which runs a command
```

The voice name is the **whole label** `say` prints, parentheses included.

### Which voice a keeper speaks in

A keeper listed under `[voice.tts.agent_voices]` speaks in that voice; every
other keeper speaks in `[voice.tts] default_voice`. Measured on the
configuration above:

```
masc voice-verify --base-path ~/work --agent alpha  →  119044 bytes of audio in "Eddy (한국어(한국))"
masc voice-verify --base-path ~/work --agent beta   →   85908 bytes of audio in "Yuna"
```

A `default_voice` on the **endpoint** outranks both, for every keeper at that
endpoint. With `default_voice = "Yuna"` added under `[[voice.tts.endpoints]]`,
`--agent alpha` answers `85908 bytes of audio in "Yuna"`, and nothing is
logged.

That field is for a section shared by providers whose voice names differ in
shape — `say` takes a label, ElevenLabs a 20-character `voice_id`. When another
provider shares the section, its default belongs to that provider, and
`voice-local-setup --voice` writes the `say` voice onto the `say` endpoint.
When every endpoint in the section is `say`, the command writes the section
default and leaves the endpoint without a voice — on every run, removing one
an endpoint already carries.

On a section shared by two providers, `agent_voices` therefore does not reach
the `say` endpoint. There is no per-provider keeper mapping.

`--agent` is the check for a mapping. `say` answers a name it does not have by
speaking in the system voice, so a mapping to a missing voice still reads
`answered`, with the same byte count as the default. The voice name in the
report is what tells them apart:

| Probe | Answer |
|---|---|
| (no `--agent`) | `79758 bytes of audio in "Yuna"` |
| `--agent sangsu` (mapped to an installed voice) | `124690 bytes of audio in "Flo (한국어(한국))"` |
| `--agent nowhere` (mapped to `NoSuchVoice`) | `79758 bytes of audio in "NoSuchVoice"` |

A name that is not in `say -v '?'` is a mapping that never took.

### The whole loop, measured

A fresh workspace, run from another directory with only `HOME` and `PATH` set,
no server started, nothing listening on a port:

```
masc init --base-path /tmp/fresh                                    1,504 lines written
masc voice-local-setup --base-path /tmp/fresh --list-voices         184 voices, 9 Korean
masc voice-local-setup --base-path /tmp/fresh --voice Yuna
masc voice-local-setup --base-path /tmp/fresh --model <ggml-large-v3-turbo.bin>
                                                                    16 lines added in all
```

`voice-local-setup` changed none of the 1,504 lines `init` wrote. With `alpha`
mapped to a Korean voice:

```
masc voice-verify --base-path /tmp/fresh --agent alpha --audio utterance.wav --message "안녕하세요 키퍼입니다"

tts
  macos-say       macos_say     answered: 119044 bytes of audio in "Eddy (한국어(한국))"

stt  (utterance.wav, 144,276 bytes)
  whisper-local   whisper_cli   answered: heard 안녕하세요. 오늘 음성 설정을 마쳤습니다.
```

| Leg | Wall, three runs |
|---|---|
| speak only | 0.72s, 0.57s, 0.58s |
| speak and hear | 3.42s, 1.99s, 1.89s |

Single runs of the setup commands varied 2–4x between walks — `init` took
0.79s on one and 1.89s on another — so no figure is given for them.

The sentence came back as spoken, full stop included; masc passed `-l auto`
and named no language.

This is the two halves a voice turn needs — a keeper's words become audio in
that keeper's voice, and a recording becomes text a keeper can be sent. It is
not a keeper turn: no model was called and nothing was appended to a chat. The
turn follows.

### Talking to imp, measured

The same kind of workspace, with a model connection added and the server
started. The model was `Qwen3.8-27B` (Q4, 35.5GB) on local Ollama, already in
memory, on an M3 Max whose load average was 25.8 from other work. The wall
times below are that machine under that load; they say nothing about an M1
with a cloud model.

**imp does not answer until it has a sandbox.** The journey prepares one at
step 4. Before that, a message to imp answers
`Keeper owner not found: imp`, and booting imp with no `docker` on `PATH`
answers `400`:

```
docker_preflight_failed: docker info failed while validating sandbox runtime: process_eio_error: Eio.Io Process Executable "docker" not found; keeper sandbox image masc-sandbox:general is not available locally: …
```

With Docker reachable and the image present, `POST /api/v1/keepers/imp/boot`
answered `200` in 0.12s.

**The token for HTTP comes from `masc login`.** A server started without
`MASC_ADMIN_TOKEN` mints one in memory and writes no file for it:

```
masc login --base-path <base> --client-env MASC_TOKEN
  role: admin
  raw_token_file: <base>/.masc/auth/local-admin.token
```

That file's token was accepted by `/voice/transcribe` on a server started
afterwards.

**A spoken question gets a written answer.** `question.wav` is `say -v Yuna`
reading `안녕하세요. 한 문장으로 자기소개를 해 주세요.` (4.8s):

| Step | Wall | What came back |
|---|---|---|
| `POST /api/v1/voice/transcribe` | 2.5s | `안녕하세요. 한 문장으로 자기소개를 해주세요.` |
| `POST /api/v1/keepers/chat/stream`, the transcript | 188s | one sentence of text, no audio |

Of the 188s, 167 went before the first event from the model. masc recorded
16,863 prompt tokens, none read from a cache, and 4.5 tokens a second decoded.

**imp speaks only when it calls `keeper_voice_speak`.** Nothing turns a reply
into speech on its own. Asked `방금 한 자기소개를 소리 내어 말해 주세요.`, imp
made three calls:

| At | Call | Result |
|---|---|---|
| 45.7s | `keeper_tool_search` for `keeper_voice_speak` | `now callable: keeper_voice_speak` |
| 259.6s | `keeper_skill` for a `voice-speak` skill | error — no such skill; the model guessed the name |
| 290.1s | `keeper_voice_speak` with the sentence | a 14.2s clip in 3.2s |
| 308.0s | reply | text |

No approval was asked for; the log line is
`external effect authorized operation=keeper_voice_speak source=local_output`.
The model's first event came 29s after the question, 200s after the tool
search, 13s after the skill call and 4.5s after the speak call.

**The clip is made and nobody hears it.** The call wrote a 14.2s WAV and put it
on the chat line:

```json
"audio":{"token":"124eb1c9…","mime":"audio/wav","audio_url":"/api/v1/voice/audio/124eb1c9…","duration_sec":14.242993}
```

`GET` on that URL with no token answered `200 audio/wav`, 632,212 bytes. The
call's result says

```
"status":"synthesized","local_playback_status":"skipped","local_playback_reason":"local playback disabled for agent"
```

because `[voice.local_playback]` is absent and absent means off. `spoken` is
the status only when this host played the clip. The TUI does not play clips at
all. The dashboard's chat line for imp showed the clip as a card — a waveform,
`0:14`, and the sentence — over an `<audio>` element with controls, no
autoplay, and `paused` still true after the page had loaded. Until someone
presses play there, the reply is silent.

imp relays that. Asked to say `오늘 음성 설정을 마쳤습니다` aloud, it called
`keeper_voice_speak` at 168.9s and replied at 203.6s:

```
"오늘 음성 설정을 마쳤습니다"라는 음성을 합성해 채팅에 첨부했습니다. 다만 이 호스트에서는 에이전트의 로컬 재생이 꺼져 있어 실제로 소리 내어 재생되지는 않았으니, 첨부된 오디오 파일을 확인해 주세요.
```

### What the commands cost

The two commands masc runs, verbatim:

```
say -v Yuna --file-format=WAVE --data-format=LEI16@22050 -o clip.wav
  "안녕하세요 키퍼입니다"                               →  111KB, immediate
whisper-cli -m ggml-large-v3-turbo -l auto -nt -f clip.wav
  → auto-detected language: ko (p = 0.998641)
  → " 안녕하세요. 키퍼입니다."                          →  5.1s wall
```

The recording masc makes is 16 kHz mono 16-bit WAV, which is what whisper.cpp
reads, so nothing is converted between the microphone and the transcript.
Each `whisper-cli` run loads the model file itself; nothing stays resident
between transcripts.

### The traps

**A wrong voice name is silent.** `say` exits 0 on a voice it does not have
and speaks in the system voice. A name that exists in several languages picks
one of them without saying which:

| Command | Result on a Korean sentence |
|---|---|
| `say -v NoSuchVoice` | exits 0, 91,028 bytes in the system voice |
| `say -v Eddy` | 4.7KB — an English voice reading Korean |
| `say -v "Eddy (한국어(한국))"` | 72KB — the Korean voice |

Take the name from `say -v '?'`. Its columns are space-padded, and the locale
is not always two letters and two letters — `ar_001` is in the list.

**A wrong container is silent too.** `say` picks its encoder from the output
file name and has no MP3 encoder:

| Command | Result |
|---|---|
| `say -o clip.mp3 "..."` | **exits 0**, 16 bytes — an empty MP3 tag frame |
| `say -o clip.wav "..."` | exits 1, `Opening output file failed: fmt?` |
| `say --file-format=WAVE --data-format=LEI16@22050 -o clip.wav "..."` | 111KB of 16-bit mono WAVE |

masc names the container in the argv and writes `say` clips as `.wav`.
`masc voice-verify` refuses any clip below a believable size rather than
counting a 0 exit as success.

**A command that did not run says why.** For the two command kinds a
`refused` line names the reason:

| `command` points at | `voice-verify` reports |
|---|---|
| a name nothing installs | `… is not installed` |
| a file with no execute bit | `… could not start: spawn of "…" failed: Permission denied` |
| a program that ran and failed (`whisper_cli`) | `… exit <code>: <the end of its output>` |

A failure reports the **end** of the command's output: `whisper-cli` prints
nine lines about which Metal library it loaded before it names the model file
it could not open.

**whisper-cli does not refuse audio it cannot read.** For a container it does
not decode it prints `error: failed to read audio file` to stderr and exits 0
with nothing on stdout — the same answer as a recording of silence. The same
sentence, encoded eight ways, through whisper-cpp 1.9.2:

| Container | First bytes | whisper-cli |
|---|---|---|
| WAV | `RIFF…WAVE` | transcribes |
| FLAC | `fLaC` | transcribes |
| MP3, ID3-tagged | `ID3` | transcribes |
| MP3, from the first frame | `FF F3` | transcribes |
| WebM | `1A 45 DF A3` | exit 0, empty |
| Ogg Opus | `OggS` … `OpusHead` | exit 0, empty |
| AIFF-C | `FORM…AIFC` | exit 0, empty |
| M4A | `…ftyp` | exit 0, empty |

masc reads the first 36 bytes before running whisper-cli and refuses the four
it does not read, naming the container:

```
masc voice-verify --base-path ~/work --audio probe.webm
  whisper-local   whisper_cli   refused: whisper-cli reads WAV, FLAC or MP3, and this audio is WebM
```

A container whose first bytes are none of the eight — Ogg Vorbis, AAC — is
handed to whisper-cli, since none of those was measured.

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

`[voice.tts]` and `[voice.stt]` are optional. Absent, the speak and transcribe
paths refuse by name before any endpoint is asked. `[voice.stt]` always names a
non-blank `default_model`. `[voice.tts]` names one when any of its endpoints is
a kind asked for a model by name — every kind except `macos_say`; a section of
`macos_say` endpoints alone needs none. A missing or blank one where it is
needed fails the load as `tts.default_model is required` or
`stt.default_model is required`.
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

A reader that has a default to fall back on — the voice for a keeper, the
tuning, whether to play locally — falls back and logs
`<what> falling back: voice config is present but unusable: <reason>` on every
read. A workspace with no voice configuration at all logs nothing: that is not
a fault.

An endpoint declares a `kind`, and the kind decides the request that gets
built — not a string match on the URL:

| `kind` | TTS | STT | Auth |
|---|---|---|---|
| `elevenlabs_direct` | `POST <base>/text-to-speech/<voice_id>` | `POST <base>/speech-to-text` | `xi-api-key` |
| `openai_compat` | `POST <base>/audio/speech` | `POST <base>/audio/transcriptions` | `Authorization: Bearer`, omitted entirely when no `api_key_env` |
| `voice_mcp` | MCP tool call | — | — |
| `macos_say` | `say -v <voice> --file-format=WAVE --data-format=LEI16@22050 -o <clip>.wav <text>` | — | — |
| `whisper_cli` | — | `whisper-cli -m <default_model> -l auto -nt -f <audio>` | — |

The two command kinds take an optional `command` naming the executable and
refuse a `base_url`.

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
by the endpoint field whitelist: a key an endpoint does not know fails the
load, naming it.

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

`record_and_transcribe` decides where a recording starts and ends. sox only
records: it writes continuously, the level is read straight from the growing
file ten times a second, and one number drives the trigger, the end, and the
bar the operator watches.

Three measurements on one workstation (2026-09-03/04) fix the design:

| | |
|---|---|
| Noise floor, pass one | −37.2 dB |
| Noise floor, pass two, minutes later, same room | −26.3 dB |
| Peak across five probes of one idle room | moved 1.9x |
| RMS across the same probes | moved 1.2x |

The room moves by more than 10 dB, so the threshold follows the room rather
than a constant. Peak wanders on a room that has not changed, so the level is
RMS. And sox's own `silence` filter is not used: it writes nothing — not even a
WAV header — until its trigger fires, so there would be no level to show while
the operator waits.

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
default, and described under Configuration above.

## External devices

Any device that can make two HTTP calls can send speech to a keeper and read
its answer. Hearing the answer is a third call, and only when the keeper spoke
— see [Talking to imp, measured](#talking-to-imp-measured).

```sh
BASE=~/work
masc login --base-path "$BASE" --client-env MASC_TOKEN
TOKEN=$(cat "$BASE/.masc/auth/local-admin.token")

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

If voice behaves oddly, read `GET /api/v1/voice/config` first: it is the one
surface that tells "not configured" from "configured and broken", and it
answers 500 with the loader's reason at any time.

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
masc voice-verify --base-path ~/work       # a workspace that is not MASC_BASE_PATH
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

### The chat line names the same type

A keeper's spoken reply is appended to its chat with an `audio` record, and
that record's `mime` is the type the clip route serves for the same file —
`audio/wav` for a `say` clip, `audio/mpeg` for an HTTP provider's:

```json
{ "audio": { "token": "9f3c…", "audio_url": "/api/v1/voice/audio/9f3c…",
             "mime": "audio/wav" } }
```

The dashboard's `<audio>` element plays from the route and does not read the
field; the field is what the chat history and the SSE payload carry to
anything that reads them instead of fetching. A synthesized file under a
container masc does not write is announced as no clip, with a line in the log,
and the reply is kept as text.

### Speaking to a keeper, not just probing it

`POST /api/v1/voice/transcribe` — the route a browser capture goes through —
transcribes with the same endpoint kinds `voice-verify` probes, the command
kinds included. On a workspace whose only STT endpoint is `whisper_cli`, with
the same `probe.wav`:

```
POST /api/v1/voice/transcribe   (raw wav body)
→ {"status":"transcribed","text":"오늘 음성 설정을 마쳤습니다.",
   "language_code":"unknown","endpoint_id":"whisper-local"}
   6.9s wall
```

`language_code` is `unknown` because the command answers with its transcript
and no such field. whisper-cli detects the language (`-l auto`) but reports it
on its own stderr, not on the wire. A caller that names a language is answered
with that name.

The dashboard microphone uploads WAV. `MediaRecorder` records WebM in
Chromium, which whisper-cli does not read, so `voice-wav.ts` decodes the
recording with the browser's own decoder at 16 kHz, mixes it to mono and
uploads 16-bit PCM — the format the TUI records. Measured in headless
Chromium 149, with a synthesized sentence as the fake microphone and a
`whisper_cli`-only workspace:

| What was posted | Size | Answer |
|---|---|---|
| the recording as `MediaRecorder` made it (`audio/webm;codecs=opus`, 2.5s) | 39,902 bytes | `400 … whisper-cli reads WAV, FLAC or MP3, and this audio is WebM` |
| the same recording after `recordingToWav`, 22ms in the page | 78,764 bytes | `200 {"status":"transcribed","text":"오늘 음성 설정을 마쳤습니다.", …}` in 2.0s |
| the source file the fake microphone played | — | the same text |

A recording the browser cannot decode is not uploaded; the dashboard shows
`녹음을 WAV 로 바꾸지 못했습니다: …` in an error toast. The upload is 32KB per
second whatever is said — twice the WebM in the measurement above.

The same, through the dashboard page itself: headless Chromium 149 opened
`/dashboard?agent=admin&token=…#keepers?keeper=imp` on that workspace, with
`question.wav` (4.8s) as the fake microphone.

| Step | What the page did |
|---|---|
| the composer's `음성으로 입력` button, 0.6s after load | showed a recording bar with a `완료` button |
| `완료` after 5.5s | `POST /api/v1/voice/transcribe` with `content-type: audio/wav` → `200 transcribed` |
| 2.8s after `완료` | a `받아쓰기` card above the composer holding the transcript |

The transcript was `안녕하세요 한 문장으로 자기소개 를 해주세요 안녕하세요 한 문장으로 자기`:
Chromium loops a fake microphone file, so 5.5s of recording held the 4.8s
sentence and the start of it again. The card is a draft. Nothing is sent to
the keeper until `전송`.

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
