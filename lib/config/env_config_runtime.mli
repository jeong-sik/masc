(** Env_config_runtime — runtime knobs grouped by subsystem.

    Surface flows through [include Env_config_runtime] in
    {!Env_config}, so callers reach values as
    [Env_config.<Module>.<field>].

    Most fields are module-level [let] bindings cached at process
    startup; the few [unit ->] thunks document re-readable values
    that operators may flip at runtime (feature flags via
    {!Feature_flag_registry}, optional env-vars). *)

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

(** {1 Tempo (polling interval)} *)

module Tempo : sig
  val default_interval_seconds : float
end

(** {1 Cache} *)

module Cache : sig
  val max_entry_size : int
  val max_entries : int
end

(** {1 Executor / Domain Pool} *)

module Executor : sig
  val domain_count_override : unit -> int option
  (** Optional override for the shared Eio executor domain count.

      Reads [MASC_EXECUTOR_DOMAIN_COUNT].  Unset, non-integer, zero, and
      negative values return [None], letting {!Domain_pool} choose its
      recommended count. *)
end

(** {1 Orchestrator} *)

module Orchestrator : sig
  val check_interval_seconds : float
  val agent_name : string
  val min_priority : int
  val enabled : bool
end

(** {1 Local runtime / llama.cpp} *)

module Local_runtime : sig
  val server_url : string
  val worker_model_opt : unit -> string option
end

module Ollama : sig
  val server_url : string
  val default_model : string
end

(** {1 Voice bridge} *)

module Voice : sig
  val default_host : string
  val default_port : int
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

(** {1 Worker / local runtime} *)

module Worker : sig
  val local_runtime_debug : bool
  val local_runtime_cooldown_sec_opt : unit -> string option
end

(** {1 AGENT_CORE SSE bridge} *)

module Agent_core_sse : sig
  val drain_interval_sec : float
end

(** {1 Lane failover} *)

module Lane : sig
  val preference_ttl_s : unit -> float
  (** Sticky lane-candidate preference TTL in seconds
      ([MASC_LANE_PREFERENCE_TTL_S], default [3600.0]).  Re-read per call so
      tests and operators can flip it without a restart; [0] disables
      stickiness. *)
end

(** {1 Dashboard signal thresholds + render budgets} *)

module Dashboard : sig
  val signal_stale_sec : float
  val signal_quiet_sec : float
  val signal_live_sec : float
  val keeper_action_stale_sec : float
  val ctx_handoff_imminent : float
  val ctx_preparing : float
  val ctx_high : float
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
  val stalled_session_threshold_sec : float
  val repo_sync_interval_sec : float
  val rate_limit_bucket_ttl_sec : int
end

(** {1 Sidecar reconcile loop} *)

module Sidecar : sig
  val reconcile_backoff_sec : float
  val control_command_timeout_sec : float
  val schema_generation_timeout_sec : float
end

(** {1 Workspace file endpoint limits} *)

module Workspace_file : sig
  val max_read_bytes : int
end
