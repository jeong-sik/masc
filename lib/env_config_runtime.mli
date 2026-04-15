(** MASC Runtime Environment Configuration

    Runtime-specific settings: zombies, locks, sessions, tempo, decisions,
    cache, orchestrator, spawn, local runtime, federation,
    cancellation, neo4j, voice, custom model, network, timeouts,
    inference defaults, control plane cleanup, message GC. *)

module Zombie : sig
  val threshold_seconds : float
  val keeper_threshold_seconds : float
  val cleanup_interval_seconds : float
end

module Lock : sig
  val timeout_seconds : float
  val expiry_warning_seconds : float
end

module Session : sig
  val max_age_seconds : float
  val rate_limit_window_seconds : float
end

module Tempo : sig
  val min_interval_seconds : float
  val max_interval_seconds : float
  val default_interval_seconds : float
end

module Decision : sig
  val ttl_seconds : float
end

module Cache : sig
  val max_entry_size : int
  val max_entries : int
end

module Claim : sig
  val ttl_seconds : float
end

module Orchestrator : sig
  val check_interval_seconds : float
  val agent_name : string
  val min_priority : int
  val timeout_seconds : int
  val enabled : bool
end

module TeamSession : sig
  val router_judge_enabled : unit -> bool
  val router_judge_timeout_sec : unit -> int
  val router_judge_confidence_threshold : unit -> float
  val router_judge_model_opt : unit -> string option
end

module Spawn : sig
  val timeout_seconds : int
  val coding_timeout_seconds : int
  val grace_period_seconds : int
end

module Local_runtime : sig
  val server_url : string
  val default_model : string
  val max_tokens : int
  val llama_swarm_model_opt : unit -> string option
  val mcp_url : unit -> string
end

module Llama : sig
  val server_url : string
  val default_model : string
  val max_tokens : int
  val llama_swarm_model_opt : unit -> string option
  val mcp_url : unit -> string
end

module Glm : sig
  val server_url : string
end

module Cancellation : sig
  val token_max_age_seconds : float
end

module Neo4j : sig
  val uri : string
  val http_uri : string
  val user : string
  val password_result : unit -> (string, string) result
end

module Voice : sig
  val default_host : string
  val default_port : int
end

module Network : sig
  val is_localhost : string -> bool
end

module Timeout : sig
  val gcloud_auth_sec : float
  val anthropic_api_sec : int
  val openai_compat_api_sec : int
  val model_grace_sec : float
  val keeper_status_sec : float
end

module Inference_defaults : sig
  val default_max_tokens : int
  val sse_retry_ms : int
  val log_truncation_len : int
end

module Cp : sig
  val cleanup_days : int
end

module Message : sig
  val max_count : int
end

module Transport : sig
  type h2_mode =
    | Auto
    | H1_only
    | H2_only
    | Unknown_h2_mode of string

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

module Cdal : sig
  val enabled : unit -> bool
end

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

module ProcMemory : sig
  val min_evidence : int
  val min_confidence : float
end

module Pulse_config : sig
  val max_consumer_failures : int
end

module Circuit : sig
  val failure_threshold : int
  val cooldown_sec : float
end

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

module Rate_bucket : sig
  val rate : float
  val burst : int
end

module Worker : sig
  val local_runtime_debug : bool
  val local_runtime_cooldown_sec_opt : unit -> string option
  val local_worker_max_tokens : int
  val local_worker_heartbeat_sec : int
end

module Oas_sse : sig
  val drain_interval_sec : float
end

module Memory_oas : sig
  val default_importance : int
end
