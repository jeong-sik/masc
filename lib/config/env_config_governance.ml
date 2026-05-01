open Env_config_core

(** {1 Inference Configuration} *)

module Inference = struct
  (** Timeout for model API calls (seconds) *)
  let timeout_seconds =
    get_float ~default:30.0 "MASC_INFERENCE_TIMEOUT_SEC"

  (** Integer fallback for call sites that use second granularity only. *)
  let timeout_seconds_int =
    max 1 (int_of_float timeout_seconds)

  (* #9629: [operator_judge_timeout_seconds] and
     [dashboard_governance_judge_timeout_seconds] used to live here as
     dedicated [int] configs.  The two judges
     (governance compute_judgments / operator compute_judgments) now
     resolve their timeout through [Env_config_oas_bridge] alongside
     the other LLM-via-OAS-worker callers, so this module no longer
     exposes them.  The legacy env-var names
     ([MASC_OPERATOR_JUDGE_TIMEOUT_SEC],
     [MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC]) remain honoured
     by [Env_config_oas_bridge.timeout_sec] as a per-caller alias
     during the migration window. *)

  (** Enable inference response cache (L1+L2). *)
  let cache_enabled =
    Feature_flag_registry.get_bool "MASC_INFERENCE_CACHE_ENABLED"

  (** Default TTL for inference response cache (seconds). *)
  let cache_ttl_seconds =
    get_int ~default:300 "MASC_INFERENCE_CACHE_TTL_SEC"

  (** Skip caching for oversized prompts (character count). *)
  let cache_max_prompt_chars =
    get_int ~default:48000 "MASC_INFERENCE_CACHE_MAX_PROMPT_CHARS"

  (** Cache only deterministic temperatures (default exact 0.0). *)
  let cache_max_temperature =
    get_float ~default:0.0 "MASC_INFERENCE_CACHE_MAX_TEMP"

  (** L1 in-memory entry cap.
      BUG-015: Reduced from 2048 to 512 — unbounded growth with 2048 default
      caused excessive memory usage in long-running servers. *)
  let cache_l1_max_entries =
    get_int ~default:512 "MASC_INFERENCE_CACHE_L1_MAX_ENTRIES"

  (** Spawn cache policy:
      - off
      - safe_only (GLM direct HTTP only, no MCP-tool side effects) *)
  let spawn_cache_policy =
    get_string ~default:"safe_only" "MASC_SPAWN_CACHE_POLICY"
    |> String.trim
    |> String.lowercase_ascii
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
  (** Neo4j / zombie-cleanup interval (seconds).
      Controls the zero-zombie Pulse rhythm in the orchestrator.
      Clamped to >= 1.0 to prevent tight-loop when misconfigured. *)
  let neo4j_timeout_sec =
    Float.max 1.0 (get_float ~default:60.0 "MASC_NEO4J_TIMEOUT_SEC")

  (** SSE keepalive interval (seconds).
      Frequency of `: keepalive` frames on command-plane SSE streams.
      Clamped to >= 1.0 to prevent tight-loop when misconfigured. *)
  let sse_keepalive_sec =
    Float.max 1.0 (get_float ~default:30.0 "MASC_SSE_KEEPALIVE_SEC")

  (** A2A event buffer size per subscription.
      Caps the in-memory event list to prevent unbounded growth. *)
  let event_buffer_size =
    get_int ~default:100 "MASC_EVENT_BUFFER_SIZE"
end

(** {1 Operator Judge Configuration} *)

