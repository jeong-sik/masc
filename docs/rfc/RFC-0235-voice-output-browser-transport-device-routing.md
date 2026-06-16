---
rfc: "0235"
title: "Voice output transport: browser-addressed audio delivery with device-routed playback"
status: Draft
created: 2026-06-14
updated: 2026-06-14
author: vincent
supersedes: []
superseded_by: null
related: ["0223"]
implementation_prs: []
---

# RFC-0235: Voice output transport — browser-addressed audio delivery, device-routed playback

Status: Draft · Promotes voice output from a server-local side effect to an
addressable transport · Reuses existing channels (keeper_chat SSE, SSE
subscriber registry) rather than introducing new stores.

> Anchors cited as `file:line` were read against `origin/main` (`a76d22deb`)
> on 2026-06-14 while writing this RFC.

## §1 Problem — the keeper speaks, but only the server's speakers can hear it

Voice output is a server-local side effect today, not an addressed transport.
A keeper's utterance is synthesized to a file and played through whichever
audio player exists on the server host; nothing about the audio reaches any
browser. A mobile browser viewing the dashboard sees the *text* of the
utterance but never the *sound*.

### 1.1 Synthesis and playback are both server-side, end-to-end

`Voice_bridge.agent_speak` (`lib/voice/voice_bridge.ml:618-675`) drives the
whole pipeline inside the server process:

1. dedup check (`is_dedup_hit`, line 619)
2. `cleanup_old_audio_files ()` (line 641)
3. TTS endpoint fan-out via `speak_via_http_tts_to_file`
   (`voice_bridge_transport.ml:138`, `voice_bridge.ml:130/370`) — synthesis
   result written to `$MASC_BASE_PATH/audio/<ts>_<agent>.mp3`
   (`voice_bridge_transport.ml:19-24`)
4. `run_local_playback` (`voice_bridge_core.ml:256`) — execs `afplay` /
   `ffplay` / `mpg123` / `play` / `open` against the server host's sound
   device (`voice_bridge_core.ml:148-162`)
5. lifecycle: files for a *successful* utterance are already retained —
   the Openai/Elevenlabs branch (`voice_bridge.ml:367-453`) has no
   `Sys.remove` on its `Played`/`Opened`/`Failed`/`Skipped` exits.
   `Sys.remove` fires only at `:384` (dedup mutex hit) and `:451`
   (synthesis failure), both producing files that must not be served.
   `:879` is an unrelated tone/recording helper, not `agent_speak`. The
   real reaper for served files is `cleanup_old_audio_files` (1h TTL,
   `voice_bridge.ml:152-175`). (Earlier draft of this RFC claimed
   immediate deletion on every exit path; that was wrong — see §2.4.)

Playback is gated per-agent by `Voice_config.local_playback_enabled_for_agent`
(`voice_config.mli:158`, `voice_bridge_core.ml:262`). The gate's name is the
design tell: "local" is the only destination the system models.

### 1.2 No browser-side audio path exists

A full scan of `dashboard/` for `new Audio(`, `AudioContext`, `MediaSource`,
`<audio`, `createObjectURL`, or audio MIME types returns zero matches outside
timestamp comments. The dashboard can render an utterance's text but has no
code that could play a sound. There is nothing to "fix" client-side; the
transport does not exist.

### 1.3 A push channel and a session registry already exist — unused by voice

Two capabilities this RFC needs are already in the codebase:

- **Push channel.** `Keeper_chat_broadcast.chat_appended ~keeper_name ~source`
  (`lib/keeper/keeper_chat_broadcast.ml:6-31`) emits a `keeper_chat_appended`
  SSE event consumed by the dashboard (`dashboard/src/sse-store.ts:547-561`).
  It is the existing path by which a keeper-originated line appears in the
  dashboard chat panel. Its payload today is `{ name, source }` — text-chat
  metadata only, no audio fields.
- **Session registry.** `lib/sse.mli:113-116` exposes
  `external_subscriber_count`, `external_subscriber_count_with_prefix`,
  `reap_dead_external_subscribers`, `remove_external_subscribers`, and
  `types/types_core.ml:906-911` defines
  `type sse_session = { agent_name; connected_at; last_activity; is_listening }`.
  The server already tracks which SSE subscribers are connected, with a
  per-agent_name dimension.

