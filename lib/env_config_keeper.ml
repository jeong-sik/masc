open Env_config_core

module Endpoints = struct
  (** @deprecated LLM-MCP server URL - no longer used.
      Use {!Oas_worker.complete_single} instead. *)
  let llm_mcp_url =
    get_string ~default:"" "LLM_MCP_URL"  (* Default empty - not used *)

  let masc_host_result () =
    match Uri.host (Uri.of_string (masc_http_base_url ())) with
    | Some host -> Ok host
    | None -> Error "MASC_HTTP_BASE_URL must include a host"
  (** MASC server host *)
  let masc_host () =
    match masc_host_result () with
    | Ok host -> host
    | Error msg -> failwith msg

  let masc_port_result () =
    match Uri.port (Uri.of_string (masc_http_base_url ())) with
    | Some port -> Ok port
    | None -> (
        match Uri.scheme (Uri.of_string (masc_http_base_url ())) with
        | Some "https" -> Ok 443
        | Some "http" -> Ok 80
        | _ -> Error "MASC_HTTP_BASE_URL must include a port or scheme")

  (** MASC server port *)
  let masc_port () =
    match masc_port_result () with
    | Ok port -> port
    | Error msg -> failwith msg

  let masc_sse_url_result () =
    Result.map (fun base -> Printf.sprintf "%s/sse" base) (masc_http_base_url_result ())

  (** MASC SSE URL (derived) *)
  let masc_sse_url () =
    match masc_sse_url_result () with
    | Ok url -> url
    | Error msg -> failwith msg
end

(** {1 Gardener — Self-Organizing Agent Ecosystem} *)

module Gardener = struct
  (** Master switch for Gardener Agent *)
  let enabled =
    get_bool ~default:true "MASC_GARDENER_ENABLED"

  (** Minimum agent population (never retire below this) *)
  let min_agents =
    get_int ~default:5 "MASC_GARDENER_MIN_AGENTS"

  (** Maximum agent population (never spawn above this) *)
  let max_agents =
    get_int ~default:30 "MASC_GARDENER_MAX_AGENTS"

  (** Target agent population (homeostatic sweet spot) *)
  let target_agents =
    get_int ~default:15 "MASC_GARDENER_TARGET_AGENTS"

  (** Maximum spawns allowed per day *)
  let max_daily_spawns =
    get_int ~default:3 "MASC_GARDENER_MAX_DAILY_SPAWNS"

  (** Maximum retirements allowed per day *)
  let max_daily_retirements =
    get_int ~default:2 "MASC_GARDENER_MAX_DAILY_RETIREMENTS"

  (** Minimum time between spawns (seconds) *)
  let spawn_cooldown_sec =
    get_float ~default:3600.0 "MASC_GARDENER_SPAWN_COOLDOWN_SEC"

  (** Minimum time between retirements (seconds) *)
  let retirement_cooldown_sec =
    get_float ~default:7200.0 "MASC_GARDENER_RETIREMENT_COOLDOWN_SEC"

  (** Use LLM for complex spawn/retire decisions *)
  let use_llm_decision =
    get_bool ~default:true "MASC_GARDENER_USE_LLM"

  (** Minimum hours before a gap signal can trigger spawn *)
  let gap_maturity_hours =
    get_float ~default:2.0 "MASC_GARDENER_GAP_MATURITY_HOURS"

  (** Hours of inactivity before an agent is retirement-eligible *)
  let idle_threshold_hours =
    get_float ~default:48.0 "MASC_GARDENER_IDLE_THRESHOLD_HOURS"

  (** Grace period before actual retirement (seconds) *)
  let retirement_grace_sec =
    get_float ~default:3600.0 "MASC_GARDENER_RETIREMENT_GRACE_SEC"

  (** Consecutive failures before circuit breaker opens *)
  let max_consecutive_failures =
    get_int ~default:3 "MASC_GARDENER_MAX_FAILURES"

  (** Circuit breaker open duration (seconds) *)
  let circuit_cooldown_sec =
    get_float ~default:3600.0 "MASC_GARDENER_CIRCUIT_COOLDOWN_SEC"

  (** Health check interval (seconds) *)
  let check_interval_sec =
    get_float ~default:1800.0 "MASC_GARDENER_CHECK_INTERVAL_SEC"
end

(** {1 Keeper Bootstrap Configuration} *)

module KeeperBootstrap = struct
  (** Enable startup keeper bootstrap scan *)
  let enabled =
    get_bool ~default:true "MASC_KEEPER_BOOTSTRAP_ENABLED"

  (** Keeper considered stale when last turn exceeds this threshold (seconds) *)
  let stale_turn_seconds =
    get_float ~default:3600.0 "MASC_KEEPER_BOOTSTRAP_STALE_TURN_SEC"

  (** Max keeper meta files to scan during bootstrap *)
  let max_scan =
    get_int ~default:10000 "MASC_KEEPER_BOOTSTRAP_MAX_SCAN"

  (** Backward compatibility: legacy field for call sites not yet migrated
      from pre-dynamic-sharding versions. Keep alias for max_scan. *)
  let max_active_keepers =
    get_int ~default:10000 "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS"
end

(** {1 Keeper Metrics Rotation Configuration} *)

module KeeperMetrics = struct
  (** Maximum metrics file size in bytes before rotation (default: 10MB) *)
  let max_file_bytes =
    get_int ~default:10_485_760 "MASC_KEEPER_METRICS_MAX_BYTES"

  (** Number of rotated files to keep (default: 1, i.e. .1 only) *)
  let max_rotated_files =
    get_int ~default:1 "MASC_KEEPER_METRICS_MAX_ROTATED"