module Operator = struct
  (** Whether operator judge background loop is enabled. Default: true. *)
  let judge_enabled = Feature_flag_registry.get_bool "MASC_OPERATOR_JUDGE_ENABLED"

  (** Operator judge interval, clamped to >= 15s. Default: 60. *)
  let judge_interval_sec = max 15 (get_int ~default:60 "MASC_OPERATOR_JUDGE_INTERVAL_SEC")

  (** Coord TTL for operator judge cleanup, clamped to >= 15s. Default: 60. *)
  let room_ttl_sec = max 15 (get_int ~default:60 "MASC_OPERATOR_JUDGE_ROOM_TTL_SEC")

  (** Session TTL for operator judge cleanup, clamped to >= 30s. Default: 300. *)
  let session_ttl_sec = max 30 (get_int ~default:300 "MASC_OPERATOR_JUDGE_SESSION_TTL_SEC")

  (** Operator snapshot cache TTL (seconds). Default: 30. *)
  let cache_ttl_sec = get_float ~default:30.0 "MASC_OPERATOR_CACHE_TTL"
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

  (** Governance judge interval, clamped to >= 15s. Default: 60. *)
  let governance_judge_interval_sec =
    max 15 (get_int ~default:60 "MASC_DASHBOARD_GOVERNANCE_JUDGE_INTERVAL_SEC")

  (** Whether governance judge is enabled. Default: true. *)
  let governance_judge_enabled = Feature_flag_registry.get_bool "MASC_DASHBOARD_GOVERNANCE_JUDGE_ENABLED"
end

(** {1 Model Routing Defaults} *)

module Model_defaults = struct
  (** Default cascade label (e.g. "gemini:pro,claude:sonnet"). *)
  let default_cascade_opt () =
    Sys.getenv_opt "MASC_DEFAULT_CASCADE" |> trim_opt

  (** Default provider name. *)
  let default_provider_opt () =
    Sys.getenv_opt "MASC_DEFAULT_PROVIDER" |> trim_opt

  (** Default model id. *)
  let default_model_opt () =
    Sys.getenv_opt "MASC_DEFAULT_MODEL" |> trim_opt

  (** Routing cascade for team session routing. Defaults to the logical
      [routes.routing] key; runtime callers normalize it through the cascade
      route table. *)
  let routing_cascade () =
    match Sys.getenv_opt "MASC_ROUTING_CASCADE" |> trim_opt with
    | Some s -> s
    | None -> "routing"

  (** Goal models (comma-separated). *)
  let goal_models_opt () =
    Sys.getenv_opt "MASC_GOAL_MODELS" |> trim_opt

  (** Goal dispatch runtime. Default: "task". *)
  let goal_dispatch_runtime () =
    get_string ~default:"task" "MASC_GOAL_DISPATCH_RUNTIME"
end

(** {1 Anti-Rationalization Configuration}
    Primary env vars: MASC_ANTI_RATIONALIZATION_*. *)

module AntiRationalization = struct
  (* #9794: when the verifier LLM is unavailable, the historical behavior
     is to approve by default (favor liveness). Operators that want stronger
     governance can flip to fail-closed (favor safety) via env var.
     Default stays Open for backward compatibility. *)
  type fail_mode =
    | Open
    | Closed

  let fail_mode_of_string raw =
    let s = String.lowercase_ascii (String.trim raw) in
    match s with
    | "closed" | "reject" | "fail_closed" | "deny" -> Closed
    | _ -> Open

  let fail_mode_to_string = function
    | Open -> "open"
    | Closed -> "closed"

  let fail_mode =
    fail_mode_of_string
      (get_string ~default:"open" "MASC_ANTI_RATIONALIZATION_FAIL_MODE")

  (* #10113: gate 2 (substring excuse pattern) historically
     issued a terminal Reject before the LLM evaluator ever
     saw the notes.  Substring matching has no word-boundary
     or context awareness, so legitimate notes that mention
     "filed a follow-up issue" or "fixed primary path; pre-
     existing issue #1234 tracked separately" were rejected
     and keepers learned to sanitize vocabulary instead of
     describing the work honestly — the opposite of the
     gate's intent.

     Default after #10113 is [false]: the substring
     detection becomes an advisory hint that travels into
     the LLM evaluator prompt, and the LLM makes the final
     decision with full context.  Operators who explicitly
     want a local fail-closed safety net (e.g. running
     without a reliable LLM evaluator) can flip this to
     [true] to restore the terminal-reject behaviour.
     Independent of [fail_mode] which only governs the
     LLM-unavailable branch at gate 3. *)
  let gate2_fail_closed =
    get_bool ~default:false "MASC_ANTI_RATIONALIZATION_GATE2_FAIL_CLOSED"
end

(** {1 Endpoint Configuration} *)
