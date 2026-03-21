(** MASC Runtime Environment Configuration

    Runtime-specific settings: zombies, locks, sessions, tempo, decisions,
    cache, orchestrator, mitosis, spawn, local runtime, federation,
    cancellation, neo4j, voice, custom model, network, timeouts,
    inference defaults, control plane cleanup, message GC, chain. *)

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

module Orchestrator : sig
  val check_interval_seconds : float
  val agent_name : string
end

module Mitosis : sig
  val trigger_interval_seconds : float
  val handoff_cooldown_seconds : float
  val experiment_enabled : bool
  val adaptive_thresholds_enabled : bool
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
end

module Llama : sig
  val server_url : string
  val default_model : string
  val max_tokens : int
end

module Federation : sig
  val timeout_seconds : float
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

module Custom_model : sig
  val default_server_url : string
end

module Network : sig
  val is_localhost : string -> bool
end

module Timeout : sig
  val gcloud_auth_sec : float
  val anthropic_api_sec : int
  val openai_compat_api_sec : int
  val model_grace_sec : float
  val graphql_query_sec : float
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

module Chain : sig
  val judge_model : string
end
