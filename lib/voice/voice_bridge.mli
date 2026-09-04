(** Voice_bridge — TTS synthesis, speech-to-text, local playback.

    Re-exports [Voice_bridge_core] (config, helpers, local playback)
    and adds the higher-level [agent_speak] and transcription APIs.

    External callers use [agent_speak], [get_agent_voice],
    and [public_config_json]. *)

include module type of Voice_bridge_core

(** {1 Types} *)

(** How one Voice MCP call failed. *)
type mcp_call_error =
  | Timed_out of float
  | Connection_failed of string
  | Http_status of
      { code : int
      ; body : string
      }
  | Malformed_body of string

type effect_disposition =
  | Proven_pre_effect
  | Remote_effect_unresolved

val mcp_call_error_to_string : mcp_call_error -> string
val mcp_call_effect_disposition : mcp_call_error -> effect_disposition
(** Voice MCP failures do not prove that remote playback did not happen. *)

type agent_speak_completion =
  | Spoken
  | Dedup_skipped

type agent_speak_result =
  { completion : agent_speak_completion
  ; payload : Yojson.Safe.t
  }

(** {1 Public API} *)

val public_config_json : unit -> (Yojson.Safe.t, Yojson.Safe.t) result

val agent_speak :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  agent_id:string ->
  message:string ->
  ?provider:string ->
  ?priority:int ->
  ?audio_device:string ->
  unit ->
  (agent_speak_result, string) result
(** Synthesize [message] via the configured TTS endpoint chain and play it
    locally, blocking the calling fiber until playback finishes. Concurrent
    callers are serialized by the global playback mutex. Returns a typed
    [completion] and preserves the provider payload. TTS/endpoint failures or
    an invalid provider completion payload return [Error] so the caller — and
    the LLM driving it — sees the failure instead of a fake success.

    Config-state semantics (no silent fallback): an explicit but broken
    voice config surfaces its load error; when no voice config exists at
    all, TTS is reported as explicitly disabled ([Error
    "no configured TTS endpoint"]) instead of substituting a hardcoded
    model name.

    This is the only speak path: the former fire-and-forget
    [enqueue_agent_speak] queue was removed after the 2026-06-10 voice
    repeat incident (schema promised blocking semantics while the
    implementation returned [status="queued"] immediately, so keepers
    re-spoke the same content every sub-turn). *)

val get_agent_voice :
  agent_id:string -> (Yojson.Safe.t, string) result

(** {1 Speech-to-Text} *)

val transcribe_audio :
  audio_file:string ->
  ?language_code:string ->
  unit ->
  (Yojson.Safe.t, string) result
(** Transcribe [audio_file] through the enabled STT endpoint chain.
    A broken explicit voice config surfaces its load error; when no
    voice config exists, STT is reported as explicitly disabled
    ([Error "no enabled STT endpoints configured"]).  If every enabled
    endpoint fails, the returned error names each attempted endpoint
    and its failure. *)

(** {1 Microphone capture thresholds} *)

(** The room is measured at each capture rather than assumed. Measured on one
    workstation 2026-09-03, the noise floor sat at -37.2 dB on one pass and
    -26.3 dB on another minutes later — 10 dB apart in one room, against a
    threshold that was then a fixed 1% of full scale. Every capture ran to its
    timeout and handed the transcriber a room. *)

val trigger_margin_db : float
(** How far above the room a sound must rise for the capture to treat it as
    speech having started, read as RMS on both sides.

    It was a peak margin until 2026-09-04, because the threshold was handed to
    sox's silence filter and that filter reads peak. Peak turned out to be an
    unstable basis: on one workstation it moved 1.9x across five probes of the
    same idle room a minute apart, while RMS moved 1.2x. The capture now makes
    this decision itself, so the margin, the gate below, and the level the
    meter draws are one number. *)

val speech_margin_db : float
(** How far the room has to fall back below a speaker for the capture to count
    as over, read as RMS.

    This is also what keeps a room away from the transcriber, because whisper
    answers silence with a sentence: three captures of an empty room returned
    "감사합니다.", "감사합니다." and "네". Byte size cannot separate those from
    speech, since a capture that ran to its timeout on room tone is large.
    Once audio reaches the endpoint chain a hallucinated transcript is
    indistinguishable from a real one, so the refusal has to happen before
    that. A capture in which no reading ever cleared {!trigger_margin_db} is
    never sent. *)

val db_of_amplitude : float -> float
(** dBFS for a linear RMS amplitude; [neg_infinity] at zero. *)

val amplitude_of_db : float -> float
(** The inverse, with [neg_infinity] mapping back to zero. *)

(** {1 Microphone record + transcribe} *)

val measure_noise_floor : ?seconds:float -> agent_id:string -> unit -> float option
(** One short capture, returning the room's RMS amplitude. [None] when the
    recorder could not run.

    Exposed for a caller that captures repeatedly: the room does not change
    between two utterances the way it changes across a session, and re-probing
    costs about 1.15 s of the gap between them. *)

(** How far a capture has got. Exposed so the decision that ends a recording
    can be checked against a table of levels rather than a microphone. *)
type level_phase =
  | Calibrating of { until : float; floor : float option }
  | Listening of { floor : float }
  | Speaking of { floor : float; quiet_since : float option }

type capture_end =
  | Ended_after_speech
  | Ended_without_speech
  | Ended_by_operator

type level_step =
  | Continue of level_phase
  | Finish of capture_end

val advance_phase :
  capture:Voice_config.capture_config ->
  now:float ->
  level:float option ->
  level_phase ->
  level_step
(** What one level reading does to a capture in progress.

    [level] is a linear RMS amplitude, or [None] when the recorder has not
    written anything to measure yet — the state every capture starts in, since
    the file is created before the first sample reaches it.

    Every threshold the capture applies is here. The loop around it supplies
    the clock and the file and nothing else. *)

val end_at_deadline : level_phase -> capture_end
(** What running out of time means, which depends on what was heard. A capture
    cut off mid-sentence still carries speech; one that never rose above the
    room is a recording of a room, and must not be transcribed. *)

val record_and_transcribe :
  agent_id:string ->
  ?timeout_sec:float ->
  ?language_code:string ->
  ?noise_floor:float ->
  ?on_level:(float -> unit) ->
  ?should_stop:(unit -> bool) ->
  unit ->
  (Yojson.Safe.t, string) result
(** Record from the microphone (with beep tones) and transcribe via STT.

    Where the recording ends is decided here rather than by sox: the level is
    re-read ten times a second while the file is being written, speech starts
    when it clears the room by {!Voice_config.trigger_margin_db}, and the
    recording stops once the room has been quiet again for
    {!Voice_config.trailing_silence_seconds}.

    [on_level] receives each of those readings in dBFS, so a caller can draw
    the same number the decision is made from. It receives
    [Float.neg_infinity] while there is no audio to measure and once more when
    the capture ends.

    [should_stop] is polled at the same rate; returning [true] ends the
    recording and yields no transcript.

    [noise_floor] reuses an RMS level already measured, skipping calibration.
    Omitted, the room is read from the capture's own opening.

    Returns transcription JSON on success, or a [no_audio] status when nothing
    rose above the room — a recording of a room must not reach the endpoint,
    which answers it with a fluent sentence. *)
