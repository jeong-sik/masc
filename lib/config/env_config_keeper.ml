open Env_config_core

module Endpoints = struct
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

  (** Maximum concurrently active keepers. Guards keeper creation and bootstrap. *)
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

(** {1 Keeper Supervisor Configuration} *)

module KeeperSupervisor = struct
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

  (** Self-preservation: ratio of crashed keepers to trigger suppression *)
  let self_preservation_ratio =
    Float.min 1.0 (Float.max 0.0
      (get_float ~default:0.3 "MASC_KEEPER_SELF_PRESERVATION_RATIO"))

  (** Self-preservation: minimum crashed candidates to trigger *)
  let self_preservation_min_candidates =
    max 1 (get_int ~default:2 "MASC_KEEPER_SELF_PRESERVATION_MIN_CANDIDATES")

  (** Dead tombstone TTL: seconds before Dead entries are cleaned up *)
  let dead_ttl_sec =
    Float.max 60.0 (get_float ~default:3600.0 "MASC_KEEPER_DEAD_TTL_SEC")
end

(** {1 Keeper Runtime Configuration} *)

module KeeperRuntime = struct
  (** Enable keeper debug logging. Default: false. *)
  let debug = get_bool ~default:false "MASC_KEEPER_DEBUG"

  (** Daily budget for keeper deliberation (USD). Default: 0.10.
      Runtime-readable (tests change this via putenv). *)
  let deliberation_daily_budget_usd () =
    get_float ~default:0.10 "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD"

  (** Keeper keepalive snapshot interval, clamped to [15, 3600]. Default: 300. *)
  let snapshot_sec =
    max 15 (min 3600 (get_int ~default:300 "MASC_KEEPER_SNAPSHOT_SEC"))

end

(** {1 Delta Checkpoint Configuration} *)

