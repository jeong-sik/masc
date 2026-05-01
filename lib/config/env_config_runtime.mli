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
end

(** {1 Tempo (polling interval)} *)

module Tempo : sig
  val min_interval_seconds : float
  val max_interval_seconds : float
  val default_interval_seconds : float
end

(** {1 Decision TTL} *)

module Decision : sig
  val ttl_seconds : float
end

(** {1 Cache} *)

module Cache : sig
  val max_entry_size : int
  val max_entries : int
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

(** {1 Relay / CLI} *)

module Relay : sig
  val target_agent : string
end

module Cli : sig
  val default_agent : string
end

(** {1 Spawn} *)

module Spawn : sig
  val timeout_seconds : int
  val coding_timeout_seconds : int
  val grace_period_seconds : int
end

(** {1 Local runtime / llama.cpp} *)

module Local_runtime : sig
  val server_url : string
  val default_model : string
  val max_tokens : int
  val worker_model_opt : unit -> string option
  val mcp_url : unit -> string
end

module Llama = Local_runtime
(** Backward-compatible alias for {!Local_runtime}. *)

module Ollama : sig
  val server_url : string
  val default_model : string
end

module Glm : sig
  val server_url : string
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

(** {1 Subsystem timeout defaults} *)

module Timeout : sig
  val gcloud_auth_sec : float
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
  val openai_compat_enabled : bool
  val http_auth_strict_env_enabled : unit -> bool
  val startup_watchdog_sec : unit -> float
end

(** {1 CDAL gate} *)

module Cdal : sig
  val enabled : unit -> bool
  val gate_enabled : unit -> bool
  val verdict_lookup_limit : unit -> int
end

(** {1 Verification FSM} *)

module Verification : sig
  val fsm_enabled : unit -> bool
  val timeout_check_interval_seconds : float
end

(** {1 Goal / Approval janitors} *)

module Goal_janitor : sig
  val enabled : unit -> bool
  val interval_seconds : float
end

module Approval_janitor : sig
  val enabled : unit -> bool
  val interval_seconds : float
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
  val dispatch_v2_enabled : bool
  val full_surface_enabled : unit -> bool
  val list_page_size : unit -> int
  val description_budget_opt : unit -> int option
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

(** {1 Memory OAS bridge} *)

module Memory_oas : sig
  val default_importance : int
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
  val mission_timeout_sec : float
  val shell_timeout_sec : float
  val shell_light_timeout_sec : float
  val render_timeout_sec : float
end

(** {1 Internal timers / cache TTLs} *)

module InternalTimers : sig
  val metrics_flush_sec : float
  val session_live_turn_window_sec : float
  val label_quiet_threshold_sec : float
  val label_stuck_threshold_sec : float
  val briefing_cache_ttl_sec : float
  val bootstrap_window_sec : float
  val sse_buffer_ttl_sec : float
  val cancellation_cleanup_sec : float
  val provider_run_ttl_sec : float
  val stalled_session_threshold_sec : float
  val janitor_interval_sec : float
  val rate_limit_bucket_ttl_sec : int
end

(** {1 Sidecar reconcile loop} *)

module Sidecar : sig
  val reconcile_backoff_sec : float
  val control_command_timeout_sec : float
  val schema_generation_timeout_sec : float
end

(** {1 Coord local git operation timeouts} *)

module Coord_git : sig
  val local_op_timeout_sec : float
end
