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
    model name. A config that loads but has no [tts] section is refused
    here too, before any endpoint is asked: there is no model to send, and
    the empty string that used to stand in for one reached providers as
    [model_id ""].

    This is the only speak path: the former fire-and-forget
    [enqueue_agent_speak] queue was removed after the 2026-06-10 voice
    repeat incident (schema promised blocking semantics while the
    implementation returned [status="queued"] immediately, so keepers
    re-spoke the same content every sub-turn). *)

val get_agent_voice :
  agent_id:string -> (Yojson.Safe.t, string) result

(** {1 Speech-to-Text} *)

(** The [status] field of every capture result this module returns, as a
    closed set. {!record_and_transcribe} and {!transcribe_audio} write it;
    {!capture_outcome_of_json} reads it back. A reader that matches on the
    string instead falls through whatever it does not know into "nothing was
    heard", which is how a discarded sentence was reported as a dead
    microphone. *)
type capture_status =
  | Transcribed
  | No_audio
  | Discarded

val capture_status_to_string : capture_status -> string
val capture_status_of_string : string -> capture_status option

val transcribe_audio :
  audio_file:string ->
  ?language_code:string ->
  unit ->
  (Yojson.Safe.t, string) result
(** Transcribe [audio_file] through the enabled STT endpoint chain.
    A broken explicit voice config surfaces its load error; when no
    voice config exists, STT is reported as explicitly disabled
    ([Error "no enabled STT endpoints configured"]), and a config with
    no [stt] section is refused by name before any endpoint is asked.
    If every enabled endpoint fails, the returned error names each
    attempted endpoint and its failure. *)

(** {1 Microphone capture thresholds}

    The margins a capture decides by are {!Voice_config.capture_config},
    read from [\[voice.capture\]] at each capture, with the measured defaults
    in {!Voice_config.default_capture}. They are not duplicated here: a copy
    of {!Voice_config.trigger_margin_db} exported from this module went on
    describing it as a peak margin after the capture had moved to RMS. *)

val db_of_amplitude : float -> float
(** dBFS for a linear RMS amplitude; [neg_infinity] at zero. *)

val amplitude_of_db : float -> float
(** The inverse, with [neg_infinity] mapping back to zero. *)

(** {1 Microphone record + transcribe} *)

val measure_noise_floor : agent_id:string -> unit -> float option
(** One short capture, as long as the configured
    {!Voice_config.calibration_seconds}, returning the room's RMS amplitude.
    [None] when the recorder could not run, or when the voice config exists
    and does not parse -- the capture that follows refuses with that reason.

    Exposed for a caller that captures repeatedly: the room does not change
    between two utterances the way it changes across a session, and re-probing
    costs about 1.15 s of the gap between them. *)

(** How far a capture has got. Exposed so the decision that ends a recording
    can be checked against a table of levels rather than a microphone. *)
type level_phase =
  | Calibrating of { until : float; floor : float option }
  | Listening of { floor : float }
  | Speaking of { floor : float; quiet_since : float option }

(** What the operator asked for when they ended a recording early. One variant
    rather than two flags: a stop and a discard cannot both be requested, and a
    pair of booleans would let them be. *)
type stop_request =
  | Keep_what_was_heard
  | Discard

(** Why a recording ended. What happens to it turns on whether speech was
    heard and on whether the operator said they do not want it. A capture
    stopped mid-sentence by the stop key, and one that ran out of time
    mid-sentence, both carry a sentence and are transcribed. *)
