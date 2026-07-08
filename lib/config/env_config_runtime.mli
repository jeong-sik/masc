(** Env_config_runtime — runtime knobs grouped by subsystem.

    Surface flows through [include Env_config_runtime] in
    {!Env_config}, so callers reach values as
    [Env_config.<Module>.<field>] (e.g.
    [Env_config.Zombie.threshold_seconds]).

    Most fields are module-level [let] bindings cached at process
    startup; the few [unit ->] thunks document re-readable values
    that operators may flip at runtime (feature flags via
    {!Feature_flag_registry}, optional env-vars). *)

(** {1 Zombie detection / cleanup} *)

module Zombie : sig
  val threshold_seconds : float
  val keeper_threshold_seconds : float
  val cleanup_interval_seconds : float
end

(** {1 Lock} *)

module Lock : sig
  val timeout_seconds : float
  val expiry_warning_seconds : float
end

(** {1 Session} *)

module Session : sig
  val max_age_seconds : float
  val rate_limit_window_seconds : float
  val sse_grace_period_seconds : float
end

(** {1 Tempo (polling interval)} *)

module Tempo : sig
  val min_interval_seconds : float
  val max_interval_seconds : float
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

(** {1 Task claim} *)

module Claim : sig
  val ttl_seconds : float
end

(** {1 Orchestrator} *)

module Orchestrator : sig
  val check_interval_seconds : float
  val agent_name : string
  val min_priority : int
  val timeout_seconds : int
  val enabled : bool
end

(** {1 Local runtime / llama.cpp} *)

module Local_runtime : sig
  val server_url : string
  val worker_model_opt : unit -> string option
  val mcp_url : unit -> string
end

module Ollama : sig
  val server_url : string
  val default_model : string
end

(** {1 Cancellation tokens} *)

module Cancellation : sig
  val token_max_age_seconds : float
end

(** {1 Voice bridge} *)

module Voice : sig
  val default_host : string
  val default_port : int
  val http_request_timeout_sec : float
  val audio_test_tone_timeout_sec : float
end

(** {1 Message GC} *)

module Message : sig
  val max_count : int
end

(** {1 Transport} *)

module Transport : sig
  type h2_mode =
    | Auto
    | H1_only
    | H2_only
    | Unknown_h2_mode of string

  val normalize_token : string -> string
  val h2_mode_of_string : string -> h2_mode
  val h2_mode_to_string : h2_mode -> string

  type agent_transport =
    | Http
    | Grpc
    | Ws
    | Webrtc
    | Local
    | Unknown_agent_transport of string

  val agent_transport_of_string : string -> agent_transport
  val agent_transport_to_string : agent_transport -> string

  val grpc_port : int
  val grpc_enabled : unit -> bool
  val grpc_target_opt : unit -> string option
  val ws_port : int
  val ws_enabled : unit -> bool
  val webrtc_enabled : unit -> bool
  val use_h2 : unit -> h2_mode
  val agent_transport_opt : unit -> agent_transport option
  val http_auth_strict_env_enabled : unit -> bool
  val startup_watchdog_sec : unit -> float
end

(** {1 Verification FSM} *)

module Verification : sig
  val fsm_enabled : unit -> bool
  val timeout_deadline_seconds : unit -> float
  val timeout_check_interval_seconds : float
end

(** {1 Approval janitor} *)

module Approval_janitor : sig
  val enabled : unit -> bool
  val interval_seconds : float
end

(** {1 Keeper stale-run window (RFC-0250)} *)

module Keeper_stale_run : sig
  val threshold_sec_opt : unit -> float option
  (** [threshold_sec_opt ()] returns the stale-run wall-clock threshold
      when [MASC_KEEPER_STALE_RUN_SEC] is positive, or [None] when unset /
      zero / negative.

      Keys on [last_turn_ts] while [current_turn_observation = None],
      producing [Idle_turn] — the no-turn-produced case. Default-on at
      [1800.0] (30 min). *)
end

(** {1 Keeper mid-turn progress watchdog (RFC-0012)} *)