The gap is not "build a channel" or "build a registry". It is: connect voice
output to the channel, and route it through the registry.

### 1.4 "Local only" is the intended behavior of the voice subsystem, not a bug

Voice was designed for a keeper that speaks into the room its server process
occupies (the 2026-06-10 voice incident and its `run_local_playback` dedup /
duration-probe machinery, `voice_bridge_core.ml:164-203`, exist precisely to
make local playback behave well). Making audio reach a browser is a new
requirement layered on top, not a defect in the existing design. This RFC
treats local playback as a *fallback destination*, not a thing to delete.

### 1.5 The owner's policy is "the connected device only"

Operator decision (2026-06-14): when one or more browsers are connected, the
utterance plays on those browsers and *not* on the server's speakers
simultaneously. When no browser is connected, local playback remains the
output. This rules out the cheap option ("play everywhere") and makes
device-routed delivery a first-class requirement rather than an additive
broadcast.

## §2 Design principles

1. **Addressed output, not side effect.** Voice output gains an explicit
   destination set: `{ browsers; local }`. The default resolution is
   `browsers` when ≥1 subscriber is connected for the keeper, else `local`.
   The current `local`-only behavior is the `local`-destination case with no
   subscribers present.
2. **Reuse, do not add stores.** Audio metadata rides the existing
   `keeper_chat_appended` event. Routing decisions read the existing SSE
   subscriber registry. The synthesized file lives where it already lives
   (`$MASC_BASE_PATH/audio/`). No new persistence, no new channel, no new
   subscriber table. Adding any of those would repeat the keeper_chat ↔
   checkpoint.messages split-brain pattern (cf. RFC-0223 §2.2).
