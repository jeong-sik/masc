open Env_config_core

module Zombie = struct
  (** Threshold for considering a resource as zombie (seconds) *)
  let threshold_seconds =
    get_float ~default:300.0 "MASC_ZOMBIE_THRESHOLD_SEC"

  (** Threshold for keeper agents (longer grace period, default 1 hour) *)
  let keeper_threshold_seconds =
    get_float ~default:3600.0 "MASC_KEEPER_ZOMBIE_THRESHOLD_SEC"

  (** Cleanup loop interval (seconds) *)
  let cleanup_interval_seconds =
    get_float ~default:60.0 "MASC_ZOMBIE_CLEANUP_INTERVAL_SEC"
end

(** {1 Lock Configuration} *)

module Lock = struct
  (** Default lock timeout (seconds) *)
  let timeout_seconds =
    get_float ~default:1800.0 "MASC_LOCK_TIMEOUT_SEC"

  (** Lock expiry warning threshold (seconds before expiry) *)
  let expiry_warning_seconds =
    get_float ~default:300.0 "MASC_LOCK_EXPIRY_WARNING_SEC"
end

(** {1 Session Configuration} *)

module Session = struct
  (** Maximum session age before cleanup (seconds) *)
  let max_age_seconds =
    get_float ~default:3600.0 "MASC_SESSION_MAX_AGE_SEC"

  (** Rate limit window (seconds) *)
  let rate_limit_window_seconds =
    get_float ~default:60.0 "MASC_SESSION_RATE_LIMIT_WINDOW_SEC"
end

(** {1 Tempo (Polling Interval) Configuration} *)

module Tempo = struct
  (** Minimum polling interval (seconds) - for urgent tempo *)
  let min_interval_seconds =
    get_float ~default:60.0 "MASC_TEMPO_MIN_INTERVAL_SEC"

  (** Maximum polling interval (seconds) - for idle tempo *)
  let max_interval_seconds =
    get_float ~default:600.0 "MASC_TEMPO_MAX_INTERVAL_SEC"

  (** Default polling interval (seconds) *)
  let default_interval_seconds =
    get_float ~default:300.0 "MASC_TEMPO_DEFAULT_INTERVAL_SEC"
end

(** {1 Orchestrator Configuration} *)

module Orchestrator = struct
  (** Orchestrator check interval (seconds) *)
  let check_interval_seconds =
    get_float ~default:300.0 "MASC_ORCHESTRATOR_INTERVAL"

  (** Orchestrator agent name *)
  let agent_name =
    get_string ~default:"orchestrator" "MASC_ORCHESTRATOR_AGENT"
end

(** {1 Mitosis (Cell Division) Configuration} *)

module Mitosis = struct
  (** Time-based trigger interval (seconds) *)
  let trigger_interval_seconds =
    get_float ~default:300.0 "MASC_MITOSIS_INTERVAL_SEC"

  (** Cooldown between consecutive handoffs (seconds).
      Prevents rapid repeated handoffs when context_ratio fluctuates near threshold. *)
  let handoff_cooldown_seconds =
    get_float ~default:60.0 "MASC_MITOSIS_HANDOFF_COOLDOWN_SEC"

  (** Enable experimental mitosis path (A/B testing integration).
      When true, run_sync_handoff logs the experimental path and can
      participate in experiment flag checks. *)
  let experiment_enabled =
    get_bool ~default:false "MASC_MITOSIS_EXPERIMENT_ENABLED"

  (** Enable adaptive threshold learning from handoff outcomes.
      When true, thresholds are adjusted via EMA based on handoff quality signals.
      Persisted per room in ~/.masc/adaptive_thresholds_{room}.json.
      Default: false (safe rollout — uses static thresholds until enabled). *)
  let adaptive_thresholds_enabled =
    get_bool ~default:false "MASC_ADAPTIVE_THRESHOLDS_ENABLED"
end

(** {1 Spawn Configuration} *)

module Spawn = struct
  (** Default spawn timeout for agent processes (seconds).
      Used by spawn.ml, spawn_eio.ml, tool_mitosis.ml, and tool_relay.ml.
      Higher value (600s) allows for slow network/API conditions while preventing indefinite hangs. *)
  let timeout_seconds =
    int_of_float (get_float ~default:600.0 "MASC_SPAWN_TIMEOUT_SEC")

  (** Extended timeout for perpetual coding mode (seconds).
      Used when perpetual_loop spawns coding agents. Default 2 hours. *)
  let coding_timeout_seconds =
    int_of_float (get_float ~default:7200.0 "MASC_SPAWN_CODING_TIMEOUT_SEC")

  (** Grace period before timeout — sends SIGTERM for checkpoint opportunity (seconds). *)
  let grace_period_seconds =
    int_of_float (get_float ~default:60.0 "MASC_SPAWN_GRACE_PERIOD_SEC")
end

(** {1 Local LLM Server Configuration} *)

module Llama = struct
  (** OpenAI-compatible llama.cpp server URL *)
  let server_url =
    get_string ~default:"http://127.0.0.1:8085" "LLAMA_SERVER_URL"

  (** Default local runtime model id for llama.cpp/OpenAI-compatible servers. *)
  let default_model =
    get_string ~default:"explicit-model-required" "LLAMA_DEFAULT_MODEL"

  (** Upper bound for local llama-provider requests.
      Callers may request less, but never more than this cap. *)
  let max_tokens =
    get_int ~default:32768 "MASC_LLAMA_MAX_TOKENS"
end

(** {1 Federation Configuration} *)

module Federation = struct
  (** Cross-cluster request timeout (seconds) *)
  let timeout_seconds =
    get_float ~default:3600.0 "MASC_FEDERATION_TIMEOUT_SEC"
end

(** {1 Cancellation Token Configuration} *)

module Cancellation = struct
  (** Token cleanup max age (seconds) *)
  let token_max_age_seconds =
    get_float ~default:3600.0 "MASC_CANCELLATION_TOKEN_MAX_AGE_SEC"
end

(** {1 Internal Guardian Configuration} *)
