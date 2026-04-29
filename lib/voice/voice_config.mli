(** Voice_config — voice (TTS / STT / session) configuration
    loaded from \[<masc_dir>/voice_config.json\].

    Persistent file shape: nested record with [tts] / [stt] /
    [session] / [local_playback] sections.  Each section carries
    its own endpoint list keyed by [endpoint_kind].

    Internal: 30+ helpers stay private — JSON parsing
    ([trim_opt], [string_list_opt], [require_string], etc.),
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
  max_retries : int option;
}
(** Per-endpoint configuration.  [api_key_env] names the
    environment variable holding the credential (not the
    credential itself).  [base_url] / [mcp_url] / [health_url]
    are populated based on [kind]. *)

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
  local_playback : local_playback_config;
}
(** Complete voice configuration. *)

(** {1 Constants (cascade-visible)} *)

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
    local_playback). Pure — no filesystem access. Used by [load]
    after IO and by tests that exercise edge cases without a
    file. *)

val load : unit -> (t, string) result
(** [load ()] reads + parses the voice config from the first
    existing path in:

    + [\$MASC_BASE_PATH/.masc/voice_config.json] (when
      [MASC_BASE_PATH] is set).
    + Repository-local [voice_config.json] (test fixture).
    + Fallback path under
      [\$XDG_CONFIG_HOME/masc/voice_config.json].

    Returns [Error _] when no candidate exists or JSON parsing
    fails.  Pinned at the contract seam — operators see one of
    these 3 paths in the error message. *)

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
    [config.tts.default_voice]. *)

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
