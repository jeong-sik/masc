(** Voice_bridge_core — voice config, retry knobs, local playback,
    and TTS helper utilities shared by {!Voice_bridge}.

    Internal helpers ([log_prefix], [split_path_env],
    [find_executable_in_path], [local_playback_argv],
    [record_playback], the dedup [last_playback] state, the playback
    mutex, the [elevenlabs_voice_ids] constant table, [trim_opt],
    [resolved_base_path_opt], [strip_provider_metadata], and
    [provider_metadata_keys]) are hidden — callers consume the
    public configuration / URI / playback / metadata-projection
    surface plus the [log_*] helpers (used by {!Voice_bridge}'s
    higher-level handlers to keep tag prefixes consistent).

    @since voice extraction (issue cluster #voice-bridge-split). *)

(** {1 Retry knobs} *)

val default_timeout_seconds : float
val default_max_retries : int
val default_initial_backoff_seconds : float
val default_backoff_multiplier : float
val playback_dedup_window_sec : float

val request_timeout_seconds : unit -> float
val max_retries : unit -> int
val initial_backoff_seconds : unit -> float
val backoff_multiplier : unit -> float

(** {1 Voice config} *)

val load_voice_config : unit -> (Voice_config.t, string) result
(** Cached load of the voice configuration JSON. *)

val default_agent_voices : unit -> (string * string) list
(** [agent_id -> voice_id] pairs from the {!Provider_adapter}
    registry, used as a fallback when the JSON config is missing. *)

val agent_voices : unit -> (string * string) list
(** Effective [agent_id -> voice_id] pairs from the loaded config,
    falling back to {!default_agent_voices}. *)

val tuning_for_agent : string -> Voice_config.voice_tuning
(** Per-agent TTS tuning ([stability] / [similarity_boost] /
    [style]); falls back to the [Voice_config] defaults when the
    config fails to load. *)

val local_playback_enabled_for_agent : string -> bool
(** [true] iff the loaded config enables local audio playback for
    [agent_id]. *)

val get_voice_for_agent : string -> string
(** Resolve the [agent_id]'s voice via {!agent_voices}, defaulting
    to ["Sarah"] when no mapping is registered. *)

(** {1 URI / endpoint resolution} *)

val default_voice_uri : string -> Uri.t
(** Construct the default voice session URI rooted at the local
    runtime endpoint. *)

val voice_mcp_uri : unit -> Uri.t
(** MCP voice URL from the configured endpoint, falling back to
    [default_voice_uri "/mcp"] on any resolution failure. *)

val voice_health_uri : unit -> Uri.t
(** Health URL from the configured endpoint, falling back to
    [default_voice_uri "/health"]. *)

val voice_mcp_host : unit -> string
val voice_mcp_port : unit -> int

(** {1 HTTP client construction} *)

val client_for_uri :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  Uri.t ->
  (Cohttp_eio.Client.t, string) result

val client_for_uri_result :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  Uri.t ->
  (Cohttp_eio.Client.t, string) result
(** [client_for_uri] wrapped to convert exceptions into
    [Error msg]; cancellation re-raises. *)

(** {1 Local playback} *)

val is_dedup_hit : agent_id:string -> message:string -> bool
(** [true] iff [(agent_id, hash message)] matches the most recent
    playback within {!playback_dedup_window_sec}. Exposed so
    {!Voice_bridge} can short-circuit before the playback mutex is
    acquired (the mutex'd recheck inside {!run_local_playback} closes
    the residual check-then-act race). *)

val run_local_playback :
  sw:Eio.Switch.t ->
  agent_id:string ->
  ?message:string ->
  audio_file:string ->
  unit ->
  [ `Dedup_hit | `Played of float option ]
(** Mutex-protected local audio playback with a 30s dedup window
    keyed on [(agent_id, hash message)]. Returns:

    - [`Dedup_hit] — another fiber already played this same message
      recently (check happens inside the playback mutex to close the
      check-then-act race);
    - [`Played None] — playback was disabled, no executable available,
      or the player exited non-zero;
    - [`Played (Some duration_seconds)] — playback succeeded.

    When [message] is omitted the dedup re-check is skipped (legacy
    callers that do not propagate the message string). *)

val start_local_playback :
  sw:Eio.Switch.t -> agent_id:string -> audio_file:string -> unit
(** Fire-and-forget wrapper around {!run_local_playback}. *)

(** {1 Filesystem layout} *)

val masc_base_dir : unit -> string
(** [<base_path>/.masc/]. Resolves [base_path] from
    [Env_config_core.base_path_opt], falling back to the nearest git
    root walking up from CWD. *)

val ensure_audio_dir : unit -> unit
(** [mkdir -p <masc_base_dir>/audio]. *)

(** {1 Structured logging helpers} *)

val log_info : string -> unit
val log_error : string -> unit
val log_debug : string -> unit
(** Wrap [Log.info] / [Log.error] / [Log.debug] with the
    [\[VoiceBridge\]] tag prefix so call sites read uniformly. *)

(** {1 TTS payload projection} *)

val append_provider_metadata :
  Yojson.Safe.t -> Voice_config.endpoint -> Yojson.Safe.t
(** Drop provider-specific metadata fields ([provider_name] /
    [provider_kind] / [provider_family] / [provider_auth] /
    [endpoint_id] / [endpoint_url]) from a TTS response so the
    public voice APIs stay vendor-neutral. The [endpoint] argument
    is currently unused but kept in the signature for forward
    compatibility. *)