end

(** {1 Keeper Interesting Alert Configuration} *)

module KeeperAlert = struct
  (** Master switch for keeper interesting alert detection/fanout *)
  let enabled =
    get_bool ~default:true "MASC_KEEPER_ALERT_ENABLED"

  (** Minimum score required to trigger alert fanout *)
  let min_score =
    get_float ~default:0.70 "MASC_KEEPER_ALERT_MIN_SCORE"

  (** Maximum alert body chars used for external fanout payloads *)
  let max_body_chars =
    get_int ~default:1200 "MASC_KEEPER_ALERT_MAX_BODY_CHARS"

  (** Retry count for each fanout channel (in addition to initial attempt) *)
  let max_retries =
    get_int ~default:2 "MASC_KEEPER_ALERT_MAX_RETRIES"

  (** Base retry delay in milliseconds (exponential backoff) *)
  let retry_base_delay_ms =
    get_int ~default:250 "MASC_KEEPER_ALERT_RETRY_BASE_DELAY_MS"

  (** Board fanout configuration *)
  let board_enabled =
    get_bool ~default:true "MASC_KEEPER_ALERT_BOARD_ENABLED"

  let board_author =
    get_string ~default:"keeper-alert-bot" "MASC_KEEPER_ALERT_BOARD_AUTHOR"

  let board_hearth =
    get_string ~default:"keeper-alert" "MASC_KEEPER_ALERT_BOARD_HEARTH"

  let board_visibility =
    get_string ~default:"internal" "MASC_KEEPER_ALERT_BOARD_VISIBILITY"

  (** Slack fanout configuration *)
  let slack_enabled =
    get_bool ~default:true "MASC_KEEPER_ALERT_SLACK_ENABLED"

  let slack_webhook_url =
    get_string ~default:"" "MASC_KEEPER_ALERT_SLACK_WEBHOOK_URL"

  (** Slack DM fanout configuration *)
  let slack_dm_enabled =
    get_bool ~default:false "MASC_KEEPER_ALERT_SLACK_DM_ENABLED"

  let slack_dm_user_id =
    get_string ~default:"" "MASC_KEEPER_ALERT_SLACK_DM_USER_ID"

  (** GitHub issue fanout configuration *)
  let github_enabled =
    get_bool ~default:false "MASC_KEEPER_ALERT_GITHUB_ENABLED"

  let github_repo =
    get_string ~default:"" "MASC_KEEPER_ALERT_GITHUB_REPO"

  let github_label =
    get_string ~default:"keeper-alert" "MASC_KEEPER_ALERT_GITHUB_LABEL"

  let github_min_score =
    get_float ~default:0.85 "MASC_KEEPER_ALERT_GITHUB_MIN_SCORE"
end

(** {1 Keeper Resident Supervisor Configuration} *)

module KeeperResidentSupervisor = struct
  (** Maximum restart attempts before declaring a keeper dead *)
  let max_restarts =
    get_int ~default:5 "MASC_KEEPER_SUPERVISOR_MAX_RESTARTS"

  (** Base delay for exponential backoff between restarts (seconds) *)
  let backoff_base_s =
    get_float ~default:10.0 "MASC_KEEPER_SUPERVISOR_BACKOFF_BASE_S"

  (** Maximum backoff delay cap (seconds) *)
  let backoff_max_s =
    get_float ~default:300.0 "MASC_KEEPER_SUPERVISOR_BACKOFF_MAX_S"

  (** Interval between supervisor sweep runs (seconds) *)
  let sweep_interval_sec =
    get_float ~default:30.0 "MASC_KEEPER_SUPERVISOR_SWEEP_SEC"
end

module Sentinel = struct
  let enabled = get_bool ~default:true "MASC_SENTINEL_ENABLED"
  let heartbeat_interval_sec = get_float ~default:30.0 "MASC_SENTINEL_HEARTBEAT_SEC"
  let board_patrol_interval_sec = get_float ~default:600.0 "MASC_SENTINEL_BOARD_PATROL_SEC"
  let task_hygiene_interval_sec = get_float ~default:300.0 "MASC_SENTINEL_TASK_HYGIENE_SEC"
  let keeper_health_interval_sec = get_float ~default:300.0 "MASC_SENTINEL_KEEPER_HEALTH_SEC"
  let task_stuck_threshold_sec = get_float ~default:600.0 "MASC_SENTINEL_TASK_STUCK_SEC"
  let task_stale_threshold_sec = get_float ~default:1800.0 "MASC_SENTINEL_TASK_STALE_SEC"
  let llm_enabled = get_bool ~default:true "MASC_SENTINEL_LLM_ENABLED"
  let llm_timeout_sec = get_int ~default:30 "MASC_SENTINEL_LLM_TIMEOUT_SEC"

  (** Governance sweep: auto-generate petitions for stuck tasks / inactive agents *)
  let governance_enabled = get_bool ~default:true "MASC_SENTINEL_GOVERNANCE_ENABLED"
  let governance_interval_sec = get_float ~default:1800.0 "MASC_SENTINEL_GOVERNANCE_INTERVAL_SEC"

  (** Threshold: tasks stuck longer than this trigger a governance petition *)
  let governance_task_stuck_sec = get_float ~default:86400.0 "MASC_SENTINEL_GOV_TASK_STUCK_SEC"
end

(** Print configuration summary for debugging *)