3. **Parse at the boundary, carry typed values inside.** The audio event
   payload is decoded into a closed record once, at the SSE edge; the
   dashboard matches on fields, not on string sniffing. No new string
   classifier branches (CLAUDE.md workaround signature #2).
4. **Lifecycle already fits the new destination.** Successful-utterance
   files are *already* retained until the `cleanup_old_audio_files` 1h TTL
   reaps them (`voice_bridge.ml:152-175`) — the Openai/Elevenlabs success
   branch never calls `Sys.remove`. So P1 needs no lifecycle rewrite: the
   1h window is already wide enough to serve as the browser fetch window.
   The only `Sys.remove` sites (`:384` dedup, `:451` synthesis failure)
   produce unservable files and stay as-is. (Correction of an earlier
   draft that claimed immediate deletion on every exit path.)
5. **OAS boundary respected.** Voice output is a MASC concept. OAS continues
   to receive a host-assembled message list and is unaware of audio delivery
   (mirrors RFC-0223 §2.5). All transport code lives under MASC
   (`lib/voice*`, `lib/keeper*`, `lib/server*`, `dashboard/`).
6. **No standing machinery without an owner decision.** No per-device
   cursors, no "did this device ack" trackers in phase 1. Routing is
   recomputed per utterance from the live registry — the same stateless
   stance RFC-0223 §2.6 takes for presence. A device-ack model is named as a
   non-goal (§5) pending evidence it is needed.

## §3 Model

```ocaml
(** Where a synthesized utterance is delivered. *)
type playback_destination = Browsers | Local

(** Resolved per utterance from the live registry. [Browsers] iff at least
    one SSE subscriber is connected for [keeper_name]; otherwise [Local].
    The operator's "connected device only" policy (§1.5) is this function. *)
val resolve_destination :
  keeper_name:string -> unit -> playback_destination
```

```ocaml
(** Audio descriptor attached to a [keeper_chat_appended] event when the
    utterance was synthesized. Optional on the wire for backward
    compatibility: old events have no audio fields and render as text-only. *)
type audio_clip = {
  url : string;              (* server-relative, e.g. "/api/v1/voice/audio/<name>" *)
  mime : string;             (* "audio/mpeg" today *)
  duration_sec : float option;
  message_text : string;     (* the utterance, for accessible fallback / captions *)
}
```

The HTTP audio endpoint serves a file from `$MASC_BASE_PATH/audio/` by a
stable, unguessable name (the current `<ts>_<agent>.mp3` is not unguessable;
P1 introduces a random token — see §4 P1). It is behind the same auth gate
as the rest of the dashboard API (`lib/server/server_auth.ml`,
`is_loopback_host` / `base_url_has_non_loopback_host` at lines 21-39), so a
non-loopback browser hitting the endpoint presents the same credentials the
dashboard already requires.

## §4 Changes, by phase (each independently shippable)

### P1 — Browser audio delivery (sound becomes reachable)

| Change | Site |
|---|---|
| Synthesized files get an unguessable name (`<token>.mp3`, token = ≥128-bit random) instead of `<ts>_<agent>.mp3`; `make_audio_file` updated | `voice_bridge_transport.ml:19-24` |
| **No lifecycle change needed.** Successful-utterance files are already retained (Openai/Elevenlabs branch has no `Sys.remove` on success exits); the existing `cleanup_old_audio_files` 1h TTL (`voice_bridge.ml:152-175`, called at `:641` and from heartbeat) is already the reaper and is already wide enough as a browser fetch window. `:384`/`:451` deletions (dedup / synthesis failure) stay — those files must not be served | `voice_bridge.ml` (no edit) |
| New HTTP route `GET /api/v1/voice/audio/:token` streams the file with `audio/mpeg`, behind the dashboard auth gate; 404 + reaped-log on miss | `lib/server/` (new route module, registered alongside `server_dashboard_http_keeper_api.ml`) |
| `keeper_chat_appended` payload gains optional `audio : { url, mime, duration_sec?, message_text }` when the utterance was synthesized; emitted in addition to the existing `local` playback when destination resolves to `Local` | `keeper_chat_broadcast.ml:6-31`, `server_routes_http_keeper_stream.ml:669/716` |
| Dashboard decodes the `audio` field once at the SSE edge into a typed record; the keeper chat panel renders an accessible audio element driven by a user gesture (play button) — never autoplay | `dashboard/src/sse-store.ts:547-561`, keeper chat panel component |

P1 notes:

- **Why unguessable names.** The endpoint is auth-gated, but the filename is
  also a capability: a logged-in operator on one keeper should not be able to
  enumerate another keeper's clips by guessing `<ts>_<agent>`. A 128-bit
  token closes enumeration without adding a per-clip ACL table.
- **Why a TTL, not "delete after browser acks".** A device-ack protocol is
  new standing machinery (§2.6 / §5). A TTL is the stateless reaper that
  already runs; reinterpreting its window as "long enough for a browser on a
  mobile network to fetch a few hundred KB of mp3" is the minimal honest
  change. The window default is derived from clip duration, not a magic
  number (cf. `playback_timeout_sec_for`, `voice_bridge_core.ml:200-203`).
- **Why user-gesture playback, not autoplay.** Mobile Safari/Chrome block
  unmuted autoplay without a user gesture even over HTTPS. The dashboard is
  reachable over HTTPS via the Cloudflare tunnel, so the gesture is the only
  remaining gate. A visible play button also serves as the accessible
  fallback (caption = `message_text`).

P1 shippable outcome: with at least one browser connected, a keeper
utterance is fetchable and playable in the browser. Local playback still
fires in parallel in P1 (parallel delivery is the temporary state; P2 makes
routing exclusive). This is acknowledged as an intermediate, not the target
shape — see the workaround self-check §7 for why it is acceptable as a
phase boundary.

### P2 — Device routing: "connected device only"

| Change | Site |
|---|---|
| `resolve_destination ~keeper_name` reads the SSE subscriber registry for subscribers connected for `keeper_name`; returns `Browsers` iff ≥1, else `Local` | new helper, sits alongside `lib/sse.ml` or in a thin `voice_destination` module |
| `agent_speak` resolves the destination before playback and suppresses `run_local_playback` when destination is `Browsers` | `voice_bridge.ml` (around the `run_local_playback` call site) |
| The `audio` field on `keeper_chat_appended` is emitted only to subscribers connected for `keeper_name` (the registry already supports prefix-scoped broadcast; the event already carries `keeper_name`) | `keeper_chat_broadcast.ml`, `lib/sse.ml` |
| `local_playback_enabled_for_agent` is reinterpreted as "is the `Local` destination ever allowed" rather than "always play locally"; when destination is `Browsers`, the agent-level flag is not consulted | `voice_config.mli:158`, `voice_bridge_core.ml:262` |

P2 open question for owner review (not blocking the RFC, but blocks the P2
PR): when destination is `Browsers`, should `Local` be fully suppressed, or
should `Local` still fire as a "the server room hears it too" convenience?
The operator's stated policy ("connected device only", §1.5) means fully
suppressed. This RFC encodes "fully suppressed" as the default and flags the
opposite as a config escape hatch only.

P2 shippable outcome: a connected mobile browser is the sole listener while
connected; the server speakers stay silent; disconnecting the browser
restores local playback on the next utterance without restart.

## §5 Non-goals / deferred

| Deferred | Why | Re-entry condition |
|---|---|---|
| Per-device delivery ack / "did this device play it" tracking | new standing machinery; TTL reaper covers the failure mode (browser never fetches → file reaped → text-only render remains correct) | evidence that the text-only fallback is insufficient, or that delivery confirmation is needed for a keeper decision |
| Streaming synthesis (chunked SSE audio) | ElevenLabs/OpenAI return whole files; chunking is a transport optimization for a latency budget that has not been measured | a measured latency budget showing whole-file fetch is too slow on the target network |
| Multi-utterance queue / precedence beyond the existing `priority` arg | `agent_speak` already takes `?priority`; a client-side queue is browser UX work, not transport | a concrete ordering failure report |
| STT (speech-to-text) browser input | out of scope; this RFC is output-only. `transcribe_audio` (`voice_bridge.ml`) is unchanged | separate RFC if bidirectional voice is wanted |
| Voice for non-dashboard surfaces (Discord voice, Slack) | surfaces are RFC-0223's domain; audio-over-Discord is a different transport with its own auth model | separate RFC |
| Digest / caption summarization | non-deterministic; needs its own evaluation harness (same rationale as RFC-0223 §5) | separate RFC with harness |

## §6 Validation

- Unit: `make_audio_file` token uniqueness/length; TTL reaper keeps files
  within the window and reaps outside it; `resolve_destination` returns
  `Browsers` for a keeper with a registered subscriber and `Local` without.
- SSE payload: round-trip an `keeper_chat_appended` event with and without
  the `audio` field; old-style event (no audio) decodes to a text-only
  render, new-style decodes with all four fields.
- Transport: HTTP audio endpoint returns 404 for an unknown token, 403 for
  an unauthenticated non-loopback request, and 200 `audio/mpeg` for a valid
  token while the file is within its TTL.
- Routing (P2): with a subscriber registered, `run_local_playback` is not
  called and the audio field is emitted; with no subscriber, `Local` fires
  and no audio field is emitted.
- Manual: on a mobile browser over the HTTPS tunnel, an utterance plays via
  the play button; the server speakers are silent while connected; killing
  the browser tab restores local playback on the next utterance.

## §7 Workaround self-check (CLAUDE.md signatures)

- **No telemetry-as-fix.** P1 adds a real transport (HTTP endpoint + SSE
  field + client playback). P2 changes real routing. Nothing merely counts
  a failure.
- **No string classifier added.** The audio descriptor is a typed record
  decoded once at the SSE boundary. The existing `source` label is reused
  unchanged.
- **No N-of-M.** P1 and P2 are vertical slices, each complete for its
  concern; P2 does not "finish what P1 half-did".
- **No cap/cooldown/dedup/repair smuggled in.** The pre-existing dedup
  (`is_dedup_hit`) and duration-probe machinery are untouched. The TTL
  reaper is a *redesign of the cleanup contract* (the file now has a
  legitimate second consumer, the browser), not a repair layered on
  immediate deletion. The P1 parallel-delivery state is a named phase
  boundary with an explicit P2 that removes it — it is not shipped as the
  target shape, and this RFC says so in §4 P1 and §4 P2.
- **No test backdoor.** `resolve_destination` reads the real registry; no
  `set_subscribers_for_test` escape hatch.