type capture_end =
  | Ended_after_speech
  | Ended_without_speech of float option
      (** The capture ran to its deadline and no reading ever cleared the
          room. Carries the room level the capture settled on, as a linear
          RMS amplitude, or [None] when the recorder never produced a sample
          to measure.

          It is carried because an empty draft is the same sight whether the
          microphone heard nothing, the room sat above the threshold, or the
          transcriber failed. The two levels separate those: "room -38.2 dB,
          speech had to clear -32.2 dB" is a thing to act on. *)
  | Stopped_before_speech of float option
      (** Either key, pressed before anything was said. Nothing waited for
          speech, so this is not a silence verdict on the microphone; it
          carries the room the same way for the same reason. *)
  | Discarded_after_speech of float
      (** The discard key, pressed after speech was heard. The sentence is
          thrown away on purpose and the operator is told that, not that
          nothing was heard: the microphone worked. The floor is always known
          here because speech was heard, so calibration had finished. *)

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
val with_noise_reduced_audio :
  audio_file:string -> f:(string -> 'a) -> 'a
(** Run [f] on a noise-reduced copy of [audio_file], removing the copy and
    the profile when [f] returns — whatever it returns, and when it raises.
    When sox cannot produce the copy, [f] runs on [audio_file] itself: the
    caller transcribes what it already had rather than nothing.

    Exposed because its scope-ownership is the regression contract: the
    [noise_reduced_copy] it replaced handed the reduced file to its caller,
    and nobody removed it — every noise-reduced capture left a
    masc_nr_*.wav behind forever. *)

val end_at_operator_stop : stop_request -> level_phase -> capture_end
(** The same question asked of a stop.

    [Keep_what_was_heard] mid-sentence is "send what I said", which is usually
    why the key is pressed -- the alternative is waiting out
    {!Voice_config.trailing_silence_seconds}. Before any speech it is
    [Stopped_before_speech].

    [Discard] is an abort whatever was heard. It is the only place in the
    capture path where the operator says what they want rather than the levels
    inferring it. Mid-sentence it is [Discarded_after_speech], so the report
    says a sentence was thrown away; before any speech it is the same
    [Stopped_before_speech] as the other key. *)

val record_and_transcribe :
  agent_id:string ->
  ?timeout_sec:float ->
  ?language_code:string ->
  ?noise_floor:float ->
  ?on_level:(float -> unit) ->
  ?should_stop:(unit -> stop_request option) ->
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

    [should_stop] is polled at the same rate. [Keep_what_was_heard] ends the
    recording and still transcribes what was said -- the usual reason to stop
    a capture is that the speaker has finished and does not want to wait out
    {!Voice_config.trailing_silence_seconds}. [Discard] throws the recording
    away and, when speech had been heard, says so with the [discarded]
    status. Either one before any speech yields [no_audio], which is what
    keeps a room away from a transcriber that answers silence with a sentence.

    [noise_floor] reuses an RMS level already measured, skipping calibration.
    Omitted, the room is read from the capture's own opening.

    The thresholds come from [\[voice.capture\]], read at each call. No
    config at all is the measured defaults. A config that exists and does not
    parse is refused with its reason before a tone is played or a microphone
    opened; it does not capture on defaults the operator did not set.

    Returns transcription JSON on success, or a [no_audio] status when nothing
    rose above the room — a recording of a room must not reach the endpoint,
    which answers it with a fluent sentence — or [discarded]. The [status]
    field is one of {!capture_status}; read it with
    {!capture_outcome_of_json}. *)

(** The result of {!record_and_transcribe} read back as what it is. The JSON
    stays the wire shape for the keeper tool; this is for a caller that has
    to act on it. *)
type capture_outcome =
  | Transcript of
      { text : string
      ; endpoint_id : string option
      }
  | Transcriber_returned_nothing of { endpoint_id : string option }
      (** The endpoint answered and its answer was empty. Not a silence: the
          capture heard speech and sent it, and the transcriber is the thing
          to look at. *)
  | Nothing_heard of { message : string }
      (** A [no_audio] result; the message carries the room level and the
          level speech had to clear, when they were measured. *)
  | Discarded_recording of { message : string }
  | Unrecognized_status of string
      (** A status neither side of this module knows. Reported rather than
          folded into any of the above. *)

val capture_outcome_of_json : Yojson.Safe.t -> capture_outcome
