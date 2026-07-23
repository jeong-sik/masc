(** Voice_bridge — TTS synthesis, speech-to-text, local playback.

    Re-exports [Voice_bridge_core] (config, helpers, local playback)
    and adds the higher-level [agent_speak] and transcription APIs.

    External callers use [agent_speak], [get_agent_voice],
    and [public_config_json]. *)

include module type of Voice_bridge_core

(** {1 Types} *)

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

(** {1 Microphone record + transcribe} *)

val record_and_transcribe :
  agent_id:string ->
  ?timeout_sec:float ->
  ?language_code:string ->
  unit ->
  (Yojson.Safe.t, string) result
(** Record from microphone (with beep tones), transcribe via STT.
    Returns transcription JSON on success. *)