module Keeper_mid_turn_progress : sig
  val timeout_sec_opt : unit -> float option
  (** [timeout_sec_opt ()] returns the in-turn progress-silence threshold
      when [MASC_KEEPER_MID_TURN_PROGRESS_TIMEOUT_SEC] is positive, or [None]
      when unset / zero / negative.

      Distinct from [Keeper_stale_run] (no-turn, [Idle_turn]): keys on
      [current_turn_observation.last_progress_at] while a turn is running,
      producing [Mid_turn_no_progress] when no progress event has been recorded
      for longer than the threshold.

      Opt-in ([None] default): progress is stamped only on tool/sdk-boundary
      events, so a default-on window could false-fire on a long single-attempt
      thinking turn. RFC-0012 recommends [300.0] when enabling. *)
end

(** {1 Slot scheduling} *)

module Slot : sig
  val yield_enabled : unit -> bool
end

(** {1 Board persistence} *)

module Board : sig
  type backend =
    | Jsonl
    | Pg
    | Unknown_backend of string

  val backend_of_string : string -> backend
  val backend_to_string : backend -> string
  val flush_interval_sec : float
  val flusher_inbox_capacity : int
  val backend_opt : unit -> backend option
end

(** {1 Procedural memory crystallization} *)

module ProcMemory : sig
  val min_evidence : int
  val min_confidence : float
end

(** {1 Pulse} *)

module Pulse_config : sig
  val max_consumer_failures : int
end

(** {1 Tool surface} *)

module Tools : sig
  (* RFC-0084 host-config-cleanup-J — [val dispatch_v2_enabled : bool]
     removed alongside the [MASC_DISPATCH_V2] feature flag. *)
  val full_surface_enabled : unit -> bool
  val list_page_size : unit -> int
  val readonly_retry_limit : int
  val public_tools_extra_opt : unit -> string option
  val web_search_provider_opt : unit -> string option
  val web_search_provider_order_opt : unit -> string option
  val web_search_fallbacks_opt : unit -> string option
  val web_search_timeout_sec : unit -> int
  val web_search_cache_ttl_sec : unit -> float
  val web_search_rate_limit_window_sec : unit -> float
  val web_search_rate_limit_max_calls : unit -> int
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
  val local_worker_max_tokens : int
  val local_worker_heartbeat_sec : int
end

(** {1 OAS SSE bridge} *)

module Oas_sse : sig
  val drain_interval_sec : float
end

(** {1 Smart heartbeat tuning} *)

module SmartHeartbeatTuning : sig
  val base_interval_s : float
  val idle_multiplier : float
  val idle_threshold_s : float
end

(** {1 Dashboard signal thresholds + render budgets} *)

module Dashboard : sig
  val signal_stale_sec : float
  val signal_quiet_sec : float
  val signal_live_sec : float
  val keeper_action_stale_sec : float
  val ctx_handoff_imminent : float
  val ctx_preparing : float
  val ctx_compacting : float
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
  val metrics_flush_sec : float
  val label_quiet_threshold_sec : float
  val label_stuck_threshold_sec : float
  val briefing_cache_ttl_sec : float
  val bootstrap_window_sec : float
  val sse_buffer_ttl_sec : float
  val stalled_session_threshold_sec : float
  val janitor_interval_sec : float
  val repo_sync_interval_sec : float
  val rate_limit_bucket_ttl_sec : int
end

(** {1 Sidecar reconcile loop} *)

module Sidecar : sig
  val reconcile_backoff_sec : float
  val control_command_timeout_sec : float
  val schema_generation_timeout_sec : float
end

(** {1 Workspace local git operation timeouts} *)

module Workspace_git : sig
  val local_op_timeout_sec : float
end

(** {1 Workspace file endpoint limits} *)

module Workspace_file : sig
  val max_read_bytes : int
end

(** {1 Shell IR approval policy gate (RFC v5)} *)

module Shell_ir_approval_gate : sig
  val enabled : unit -> bool
  (** [enabled ()] is true when [MASC_SHELL_IR_APPROVAL_GATE_ENABLED] is set.
      Routes Execute tool calls through the capability-based approval policy
      gate so safe commands can be auto-allowed while audited/privileged
      operations require explicit approval. Default: [true] (the autonomous
      policy is a strict safety improvement over the no-gate path). *)
end

(** {1 Shell IR approval policy config (RFC-0254)} *)

module Shell_ir_approval : sig
  val raw_overlay : unit -> string option
  (** Single env spec for Shell IR approval trust overlay.
      See {!Masc_exec.Approval_config.shell_ir_approval_overlay_of_string} for
      supported values and validation semantics.
      Returns [None] when unset/blank. *)
end