module DeltaCheckpoint = struct
  (** Enable delta-based checkpoint storage. Default: false (experimental). *)
  let enabled =
    get_bool ~default:false "MASC_KEEPER_DELTA_CHECKPOINT_ENABLED"

  (** Enable lazy message loading from checkpoints. Default: false (experimental). *)
  let lazy_loading =
    get_bool ~default:false "MASC_KEEPER_LAZY_MESSAGE_LOADING"

  (** Maximum delta chain length before forcing full checkpoint. Default: 5.
      Range: [2, 20]. Prevents unbounded delta chains. *)
  let max_chain_length =
    max 2 (min 20 (get_int ~default:5 "MASC_KEEPER_DELTA_MAX_CHAIN_LENGTH"))

  (** Minimum messages in checkpoint before enabling delta mode. Default: 3.
      Range: [1, 20]. Small checkpoints don't benefit from delta. *)
  let min_messages_for_delta =
    max 1 (min 20 (get_int ~default:3 "MASC_KEEPER_DELTA_MIN_MESSAGES"))
end

(** {1 Alert Dedup Configuration} *)

module AlertDedup = struct
  (** Alert dedup window, clamped to >= 5s. Default: 60. *)
  let window_sec =
    Float.max 5.0 (get_float ~default:60.0 "MASC_ALERT_DEDUP_WINDOW_SEC")
end

(** Shared: keepalive interval, read early so WorkAsHeartbeat can reference it. *)
let keepalive_interval_sec_ =
  max 5 (min 300 (get_int ~default:30 "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC"))

(** {1 Work-as-Heartbeat Configuration (Phase 1)} *)

module WorkAsHeartbeat = struct
  (** Master switch. When true, successful Room.heartbeat_in_room after a
      unified turn counts as presence proof, allowing the next cycle to skip
      the full ensure_keeper_room_presence call. *)
  let enabled =
    get_bool ~default:true "MASC_KEEPER_WORK_AS_HEARTBEAT"

  (** Maximum seconds since last successful room heartbeat before presence
      sync is required again. Floor = keepalive interval (dynamic). *)
  let max_silence_sec =
    let floor = Float.of_int keepalive_interval_sec_ in
    Float.max floor (get_float ~default:120.0 "MASC_KEEPER_MAX_SILENCE_SEC")
end

(** {1 Smart Heartbeat Configuration (Phase 2)} *)

module SmartHeartbeat = struct
  (** Master switch for adaptive heartbeat scheduling in the keepalive loop.
      When true, Heartbeat_smart.should_emit gates presence/snapshot/board/turn
      blocks, skipping cycles when the keeper is busy or deeply idle. *)
  let enabled =
    get_bool ~default:true "MASC_KEEPER_SMART_HEARTBEAT"
end

(** {1 Keeper Keepalive Loop Constants} *)

module KeeperKeepalive = struct
  (** Heartbeat cycle interval in seconds. Default: 30.
      Range: [5, 300]. This is the foundational timing constant — every
      keeper cycle (presence, snapshot, board scan, turn, recurring) runs
      at this cadence. *)
  let interval_sec = keepalive_interval_sec_

  (** Maximum consecutive heartbeat failures before raising
      Keeper_heartbeat_failure (structured crash). Default: 5.
      Range: [2, 50]. *)
  let max_consecutive_failures =
    max 2 (min 50 (get_int ~default:5 "MASC_KEEPER_MAX_CONSECUTIVE_HB_FAILURES"))

  (** Maximum consecutive unified turn failures before marking keeper as
      crashed. Covers LLM timeout, rate limit, and other turn errors.
      Default: 10. Range: [3, 100]. *)
  let max_consecutive_turn_failures =
    max 3 (min 100 (get_int ~default:10 "MASC_KEEPER_MAX_CONSECUTIVE_TURN_FAILURES"))

  (** Board-reactive wakeup debounce in seconds. Prevents rapid repeated
      wakeups from the same board post. Default: 60.0.
      Range: [5, 300]. *)
  let board_debounce_sec =
    Float.max 5.0 (Float.min 300.0
      (get_float ~default:60.0 "MASC_KEEPER_BOARD_DEBOUNCE_SEC"))

  (** Interruptible sleep chunk size in seconds. Smaller = faster wakeup
      response but more CPU polling. Default: 2.0.
      Range: [0.1, 10.0]. *)
  let sleep_chunk_sec =
    Float.max 0.1 (Float.min 10.0
      (get_float ~default:2.0 "MASC_KEEPER_SLEEP_CHUNK_SEC"))

  (** Jitter factor applied to heartbeat interval (fraction of base).
      Default: 0.2 (20%). Range: [0.0, 0.5]. *)
  let jitter_factor =
    Float.max 0.0 (Float.min 0.5
      (get_float ~default:0.2 "MASC_KEEPER_HEARTBEAT_JITTER_FACTOR"))
end

(** {1 gRPC Heartbeat Reconnect} *)

module KeeperGrpc = struct
  (** Maximum gRPC reconnect attempts before stopping the heartbeat fiber.
      Default: 5. Range: [1, 20]. *)
  let max_reconnect_attempts =
    max 1 (min 20 (get_int ~default:5 "MASC_KEEPER_GRPC_MAX_RECONNECT"))

  (** Backoff delay between gRPC reconnect attempts in seconds.
      Default: 5.0. Range: [1.0, 60.0]. *)
  let reconnect_backoff_sec =
    Float.max 1.0 (Float.min 60.0
      (get_float ~default:5.0 "MASC_KEEPER_GRPC_RECONNECT_BACKOFF_SEC"))
end

(** {1 Proactive Generation} *)

module KeeperProactive = struct
  (** Maximum proactive generation attempts before falling back.
      Default: 3. Range: [1, 10]. *)
  let max_attempts =
    max 1 (min 10 (get_int ~default:3 "MASC_KEEPER_PROACTIVE_MAX_ATTEMPTS"))

  (** Stage timing ring buffer size for Phase 0 profiling.
      Default: 100. Range: [10, 1000]. *)
  let stage_timing_ring_size =
    max 10 (min 1000 (get_int ~default:100 "MASC_KEEPER_STAGE_TIMING_RING_SIZE"))
end

(** {1 Tool Execution} *)

module KeeperToolExec = struct
  (** Maximum consecutive failures for the same (tool_name, args_hash)
      before blocking further attempts. Prevents infinite retry loops.
      Default: 3. Range: [2, 20]. *)
  let max_consecutive_tool_failures =
    max 2 (min 20 (get_int ~default:3 "MASC_KEEPER_MAX_CONSECUTIVE_TOOL_FAILURES"))
end

(** Print configuration summary for debugging *)
