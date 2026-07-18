open Env_config_core

(** {1 Rate Limit Cleanup Configuration} *)

module RateLimit = struct
  (** Cleanup interval for stale rate limit buckets (seconds) *)
  let cleanup_interval_seconds =
    get_float ~default:300.0 "MASC_RATE_LIMIT_CLEANUP_INTERVAL_SEC"

  (** Max age for rate limit entries before cleanup (seconds) *)
  let entry_max_age_seconds =
    get_float ~default:3600.0 "MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC"
end

(** {1 Agent Autonomy Configuration}
    Primary env vars: MASC_AUTONOMY_*. *)

module Autonomy = struct
  (** Quiet hours start (0-23). Keeper suppresses actions in this window. *)
  let quiet_start =
    get_int ~default:3 "MASC_AUTONOMY_QUIET_START"

  (** Quiet hours end (0-23). *)
  let quiet_end =
    get_int ~default:7 "MASC_AUTONOMY_QUIET_END"
end

(** {1 Thompson Sampling / Agent Selection Configuration}
    Primary env vars: MASC_AUTONOMY_*. *)

module AgentSelection = struct
  let max_starvation_ticks =
    get_int ~default:12 "MASC_AUTONOMY_MAX_STARVATION_TICKS"

  let starvation_bonus_coefficient =
    get_float ~default:0.15 "MASC_AUTONOMY_STARVATION_BONUS_COEF"

  let thompson_weight =
    get_float ~default:0.7 "MASC_AUTONOMY_THOMPSON_WEIGHT"

  let vote_decay_factor =
    get_float ~default:0.95 "MASC_AUTONOMY_VOTE_DECAY_FACTOR"
end

(** {1 Timeouts & Buffer Sizes} *)

module Timeouts = struct
  (** Maintenance Pulse interval (seconds).
      Controls the orphan-observation and channel-dedup consumers.
      Clamped to >= 1.0 to prevent tight-loop when misconfigured.
      @category Runtime
      @ops_class operator *)
  let maintenance_pulse_interval_sec =
    Float.max 1.0
      (get_float ~default:60.0 "MASC_MAINTENANCE_PULSE_INTERVAL_SEC")
end

(** {1 Operator Snapshot Cache Configuration} *)

module Operator = struct
  (** Operator snapshot cache TTL (seconds). Default: 30. *)
  let cache_ttl_sec = get_float ~default:30.0 "MASC_OPERATOR_CACHE_TTL"

  (** Stale-while-revalidate grace factor. After the TTL expires, the
      previous snapshot is still served for [ttl * factor] seconds while a
      background fiber recomputes. Default: 3.0 (max 90 s stale at default TTL).
      @category Timeouts
      @ops_class operator *)
  let cache_stale_grace_factor =
    Float.max 0.0 (get_float ~default:3.0 "MASC_OPERATOR_CACHE_STALE_GRACE_FACTOR")

  (** Enable background revalidation when serving stale snapshots.
      Default: true. Disabling makes stale entries behave like the old
      blocking TTL cache, which is useful for tests or strict-freshness mode. *)
  let cache_background_revalidate =
    Feature_flag_registry.get_bool "MASC_OPERATOR_CACHE_BACKGROUND_REVALIDATE"
end

(** {1 Dashboard Configuration} *)

module Dashboard_config = struct
  (** Whether dashboard fixtures are enabled. Default: false.
      Re-readable within the process; this does not imply shell-level
      hot reload as an operator contract. *)
  let fixtures_enabled () = Feature_flag_registry.get_bool "MASC_DASHBOARD_FIXTURES_ENABLED"

  (** Dashboard fixture name override. *)
  let fixture_opt () =
    Sys.getenv_opt "MASC_DASHBOARD_FIXTURE" |> trim_opt

end

(** {1 Model Routing Defaults} *)

module Model_defaults = struct
  (** Default runtime label (e.g. "glm:pro,openai:gpt-4.1"). *)
  let default_runtime_opt () =
    Sys.getenv_opt "MASC_DEFAULT_RUNTIME" |> trim_opt
end

(** {1 Endpoint Configuration} *)
