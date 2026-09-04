(** Voice_config — voice (TTS / STT / session) configuration
    loaded from \[<masc_dir>/voice_config.json\].

    Persistent file shape: nested record with [tts] / [stt] /
    [session] / [local_playback] sections.  Each section carries
    its own endpoint list keyed by [endpoint_kind].

    Internal: the parsing helpers stay private — JSON parsing
    ([trim_nonempty_json], [require_string], etc.),
    path resolution helpers, voice-tuning extractors, and the
    \[default_*_*\] string constants for missing fields.  All
    consumed only inside {!load}'s parsing pipeline. *)

(** {1 Endpoint kind} *)

type endpoint_kind =
  | Openai_compat
  | Elevenlabs_direct
  | Voice_mcp

val string_of_endpoint_kind : endpoint_kind -> string
(** [string_of_endpoint_kind k] returns the canonical lowercase
    label: ["openai_compat"] / ["elevenlabs_direct"] /
    ["voice_mcp"].  Used by config matchers and provider routing. *)

(** {1 Endpoint record} *)

type endpoint = {
  id : string;
  kind : endpoint_kind;
  base_url : string option;
  mcp_url : string option;
  health_url : string option;
  api_key_env : string option;
  enabled : bool;
  timeout_seconds : float option;
  default_voice : string option;
}
(** Per-endpoint configuration.  [api_key_env] names the
    environment variable holding the credential (not the
    credential itself).  [base_url] / [mcp_url] / [health_url]
    are populated based on [kind].

    [default_voice] is the voice name this endpoint answers to. A voice id is
    provider-specific vocabulary -- an ElevenLabs [voice_id] is 20-64
    alphanumerics, an OpenAI voice is a name like ["alloy"] -- so the fallback
    chain handing one endpoint's id to the next endpoint asks for a voice that
    does not exist there (#24068). [None] means the endpoint has none declared
    and falls back to [tts.default_voice]. *)

(** {1 Voice tuning} *)

type voice_tuning = {
  stability : float;
  similarity_boost : float;
  style : float;
}
(** ElevenLabs-style voice tuning parameters.  All in [\[0.0, 1.0\]]. *)

(** {1 TTS / STT / session config} *)

type tts_config = {
  default_model : string;
  default_voice : string;
  default_voice_settings : voice_tuning;
  agent_voices : (string * string) list;
      (** [(agent_id, voice_id)] override map. *)
  agent_voice_settings : (string * voice_tuning) list;
      (** [(agent_id, tuning)] override map — falls back to
          [default_voice_settings] when missing. *)
  endpoints : endpoint list;
}

type stt_config = {
  default_model : string;
  endpoints : endpoint list;
}

type session_config = { endpoints : endpoint list }

type capture_config = {
  calibration_seconds : float;
      (** How long the room is measured before recording. Longer is steadier
          against a passing noise; shorter is less delay between the key and
          the tone. Must be greater than zero — a probe of no length measures
          nothing, and the threshold would come from an empty file. *)
  trigger_margin_db : float;
      (** How far above the room a sound must rise for the capture to count as
          speech having started. Raise it when captures begin on their own and
          never end; lower it when speaking does not start one.

          Read as RMS, the same as {!speech_margin_db} and the same as the
          level the meter draws, so what an operator watches and what the
          decision uses are one number. They were two until 2026-09-04: this
          margin was applied to a peak because it was handed to sox's silence
          filter, which reads peak. Peak on room tone moved 1.9x across five
          probes a minute apart while RMS moved 1.2x, so the threshold derived
          from it wandered on a room that had not changed. *)
  trailing_silence_seconds : float;
      (** How long the room has to stay quiet after speech before the capture
          stops. Long enough to sit through the pause inside a sentence, short
          enough that an operator is not waiting on their own recording.

          Must be greater than zero: a capture that stops the instant a
          speaker draws breath cuts the sentence in half. *)
  speech_margin_db : float;
      (** How far a whole capture must average above the room, read as RMS on
          both sides, to be transcribed at all. Lower it and whisper starts
          answering silence with a sentence: three captures of an empty room
          returned "감사합니다.", "감사합니다." and "네".

          Not comparable to {!trigger_margin_db}, which is a peak margin. *)
  noise_reduction : bool;
      (** Subtract the room's profile from a capture before transcribing.
          Measured on one sample it removed the floor entirely while keeping
          81% of the speech, and corrected one word.

          Off by default, on a small sample and because it cuts both ways:
          applied to a capture with no speech it hands whisper a perfect
          silence, which is what it hallucinates hardest against. It runs only
          after {!speech_margin_db} has admitted the capture. *)
}

type local_playback_config = {
  enabled : bool;
  agents : string list;
      (** Allow-list of agent ids permitted to play locally.
          Empty list = all agents permitted (when [enabled = true]). *)
}

(** {1 Composite config} *)

type t = {
  tts : tts_config;
  stt : stt_config;
  session : session_config;
  capture : capture_config;
  local_playback : local_playback_config;
}
(** Complete voice configuration. *)

(** {1 Constants (runtime-visible)} *)

val default_capture : capture_config
(** The values used when [\[voice.capture\]] is absent. Every one was measured
    on a single workstation, which is the reason the section exists: two
    earlier margins chosen from one room were both wrong, and an operator
    whose captures never start needs a knob rather than a release. *)

val default_elevenlabs_base_url : string
(** [https://api.elevenlabs.io/v1] — pinned as a fallback when
    the [Elevenlabs_direct] endpoint omits [base_url].
    Operator-visible so callers can assert / log the resolved
    URL without re-deriving the default. *)

(** {1 Path resolution} *)

val config_path : unit -> string
(** [config_path ()] returns the resolved config file path —
    first existing candidate from
    [base_path_voice_config_path_opt] / repo path / fallback,
    or the last fallback when none exist (for error messages). *)

(** {1 Loading} *)

val parse_json : Yojson.Safe.t -> (t, string) result
(** [parse_json json] parses an in-memory JSON value into a [t].
    Composes the per-section parsers (tts, stt, session,
    local_playback). Pure — no filesystem access. Used by [load_detailed]
    after IO and by tests that exercise edge cases without a
    file. *)

(** {1 Typed load status} *)

type load_error =
  | Not_configured
      (** No [\[voice\]] section in runtime.toml and no
          [voice_config.json] candidate exists: voice is simply not
          set up in this environment.  Callers treat this as
          "voice disabled", not as a failure. *)
  | Invalid of string
      (** A voice config source exists but could not be read or
          parsed; the string names the source and the reason.
          Callers must surface this to the operator instead of
          substituting defaults. *)

val load_detailed : unit -> (t, load_error) result
(** [load_detailed ()] distinguishes "voice is not configured"
    ({!Not_configured}) from "an explicit config exists but is
    broken" ({!Invalid}). *)

val load_error_to_string : load_error -> string
(** Render a typed load error at an operator-facing boundary. *)

(** {1 Endpoint selection} *)

val select_endpoint :
  ?endpoint_id:string -> endpoint list -> endpoint option
(** [select_endpoint ?endpoint_id endpoints] picks an endpoint:

    - When [endpoint_id = Some id] (non-empty after trim):
      matches [endpoint.id = id] OR
      [string_of_endpoint_kind endpoint.kind = id].
    - When [endpoint_id = None] or empty: returns the first
      enabled endpoint.

    Disabled endpoints ([enabled = false]) are filtered out
    before lookup. *)

(** {1 Per-agent helpers} *)

val voice_for_agent : t -> string -> string
(** [voice_for_agent config agent_id] returns the agent-specific
    voice id when present in [config.tts.agent_voices], else
    [config.tts.default_voice]. This is the workspace-wide answer; a caller
    speaking through a specific endpoint wants {!voice_for_agent_at_endpoint}. *)

val voice_for_agent_at_endpoint : t -> endpoint -> string -> string
(** The voice to ask [endpoint] for on [agent_id]'s behalf: the endpoint's own
    [default_voice] when it declares one, otherwise {!voice_for_agent}. The
    fallback chain resolves this per endpoint rather than once, so switching
    endpoints does not carry the previous provider's voice vocabulary along. *)

val tuning_for_agent : t -> string -> voice_tuning
(** [tuning_for_agent config agent_id] returns the
    agent-specific tuning when present in
    [config.tts.agent_voice_settings], else
    [config.tts.default_voice_settings]. *)

val local_playback_enabled_for_agent : t -> string -> bool
(** [local_playback_enabled_for_agent config agent_id] is true iff:

    + [config.local_playback.enabled] is [true], AND
    + [config.local_playback.agents] is empty (allow-all) OR
      contains [agent_id]. *)

val available_voices : t -> string list
(** [available_voices config] returns the [default_voice] followed
    by all per-agent voice overrides — used by the voice-bridge
    health endpoint to advertise the configured voice set. *)

(** {1 Public JSON} *)

val public_json : t -> Yojson.Safe.t
(** [public_json config] renders the config as JSON suitable for
    operator-visible endpoints.  API key env-var names are
    redacted (only the env-var name is exposed, never the value).
    Pinned at the contract seam — drift could leak credentials
    via the public diagnostics surface. *)
