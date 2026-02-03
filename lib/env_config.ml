(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.

    Usage:
      let threshold = Env_config.Zombie.threshold_seconds
      let lock_timeout = Env_config.Lock.timeout_seconds
*)

(** Safe getters with defaults *)
let get_string ~default name =
  match Sys.getenv_opt name with
  | Some v -> v
  | None -> default

let get_int ~default name =
  match Sys.getenv_opt name with
  | Some v -> Safe_ops.int_of_string_with_default ~default v
  | None -> default

let get_float ~default name =
  match Sys.getenv_opt name with
  | Some v -> Safe_ops.float_of_string_with_default ~default v
  | None -> default

let get_bool ~default name =
  match Sys.getenv_opt name with
  | Some v ->
      (match String.lowercase_ascii v with
       | "true" | "1" | "yes" -> true
       | "false" | "0" | "no" -> false
       | _ -> default)
  | None -> default

(** {1 Zombie Detection / Cleanup Configuration} *)

module Zombie = struct
  (** Threshold for considering a resource as zombie (seconds) *)
  let threshold_seconds =
    get_float ~default:300.0 "MASC_ZOMBIE_THRESHOLD_SEC"

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
end

(** {1 Spawn Configuration} *)

module Spawn = struct
  (** Default spawn timeout for agent processes (seconds).
      Used by spawn.ml, spawn_eio.ml, tool_mitosis.ml, and tool_relay.ml.
      Higher value (600s) allows for slow network/API conditions while preventing indefinite hangs. *)
  let timeout_seconds =
    int_of_float (get_float ~default:600.0 "MASC_SPAWN_TIMEOUT_SEC")
end

(** {1 Ollama Configuration} *)

module Ollama = struct
  (** Default model — always resident in VRAM via launchd preload *)
  let default_model =
    get_string ~default:"glm-4.7-flash" "OLLAMA_DEFAULT_MODEL"
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

(** {1 Qdrant Configuration} *)

module Qdrant = struct
  (** Timeout for Qdrant API calls (seconds) *)
  let timeout_seconds =
    get_float ~default:30.0 "MASC_QDRANT_TIMEOUT_SEC"
end

(** {1 LLM Configuration} *)

module Llm = struct
  (** Timeout for LLM API calls (seconds) *)
  let timeout_seconds =
    get_float ~default:30.0 "MASC_LLM_TIMEOUT_SEC"
end

(** {1 Rate Limit Cleanup Configuration} *)

module RateLimit = struct
  (** Cleanup interval for stale rate limit buckets (seconds) *)
  let cleanup_interval_seconds =
    get_float ~default:300.0 "MASC_RATE_LIMIT_CLEANUP_INTERVAL_SEC"

  (** Max age for rate limit entries before cleanup (seconds) *)
  let entry_max_age_seconds =
    get_float ~default:3600.0 "MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC"
end

(** {1 Lodge Heartbeat v2 — Generative Agent Configuration} *)

module LodgeV2 = struct
  (** Tick interval: 4 hours default (was 60-120s in v1) *)
  let tick_interval_seconds =
    get_float ~default:14400.0 "MASC_LODGE_TICK_INTERVAL_SEC"

  (** How many agents to activate per tick *)
  let agents_per_tick =
    get_int ~default:3 "MASC_LODGE_AGENTS_PER_TICK"

  (** Max posts an agent can make per tick *)
  let max_posts_per_tick =
    get_int ~default:1 "MASC_LODGE_MAX_POSTS_PER_TICK"

  (** Max comments an agent can make per tick *)
  let max_comments_per_tick =
    get_int ~default:3 "MASC_LODGE_MAX_COMMENTS_PER_TICK"

  (** Max total actions per agent per day *)
  let max_daily_actions =
    get_int ~default:10 "MASC_LODGE_MAX_DAILY_ACTIONS"

  (** Importance sum threshold to trigger reflection *)
  let reflection_threshold =
    get_int ~default:100 "MASC_LODGE_REFLECTION_THRESHOLD"

  (** Use plan-based agent selection (vs legacy round-robin) *)
  let use_planner =
    get_bool ~default:true "MASC_LODGE_USE_PLANNER"

  (** Enable heartbeat *)
  let enabled =
    get_bool ~default:true "MASC_LODGE_ENABLED"

  (** Quiet hours start (KST, inclusive) *)
  let quiet_start =
    get_int ~default:3 "MASC_LODGE_QUIET_START"

  (** Quiet hours end (KST, exclusive) *)
  let quiet_end =
    get_int ~default:7 "MASC_LODGE_QUIET_END"

  (** Min gap between same agent check-ins (seconds) *)
  let min_checkin_gap_seconds =
    get_float ~default:1800.0 "MASC_LODGE_MIN_CHECKIN_GAP"
end

(** {1 Endpoint Configuration} *)

module Endpoints = struct
  (** LLM-MCP server URL *)
  let llm_mcp_url =
    get_string ~default:"http://127.0.0.1:8932/mcp" "LLM_MCP_URL"

  (** MASC server host *)
  let masc_host =
    get_string ~default:"127.0.0.1" "MASC_HOST"

  (** MASC server port *)
  let masc_port =
    get_int ~default:8935 "MASC_MCP_PORT"

  (** MASC SSE URL (derived) *)
  let masc_sse_url =
    Printf.sprintf "http://%s:%d/sse" masc_host masc_port
end

(** Print configuration summary for debugging *)
let print_summary () =
  Printf.eprintf "[env_config] Zombie: threshold=%.0fs cleanup_interval=%.0fs\n%!"
    Zombie.threshold_seconds Zombie.cleanup_interval_seconds;
  Printf.eprintf "[env_config] Lock: timeout=%.0fs expiry_warning=%.0fs\n%!"
    Lock.timeout_seconds Lock.expiry_warning_seconds;
  Printf.eprintf "[env_config] Session: max_age=%.0fs rate_limit_window=%.0fs\n%!"
    Session.max_age_seconds Session.rate_limit_window_seconds;
  Printf.eprintf "[env_config] Tempo: min=%.0fs max=%.0fs default=%.0fs\n%!"
    Tempo.min_interval_seconds Tempo.max_interval_seconds Tempo.default_interval_seconds;
  Printf.eprintf "[env_config] Qdrant: timeout=%.0fs\n%!" Qdrant.timeout_seconds;
  Printf.eprintf "[env_config] Llm: timeout=%.0fs\n%!" Llm.timeout_seconds;
  Printf.eprintf "[env_config] RateLimit: cleanup_interval=%.0fs entry_max_age=%.0fs\n%!"
    RateLimit.cleanup_interval_seconds RateLimit.entry_max_age_seconds;
  Printf.eprintf "[env_config] LodgeV2: tick=%.0fs agents_per_tick=%d planner=%b reflection_thresh=%d\n%!"
    LodgeV2.tick_interval_seconds LodgeV2.agents_per_tick
    LodgeV2.use_planner LodgeV2.reflection_threshold
