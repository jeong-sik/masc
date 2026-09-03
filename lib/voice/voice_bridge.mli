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

(** The room is measured at each capture rather than assumed. The recording
    threshold was a literal 1% of full scale (about -40 dBFS); measured on one
    workstation 2026-09-03 the noise floor sat at -37.2 dB on one pass and
    -26.3 dB on another minutes later, both above it. The silence filter then
    saw sound continuously, so every capture ran to its timeout and handed the
    transcriber a room. A floor that moves 10 dB between passes in one room is
    why this is read per capture. *)

val trigger_margin_db : float
(** How far above the measured floor a capture must rise to start recording.
    Speech sat 5.0 dB and 6.1 dB above the floor on the two measured passes --
    an ordinary sentence at a built-in microphone -- so a margin near that
    separation would swallow the utterance. *)

val speech_margin_db : float
(** How far above the floor a whole capture must average to be transcribed at
    all. Below {!trigger_margin_db}, so a capture that did start but carries
    only room tone is still refused.

    This exists because whisper answers silence with a sentence: three captures
    of an empty room returned "감사합니다.", "감사합니다." and "네". Byte size
    cannot separate those from speech, since a capture that ran to its timeout
    on room tone is large. Once audio reaches the endpoint chain a hallucinated
    transcript is indistinguishable from a real one, so the refusal has to
    happen here. *)

val rms_amplitude_of_file : string -> float option
(** Linear RMS amplitude of an audio file, read through [sox stat].
    [None] when sox does not run or its output carries no level line.

    Safe to call on a file still being written: sox reports the level of what
    is there. That is what a level meter reads, because opening a second
    capture device costs about 2.5 s — longer than most utterances — while the
    recording in progress is already a continuous record of what the
    microphone hears. *)

val db_of_amplitude : float -> float
(** dBFS for a linear RMS amplitude; [neg_infinity] at zero. *)

val amplitude_of_db : float -> float
(** The inverse, with [neg_infinity] mapping back to zero. *)

(** {1 Microphone record + transcribe} *)

val record_and_transcribe :
  agent_id:string ->
  ?timeout_sec:float ->
  ?language_code:string ->
  unit ->
  (Yojson.Safe.t, string) result
(** Record from microphone (with beep tones), transcribe via STT.
    Returns transcription JSON on success. *)
