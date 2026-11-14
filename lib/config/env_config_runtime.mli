(** Env_config_runtime — runtime knobs grouped by subsystem.

    Surface flows through [include Env_config_runtime] in
    {!Env_config}, so callers reach values as
    [Env_config.<Module>.<field>].

    Most fields are module-level [let] bindings cached at process
    startup; the few [unit ->] thunks document re-readable values
    that operators may flip at runtime (boolean env flags,
    optional env-vars). *)

(** {1 Session} *)

module Session : sig
  val max_age_seconds : float
  val sse_grace_period_seconds : float
end

(** {1 SSE reconnect guard} *)

module Sse_connect_guard : sig
  val reconnect_min_interval_seconds : float
  (** Minimum interval between SSE reconnects for one session.
      [<= 0.0] disables the per-session cooldown. *)

  val connect_window_seconds : float
  (** Sliding window over which reconnects are counted.
      [<= 0.0] disables the window limit. *)

  val connect_max_in_window : int
  (** Reconnects admitted inside one window. [<= 0] disables the window
      limit. *)

  (** Re-readable reads of the same three knobs.  The [float]/[int]
      bindings above are evaluated once at process start; these thunks
      read the environment at each call, so tests can pin the
      documented disable semantics ([<= 0], including negative
      values) without forking a process.  An operator flipping the
      env-var mid-flight is {e not} promised a hot reload — the
      transport still reads the cached bindings — only that the
      reader itself never clamps a negative to the default. *)
  module Re_read : sig
    val reconnect_min_interval_seconds : unit -> float
    val connect_window_seconds : unit -> float
    val connect_max_in_window : unit -> int
  end
end

(** {1 Executor / Domain Pool} *)

module Executor : sig
  val domain_count_override : unit -> int option
  (** Optional override for the shared Eio executor domain count.

      Reads [MASC_EXECUTOR_DOMAIN_COUNT].  Unset, non-integer, zero, and
      negative values return [None], letting {!Domain_pool} choose its
      recommended count. *)
end

(** {1 Ollama} *)

module Ollama : sig
  val server_url : string
  val default_model : string
end

(** {1 Voice bridge} *)

module Voice : sig
  val http_request_timeout_sec : float
  val audio_test_tone_timeout_sec : float
end

(** {1 Transport} *)

module Transport : sig
  type h2_mode =
    | Auto
    | H1_only
    | H2_only

  val h2_mode_of_string : string -> h2_mode
  val h2_mode_to_string : h2_mode -> string
  val configure_h2_from_env : unit -> h2_mode
  val effective_h2_mode : unit -> h2_mode
  val h2_snapshot_entry : Env_config_snapshot_collector.t

  val grpc_port : int
  val grpc_enabled : unit -> bool
  val grpc_target_opt : unit -> string option
  val ws_enabled : unit -> bool

  val https_port_default : int
  (** 8938. The WebSocket listener holds 8937. *)

  val https_port : unit -> int option
  (** The HTTPS listener port (TLS 1.3, ALPN [h2] and [http/1.1]), from
      [MASC_HTTPS_PORT] or TOML [transport.https_port]. [None] when the value
      is ["0"]: no HTTPS listener. A value that is not a port falls back to
      {!https_port_default}. *)

  val tls_cert_file : unit -> string option
  (** [MASC_TLS_CERT_FILE] or TOML [transport.tls_cert_file]: a PEM
      certificate chain for the HTTPS listener. Set together with
      {!tls_key_file}; unset, the server uses a self-signed pair under
      [<base-path>/.masc/tls/]. *)

  val tls_key_file : unit -> string option
  (** [MASC_TLS_KEY_FILE] or TOML [transport.tls_key_file]: the PEM private
      key that belongs to {!tls_cert_file}. *)

  val serving_domain_enabled : unit -> bool
  val http_auth_strict_env_enabled : unit -> bool
  val startup_watchdog_sec : unit -> float
end

(** {1 Board persistence} *)

module Board : sig
  val flush_interval_sec : float
  val flusher_inbox_capacity : int
end

(** {1 Tool surface} *)

module Tools : sig
  val list_page_size : unit -> int
  val web_search_provider_opt : unit -> string option
  val web_search_provider_order_opt : unit -> string option
  val web_search_fallbacks_opt : unit -> string option
  val web_search_timeout_sec : unit -> int
  val web_search_cache_ttl_sec : unit -> float

  val searxng_url_configured : string -> (string option, string) result
  (** What a [web_search.searxng_url] value names, without trailing slashes.
      Blank is unset, [Ok None]. A value that is not an http or https URL with
      a host, or that carries userinfo, is [Error], saying why without naming
      the setting. runtime.toml validation and {!searxng_base_url} both decide
      by this. *)

  val searxng_base_url : unit -> (string, string) result
  (** runtime.toml [web_search.searxng_url] or [MASC_SEARXNG_URL] without
      trailing slashes, or {!Masc_network_defaults.searxng_default_url} when
      unset or blank. [Error] names the setting and why its URL is refused. *)
end

(** {1 OpenTelemetry} *)

module Otel : sig
  val enabled : unit -> bool
  (** [MASC_OTEL_ENABLED], default {!Masc_network_defaults.otel_default_enabled}. *)
end

(** {1 Rate limit bucket} *)

module Rate_bucket : sig
  val rate : float
  val burst : int
  val agent_rate : float
  (** Per-agent requests per second ([MASC_AGENT_RATE_LIMIT], default [20.0]). *)
  val agent_burst : int
  (** Per-agent burst capacity ([MASC_AGENT_RATE_BURST], default [50]). *)
end

(** {1 AGENT_CORE SSE bridge} *)

module Agent_core_sse : sig
  val drain_interval_sec : float
end

(** {1 Dashboard signal thresholds + render budgets} *)

module Dashboard : sig
  val signal_stale_sec : float
  val signal_quiet_sec : float
  val signal_live_sec : float
  val keeper_action_stale_sec : float
  val shell_prewarm_inner_timeout_sec : float
  val shell_prewarm_outer_timeout_sec : float
  val execution_timeout_sec : float
  val execution_trust_timeout_sec : float
  val briefing_timeout_sec : float
  val shell_timeout_sec : float
  val shell_light_timeout_sec : float
  val render_timeout_sec : float
  val full_health_refresh_timeout_sec : float
  val full_health_critical_failure_threshold : int
end

(** {1 Internal timers / cache TTLs} *)

module InternalTimers : sig
  val label_quiet_threshold_sec : float
  val label_stuck_threshold_sec : float
  val briefing_cache_ttl_sec : float
  val sse_buffer_ttl_sec : float
  val repo_sync_interval_sec : float
  val rate_limit_bucket_ttl_sec : int
end

(** {1 Lane add-on process control} *)

module Sidecar : sig
  val control_command_timeout_sec : float
end

(** {1 Workspace file endpoint limits} *)

module Workspace_file : sig
  val max_read_bytes : int
end
