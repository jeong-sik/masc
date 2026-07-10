(** Env_config_keeper — keeper runtime parameters from environment.

    All [MASC_KEEPER_*] env vars in this module can also be set
    declaratively in [<resolved config root>/runtime.toml].
    The TOML loader ({!Keeper_runtime_config.load_and_apply}) runs at
    server startup and records unset values in the process-local boot
    override store before this module initializes.

    Precedence: process env > TOML > hardcoded default below.

    See [docs/BOOT-ENV-STATE-INVENTORY.md] section 1.3 for the full
    TOML schema and section mapping. *)

open Env_config_core

(** {1 Keeper Bootstrap Configuration} *)

module KeeperBootstrap = struct
  (** Enable startup keeper bootstrap scan *)
  let enabled = Feature_flag_registry.get_bool "MASC_KEEPER_BOOTSTRAP_ENABLED"

  (** Keeper considered stale when last turn exceeds this threshold (seconds) *)
  let stale_turn_seconds =
    get_float_nonneg ~default:3600.0 "MASC_KEEPER_BOOTSTRAP_STALE_TURN_SEC"
  ;;

  (** Max keeper meta files to scan during bootstrap *)
  let max_scan = get_int_nonneg ~default:10000 "MASC_KEEPER_BOOTSTRAP_MAX_SCAN"

  (** Maximum concurrently active keepers. Guards keeper creation and bootstrap. *)
  let max_active_keepers =
    get_int_nonneg ~default:10000 "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS"
  ;;

  (** Polling interval (seconds) for the lazy-startup wait loop in
      [server_bootstrap_loops.ml]. The autoboot fiber wakes up every
      [lazy_startup_poll_interval_sec] to re-check whether all
      registered lazy startup tasks have completed before kicking off
      keeper bootstrap. Default 0.25s preserves the inline literal at
      [server_bootstrap_loops.ml:157] (responsive enough for unit
      tests while keeping the idle CPU cost negligible). Floor 0.05s
      protects against operator typos that would burn CPU. *)
  let lazy_startup_poll_interval_sec =
    Float.max
      0.05
      (get_float ~default:0.25 "MASC_KEEPER_BOOTSTRAP_LAZY_STARTUP_POLL_INTERVAL_SEC")
  ;;

  (** Polling interval (seconds) for the keeper-lifecycle listener
      retry loop in [server_bootstrap_loops.ml]. After a listener
      iteration raises (non-cancellation) the loop sleeps for this
      interval before retrying — keeping the spinning under control
      when an upstream subsystem is briefly down. Default 0.25s
      preserves the inline literal at [server_bootstrap_loops.ml:240]. *)
  let keeper_listener_retry_interval_sec =
    Float.max
      0.05
      (get_float ~default:0.25 "MASC_KEEPER_BOOTSTRAP_LISTENER_RETRY_INTERVAL_SEC")
  ;;

  (** Settle delay (seconds) between lazy-startup completion and the
      keeper bootstrap fan-out. The autoboot fiber sleeps for this
      duration so SSE/board/orchestrator subsystems get a chance to
      finish their first tick before keeper boot competes for them.
      Default 5.0s preserves the inline literal at
      [server_bootstrap_loops.ml:482]. Operators on cold-start machines
      may raise this; setting to 0 is allowed (no settle) but unwise
      under load. *)
  let post_startup_settle_sec =
    Float.max 0.0 (get_float ~default:5.0 "MASC_KEEPER_BOOTSTRAP_POST_STARTUP_SETTLE_SEC")
  ;;
end

(** {1 Keeper Metrics Rotation Configuration} *)

module KeeperMetrics = struct
  (** Maximum metrics file size in bytes before rotation (default: 10MB) *)
  let max_file_bytes = get_int_nonneg ~default:10_485_760 "MASC_KEEPER_METRICS_MAX_BYTES"

  (** Number of rotated files to keep (default: 1, i.e. .1 only) *)
  let max_rotated_files = get_int_nonneg ~default:1 "MASC_KEEPER_METRICS_MAX_ROTATED"
end

(** {1 Keeper Wire Capture Configuration} *)

module KeeperWireCapture = struct
  let clamp_int ~min_value ~max_value value =
    max min_value (min max_value value)
  ;;

  (** Master switch for diagnostic MASC->OAS wire capture. Default off.
      @category Policies @ops_class operator *)
  let enabled () = Feature_flag_registry.get_bool "MASC_KEEPER_WIRE_CAPTURE"

  let retention_days_default = 3
  let retention_days_ceiling = 30
  let max_bytes_default = 64 * 1024 * 1024
  let max_bytes_ceiling = 1024 * 1024 * 1024

  (** Maximum age for [<masc_root>/wire-capture] day files retained by the
      diagnostic MASC->OAS wire-capture harness. Default is 3 days. Range:
      [1, 30] days.

      @category Policies @ops_class operator *)
  let retention_days () =
    get_int_nonneg
      ~default:retention_days_default
      "MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS"
    |> clamp_int ~min_value:1 ~max_value:retention_days_ceiling
  ;;

  (** Maximum bytes for the active [<masc_root>/wire-capture/YYYY-MM/DD.jsonl]
      file and maximum total bytes retained below [<masc_root>/wire-capture]
      after opportunistic completed-day cleanup. Default is 64 MiB. Range:
      [1, 1024] MiB.

      @category Policies @ops_class operator *)
  let max_bytes () =
    get_int_nonneg ~default:max_bytes_default "MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES"
    |> clamp_int ~min_value:1 ~max_value:max_bytes_ceiling
  ;;
end

(** {1 Keeper Interesting Alert Configuration} *)

module KeeperAlert = struct
  (** Master switch for keeper interesting alert detection/fanout *)
  let enabled = Feature_flag_registry.get_bool "MASC_KEEPER_ALERT_ENABLED"

  (** Minimum score required to trigger alert fanout *)
  let min_score = get_float ~default:0.70 "MASC_KEEPER_ALERT_MIN_SCORE"

  (** Maximum alert body chars used for external fanout payloads *)
  let max_body_chars = get_int_nonneg ~default:1200 "MASC_KEEPER_ALERT_MAX_BODY_CHARS"

  (** Retry count for each fanout channel (in addition to initial attempt) *)
  let max_retries = get_int_nonneg ~default:2 "MASC_KEEPER_ALERT_MAX_RETRIES"

  (** Base retry delay in milliseconds (exponential backoff) *)
  let retry_base_delay_ms =
    get_int_nonneg ~default:250 "MASC_KEEPER_ALERT_RETRY_BASE_DELAY_MS"
  ;;

  (** Board fanout configuration *)
  let board_enabled = Feature_flag_registry.get_bool "MASC_KEEPER_ALERT_BOARD_ENABLED"

  let board_author =
    get_string ~default:"keeper-alert-bot" "MASC_KEEPER_ALERT_BOARD_AUTHOR"
  ;;

  let board_hearth = get_string ~default:"keeper-alert" "MASC_KEEPER_ALERT_BOARD_HEARTH"

  let board_visibility =
    get_string ~default:"internal" "MASC_KEEPER_ALERT_BOARD_VISIBILITY"
  ;;

  (** Slack fanout configuration *)
  let slack_enabled = Feature_flag_registry.get_bool "MASC_KEEPER_ALERT_SLACK_ENABLED"

  let slack_webhook_url = get_string ~default:"" "MASC_KEEPER_ALERT_SLACK_WEBHOOK_URL"

  (** Slack DM fanout configuration *)
  let slack_dm_enabled =
    Feature_flag_registry.get_bool "MASC_KEEPER_ALERT_SLACK_DM_ENABLED"
  ;;

  let slack_dm_user_id = get_string ~default:"" "MASC_KEEPER_ALERT_SLACK_DM_USER_ID"

  (** GitHub issue fanout configuration *)
  let github_enabled = Feature_flag_registry.get_bool "MASC_KEEPER_ALERT_GITHUB_ENABLED"

  let github_repo = get_string ~default:"" "MASC_KEEPER_ALERT_GITHUB_REPO"
  let github_label = get_string ~default:"keeper-alert" "MASC_KEEPER_ALERT_GITHUB_LABEL"
  let github_min_score = get_float ~default:0.85 "MASC_KEEPER_ALERT_GITHUB_MIN_SCORE"
end

(** {1 Keeper Supervisor Configuration} *)

module KeeperSupervisor = Env_config_keeper_supervisor

(** {1 Keeper Poll Intervals}

    Drain / poll cadences for keeper background fibers that have no
    natural event signal — they have to wake up periodically and check.
    Previously hardcoded as inline literals in the fiber loop body,
    making them invisible to the operator and impossible to tune
    without a rebuild. Operator-tunable cadence is a load-bearing
    config knob in production, not an implementation detail.

    Precedence: process env > hardcoded default below. *)

module KeeperPollIntervals = struct
  (** Crash persistence drain fiber wake interval in seconds.

      Drain fiber batches in-memory crash events and persists them
      to the dated jsonl store. Lower values reduce write batching
      (more, smaller writes); higher values risk losing the
      in-memory tail on a hard kill. Must be >= 0.1.
      Default: 2.0 — used at {!Keeper_crash_persistence}. *)
  let crash_persistence_drain_sec =
    Float.max 0.1 (get_float ~default:2.0 "MASC_KEEPER_CRASH_PERSIST_DRAIN_INTERVAL_SEC")
  ;;
end

(** {1 Keeper Runtime Configuration} *)

module KeeperRuntime = struct
  (** Enable keeper debug logging. Default: false. *)
  let debug = Feature_flag_registry.get_bool "MASC_KEEPER_DEBUG"

  (** Daily budget for keeper deliberation (USD). Default: 0.10.
      Re-readable within the process. Live operator control should use
      Runtime_params, not parent-shell env edits. *)
  let deliberation_daily_budget_usd () =
    get_float ~default:0.10 "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD"
  ;;

  (** Keeper keepalive snapshot interval, clamped to [15, 3600]. Default: 300. *)
  let snapshot_sec = max 15 (min 3600 (get_int ~default:300 "MASC_KEEPER_SNAPSHOT_SEC"))
end

(** {1 Keeper Memory OS Configuration}

    Memory OS readers use functions, not module-load constants, because tests and
    long-running processes may steer these kill switches with live env updates.
    Precedence still flows through {!Env_config_core.raw_value_opt}: process env,
    then the boot override store, then the hardcoded defaults below. *)

module KeeperMemoryOs = struct
  let get_int_logged = Env_config_memory.get_int_logged
  let get_float_positive_logged = Env_config_memory.get_float_positive_logged

  let recall_enabled_default = true
  let librarian_enabled_default = true
  let librarian_cadence_turns_default = 3
  let librarian_max_messages_default = 24
  let librarian_timeout_sec_default = 600.0
  let librarian_max_tokens_default = 4096
  let librarian_runtime_id_default = None
  let gc_enabled_default = true
  let shared_consolidator_enabled_default = false
  let consolidation_enabled_default = false
  let consolidation_runtime_id_default = None

  (* Env-key SSOT: the config-introspection registry
     (env_config_snapshot.ml memory_entries) and the tests reference these
     constants instead of re-spelling the literals, so a knob rename breaks
     compilation instead of silently drifting into a phantom registry entry. *)
  let recall_env_key = "MASC_KEEPER_MEMORY_OS_RECALL"
  let librarian_env_key = "MASC_KEEPER_MEMORY_OS_LIBRARIAN"
  let librarian_cadence_turns_env_key = "MASC_KEEPER_MEMORY_OS_LIBRARIAN_CADENCE_TURNS"
  let librarian_max_messages_env_key = "MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_MESSAGES"
  let librarian_timeout_sec_env_key = "MASC_KEEPER_MEMORY_OS_LIBRARIAN_TIMEOUT_SEC"
  let librarian_max_tokens_env_key = "MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_TOKENS"
  let librarian_runtime_id_env_key = "MASC_KEEPER_MEMORY_OS_LIBRARIAN_RUNTIME_ID"
  let gc_env_key = "MASC_KEEPER_MEMORY_OS_GC"
  let shared_consolidator_env_key = "MASC_KEEPER_MEMORY_OS_CONSOLIDATE"
  let consolidation_env_key = "MASC_KEEPER_MEMORY_OS_CONSOLIDATION"
  let consolidation_runtime_id_env_key = "MASC_KEEPER_MEMORY_OS_CONSOLIDATION_RUNTIME_ID"

  let optional_string_default value = Option.value value ~default:""
  ;;

  let float_default_to_display value = Printf.sprintf "%.1f" value ;;

  let get_bool_logged ?(invalid = Env_config_memory.Default) name ~default =
    Env_config_memory.get_bool_logged
      ~invalid
      name
      ~default
  ;;

  let nonempty_string value =
    let value = String.trim value in
    if String.equal value "" then None else Some value
  ;;

  (** Memory OS recall prompt injection kill switch. Default: true; invalid
      values fail closed to false so malformed operator input cannot leave the
      kill switch accidentally enabled.
      @category Policies
      @ops_class operator *)
  let recall_enabled () =
    get_bool_logged
      ~invalid:Env_config_memory.Fail_closed
      recall_env_key
      ~default:recall_enabled_default
  ;;

  (** Memory OS librarian post-turn extraction kill switch. Default: true;
      invalid values fail closed to false so malformed operator input cannot
      leave the kill switch accidentally enabled.
      @category Policies
      @ops_class operator *)
  let librarian_enabled () =
    get_bool_logged
      ~invalid:Env_config_memory.Fail_closed
      librarian_env_key
      ~default:librarian_enabled_default
  ;;

  (** Turns between librarian extraction attempts per keeper. Default: 3,
      floored to 1.
      @category Runtime
      @ops_class operator *)
  let librarian_cadence_turns () =
    max
      1
      (get_int_logged
         librarian_cadence_turns_env_key
         ~default:librarian_cadence_turns_default)
  ;;

  (** Base recent-message window for librarian extraction. Default: 24,
      floored to 1.
      @category Runtime
      @ops_class operator *)
  let librarian_max_messages () =
    max
      1
      (get_int_logged
         librarian_max_messages_env_key
         ~default:librarian_max_messages_default)
  ;;

  (** Provider timeout for librarian extraction. Default: 600 seconds; invalid,
      non-positive, NaN, or infinite values fall back to the default.
      @category Timeouts
      @ops_class operator *)
  let librarian_timeout_sec () =
    get_float_positive_logged
      librarian_timeout_sec_env_key
      ~default:librarian_timeout_sec_default
  ;;

  (** Output token cap for librarian extraction, applied as min with the
      provider max_tokens. Default: 4096, floored to 1.
      @category Runtime
      @ops_class operator *)
  let librarian_max_tokens () =
    max
      1
      (get_int_logged
         librarian_max_tokens_env_key
         ~default:librarian_max_tokens_default)
  ;;

  (** Optional runtime id override for librarian extraction.
      @category Runtime
      @ops_class operator *)
  let librarian_runtime_id () =
    get_string
      ~default:(optional_string_default librarian_runtime_id_default)
      librarian_runtime_id_env_key
    |> nonempty_string
  ;;

  (** Per-keeper Memory OS GC maintenance fiber kill switch. Default: true;
      invalid values fail closed to false. Env var acts as a kill switch to
      disable GC if a live dry-run shows it would prune the wrong rows.
      @category Storage
      @ops_class operator *)
  let gc_enabled () =
    get_bool_logged
      ~invalid:Env_config_memory.Fail_closed
      gc_env_key
      ~default:gc_enabled_default
  ;;

  (** Tier-2 shared Memory OS consolidator kill switch. Default: false; invalid
      values fail closed to false. This gates the deterministic cross-keeper
      shared-store sweep, separate from the per-keeper LLM consolidation pass.
      @category Policies
      @ops_class operator *)
  let shared_consolidator_enabled () =
    get_bool_logged
      ~invalid:Env_config_memory.Fail_closed
      shared_consolidator_env_key
      ~default:shared_consolidator_enabled_default
  ;;

  (** Per-keeper Memory OS consolidation maintenance fiber kill switch.
      Default: false; invalid values fail closed to false.
      @category Policies
      @ops_class operator *)
  let consolidation_enabled () =
    get_bool_logged
      ~invalid:Env_config_memory.Fail_closed
      consolidation_env_key
      ~default:consolidation_enabled_default
  ;;

  (** Optional runtime id override for Memory OS consolidation.
      @category Runtime
      @ops_class operator *)
  let consolidation_runtime_id () =
    get_string
      ~default:(optional_string_default consolidation_runtime_id_default)
      consolidation_runtime_id_env_key
    |> nonempty_string
  ;;
end

(** {1 Keeper dashboard compaction snapshots}

    Read-side bounds for the dashboard compaction snapshot inspector. These
    limits only cap filesystem hydration work and response size; they do not
    alter keeper compaction policy or reducer semantics.

    @category Runtime @ops_class operator *)
module KeeperCompactionSnapshots = struct
  (** Default item limit for [GET /keepers/:name/compaction-snapshots].
      Default: 25. @category Runtime @ops_class operator *)
  let default_limit =
    max 1 (get_int_nonneg ~default:25 "MASC_KEEPER_COMPACTION_SNAPSHOT_DEFAULT_LIMIT")
  ;;

  (** Maximum accepted item limit for the compaction snapshot endpoint.
      Default: 100. @category Runtime @ops_class operator *)
  let max_limit =
    max 1 (get_int_nonneg ~default:100 "MASC_KEEPER_COMPACTION_SNAPSHOT_MAX_LIMIT")
  ;;

  (** Minimum manifest files scanned before applying [limit * multiplier].
      Default: 8. @category Runtime @ops_class operator *)
  let manifest_scan_min_files =
    max
      1
      (get_int_nonneg
         ~default:8
         "MASC_KEEPER_COMPACTION_SNAPSHOT_MANIFEST_SCAN_MIN_FILES")
  ;;

  (** Multiplier from requested item limit to manifest files scanned.
      Default: 4. @category Runtime @ops_class operator *)
  let manifest_scan_limit_multiplier =
    max
      1
      (get_int_nonneg
         ~default:4
         "MASC_KEEPER_COMPACTION_SNAPSHOT_MANIFEST_SCAN_LIMIT_MULTIPLIER")
  ;;

  (** Tail line count read from each selected manifest file. Default: 200.
      @category Runtime @ops_class operator *)
  let manifest_tail_max_lines =
    max
      1
      (get_int_nonneg
         ~default:200
         "MASC_KEEPER_COMPACTION_SNAPSHOT_MANIFEST_TAIL_MAX_LINES")
  ;;
end

(** {1 Keeper Vision Tool Configuration} *)

module KeeperVision = struct
  let clamp_int ~min_value ~max_value value =
    max min_value (min max_value value)
  ;;

  let clamp_float ~min_value ~max_value value =
    Float.max min_value (Float.min max_value value)
  ;;

  let max_image_bytes_default = 5 * 1024 * 1024
  let max_image_bytes_ceiling = 10 * 1024 * 1024
  let candidate_backoff_base_sec_ceiling = 5.0
  let candidate_backoff_max_sec_ceiling = 30.0

  (** Maximum raw image bytes accepted by the one-shot vision tool before
      provider-message construction. Default is 5 MiB to match dashboard upload
      policy. Range: [1, 10 MiB], so base64 expansion still stays below the
      default HTTP body cap with headroom.

      @category Policies @ops_class operator *)
  let max_image_bytes () =
    get_int_nonneg ~default:max_image_bytes_default "MASC_KEEPER_VISION_MAX_IMAGE_BYTES"
    |> clamp_int ~min_value:1 ~max_value:max_image_bytes_ceiling
  ;;

  (** Base delay before trying the next vision runtime after a failed provider
      attempt. A small default avoids tight failover loops while keeping the tool
      responsive. Range: [0, 5] seconds; 0 disables inter-candidate delay.

      @category Timeouts @ops_class operator *)
  let candidate_backoff_base_sec () =
    get_float_nonneg ~default:0.05 "MASC_KEEPER_VISION_CANDIDATE_BACKOFF_BASE_SEC"
    |> clamp_float ~min_value:0.0 ~max_value:candidate_backoff_base_sec_ceiling
  ;;

  (** Upper bound for the per-candidate vision failover delay. Range: [base, 30]
      seconds, so a typo cannot exceed the tool's cumulative deadline policy.

      @category Timeouts @ops_class operator *)
  let candidate_backoff_max_sec () =
    let base = candidate_backoff_base_sec () in
    get_float_nonneg ~default:0.25 "MASC_KEEPER_VISION_CANDIDATE_BACKOFF_MAX_SEC"
    |> clamp_float ~min_value:0.0 ~max_value:candidate_backoff_max_sec_ceiling
    |> Float.max base
  ;;
end

(** {1 Keeper Generated Media Configuration} *)

module KeeperGeneratedMedia = struct
  let clamp_int ~min_value ~max_value value =
    max min_value (min max_value value)
  ;;

  let clamp_float ~min_value ~max_value value =
    Float.max min_value (Float.min max_value value)
  ;;

  let max_bytes_default = 10 * 1024 * 1024
  let max_bytes_ceiling = 50 * 1024 * 1024
  let dir_max_bytes_default = 500 * 1024 * 1024
  let dir_max_bytes_ceiling = 5 * 1024 * 1024 * 1024
  let retention_seconds_default = Masc_time_constants.day
  let retention_seconds_ceiling = Masc_time_constants.days_to_seconds 30

  (** Maximum raw generated-media bytes accepted by the durable store and serve
      route. Default is 10 MiB. Range: [1, 50 MiB].

      @category Policies @ops_class operator *)
  let max_bytes () =
    get_int_nonneg ~default:max_bytes_default "MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES"
    |> clamp_int ~min_value:1 ~max_value:max_bytes_ceiling
  ;;

  (** Maximum total bytes retained in [<masc_dir>/media] after opportunistic
      cleanup. Default is 500 MiB. Range: [1, 5 GiB].

      @category Policies @ops_class operator *)
  let dir_max_bytes () =
    get_int_nonneg
      ~default:dir_max_bytes_default
      "MASC_KEEPER_GENERATED_MEDIA_DIR_MAX_BYTES"
    |> clamp_int ~min_value:1 ~max_value:dir_max_bytes_ceiling
  ;;

  (** Maximum generated-media file age retained by opportunistic cleanup. Default
      is 24 hours. Range: [1 second, 30 days].

      @category Policies @ops_class operator *)
  let retention_seconds () =
    get_float_nonneg
      ~default:retention_seconds_default
      "MASC_KEEPER_GENERATED_MEDIA_RETENTION_SEC"
    |> clamp_float ~min_value:1.0 ~max_value:retention_seconds_ceiling
  ;;
end

(** {1 Keeper Context Reducer Configuration}

    Controls for the {!Agent_sdk.Context_reducer} stages applied to the
    keeper message history before each turn.  Extracted from a hardcoded
    literal (masc PR #xxxx) so the reducer cap can be tuned per
    deployment without a rebuild.  Default preserves the prior value. *)

module KeeperReducer = struct
  (** Max message tokens retained by
      {!Agent_sdk.Context_reducer.cap_message_tokens} in the keeper run
      reducer pipeline.  Default: 32000.  Minimum: 1024.

      Env: [MASC_KEEPER_REDUCER_CAP_TOKENS]. *)
  let cap_message_tokens =
    max 1024 (get_int ~default:32000 "MASC_KEEPER_REDUCER_CAP_TOKENS")
  ;;

  (** Recent messages kept verbatim by
      {!Agent_sdk.Context_reducer.cap_message_tokens}.  Default: 3.
      Range: [1, 20].

      Env: [MASC_KEEPER_REDUCER_KEEP_RECENT]. *)
  let cap_message_keep_recent =
    max 1 (min 20 (get_int ~default:3 "MASC_KEEPER_REDUCER_KEEP_RECENT"))
  ;;
end

(** {1 Alert Dedup Configuration} *)

module AlertDedup = struct
  (** Alert dedup window, clamped to >= 5s. Default: 60. *)
  let window_sec = Float.max 5.0 (get_float ~default:60.0 "MASC_ALERT_DEDUP_WINDOW_SEC")
end

(** Shared: keepalive interval, read early so WorkAsHeartbeat can reference it. *)
let keepalive_interval_sec_ =
  max 5 (min 300 (get_int ~default:30 "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC"))
;;

(** {1 Work-as-Heartbeat Configuration (Phase 1)} *)

module WorkAsHeartbeat = struct
  (** Master switch. When true, successful Workspace.heartbeat after a
      unified turn counts as presence proof, allowing the next cycle to skip
      the full ensure_keeper_workspace_presence call. *)
  let enabled = Feature_flag_registry.get_bool "MASC_KEEPER_WORK_AS_HEARTBEAT"

  (** Maximum seconds since last successful workspace heartbeat before presence
      sync is required again. Floor = keepalive interval (dynamic). *)
  let max_silence_sec =
    let floor = Float.of_int keepalive_interval_sec_ in
    Float.max floor (get_float ~default:120.0 "MASC_KEEPER_MAX_SILENCE_SEC")
  ;;
end

(** {1 Smart Heartbeat Configuration (Phase 2)} *)

module SmartHeartbeat = struct
  (** Master switch for adaptive heartbeat scheduling in the keepalive loop.
      When true, Keeper_heartbeat_smart.should_emit gates presence/snapshot/board/turn
      blocks, skipping cycles when the keeper is busy or deeply idle. *)
  let enabled = Feature_flag_registry.get_bool "MASC_KEEPER_SMART_HEARTBEAT"
end

module KeeperVisibilityGate = struct
  (** Consumer-driven idle backoff: when true, keepers with no dashboard/SSE
      observer and no pending signal delay proactive idle turns by
      [unobserved_visibility_idle_window_s] to reduce token waste. *)
  let enabled = Feature_flag_registry.get_bool "MASC_KEEPER_VISIBILITY_GATE"
end

(** {1 Keeper turn admission policy} *)

module KeeperTurnAdmission = struct
  (** Maximum chat requests allowed to park behind one keeper's admitted turn.
      Default preserves the previous per-keeper cap. Runtime operators may raise
      it for high-fan-in dashboard/connector deployments through
      [turn.chat_waiting_cap] in runtime.toml or the env var below. Floored at
      1 because [run_serialized] counts the caller before acquiring the slot.

      Env: [MASC_KEEPER_TURN_CHAT_WAITING_CAP].
      @category Concurrency @ops_class operator *)
  let max_waiting_chat_requests =
    max 1 (get_int ~default:8 "MASC_KEEPER_TURN_CHAT_WAITING_CAP")
  ;;
end

(** {1 Keeper health policy} *)

module KeeperHealth = struct
  (** Durable event-queue backlog age threshold for fleet health degradation.
      The durable queue remains fully reported regardless of this value; this
      policy only decides when backlog should flip [/health?full=1] from
      informational to operator-actionable. Default [0.0] preserves the
      existing behavior where any durable backlog is immediately visible as
      degraded. Operators may raise it to avoid treating fresh, expected queue
      handoff as degraded.

      Env: [MASC_KEEPER_DURABLE_QUEUE_STALE_SEC].
      @category Telemetry @ops_class operator *)
  let durable_queue_stale_sec () =
    get_float_nonneg ~default:0.0 "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC"
  ;;
end

(** {1 Keeper proactive scheduler policy} *)

module KeeperProactivePolicy = struct
  (** Maximum exponent used by no-op cooldown backoff:
      [base_cooldown * (1 lsl min consecutive_noop_count value)].
      Default [2] preserves the previous maximum 4x cooldown. Range [0, 8]
      keeps the policy bounded while allowing operators to disable or relax
      no-op backoff.

      Env: [MASC_KEEPER_PROACTIVE_NOOP_BACKOFF_MAX_SHIFT].
      @category Timeouts @ops_class operator *)
  let noop_backoff_max_shift =
    min 8 (get_int_nonneg ~default:2 "MASC_KEEPER_PROACTIVE_NOOP_BACKOFF_MAX_SHIFT")
  ;;

  (** Maximum idle-decay periods applied after a keeper has been idle longer
      than its effective proactive base cooldown. Default [4] preserves the
      previous floor-reaching behavior. Range [0, 16] prevents an accidental
      hot loop while still making the policy explicit.

      Env: [MASC_KEEPER_PROACTIVE_IDLE_DECAY_MAX_PERIODS].
      @category Timeouts @ops_class operator *)
  let idle_decay_max_periods =
    min 16 (get_int_nonneg ~default:4 "MASC_KEEPER_PROACTIVE_IDLE_DECAY_MAX_PERIODS")
  ;;
end

(** {1 Keeper Keepalive Loop Constants} *)

module KeeperKeepalive = struct
  (** Heartbeat cycle interval in seconds. Default: 30.
      Range: [5, 300]. This is the foundational timing constant — every
      keeper cycle (presence, snapshot, board scan, turn, recurring) runs
      at this cadence. *)
  let interval_sec = keepalive_interval_sec_

  (** Maximum consecutive heartbeat failures before raising
      Keeper_fiber_crash (structured crash via dispatch_event). Default: 5.
      Range: [2, 50]. *)
  let max_consecutive_failures =
    max 2 (min 50 (get_int ~default:5 "MASC_KEEPER_MAX_CONSECUTIVE_HB_FAILURES"))
  ;;

  (** Maximum consecutive unified turn failures before marking keeper as
      crashed. Covers LLM timeout, rate limit, and other turn errors.
      Default: 10. Range: [3, 100]. *)
  let max_consecutive_turn_failures =
    max 3 (min 100 (get_int ~default:10 "MASC_KEEPER_MAX_CONSECUTIVE_TURN_FAILURES"))
  ;;

  (** Board-reactive wakeup debounce in seconds. Prevents rapid repeated
      wakeups from the same board post. Default: 60.0.
      Range: [5, 300]. *)

  (** Interruptible sleep chunk size in seconds. Smaller = faster wakeup
      response but more CPU polling. Default: 2.0.
      Range: [0.1, 10.0]. *)
  let sleep_chunk_sec =
    Float.max 0.1 (Float.min 10.0 (get_float ~default:2.0 "MASC_KEEPER_SLEEP_CHUNK_SEC"))
  ;;

  (** Jitter factor applied to heartbeat interval (fraction of base).
      Default: 0.2 (20%). Range: [0.0, 0.5]. *)
  let jitter_factor =
    Float.max
      0.0
      (Float.min 0.5 (get_float ~default:0.2 "MASC_KEEPER_HEARTBEAT_JITTER_FACTOR"))
  ;;

  (** {2 Idle Turn Constants}

      Keepers may call tools or finish with text. Idle detection only
      fires when the same tool+args pattern repeats. Higher thresholds
      allow legitimate multi-step exploration (e.g., calling
      keeper_tool_search with different queries). *)

  (** Max idle turns for scheduled autonomous keeper turns.
      Keepers have workspace to explore multi-step tool sequences.
      10 idle turns × ~5K tokens = ~50K budget.
      Env: [MASC_KEEPER_MAX_IDLE_TURNS_AUTONOMOUS]. Default: 10. *)
  let max_idle_turns_autonomous =
    max 2 (min 50 (get_int ~default:10 "MASC_KEEPER_MAX_IDLE_TURNS_AUTONOMOUS"))
  ;;

  (** Max idle turns for reactive (board/mention triggered) keeper turns.
      Reactive turns have an explicit trigger — more patience warranted.
      Env: [MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE]. Default: 15. *)
  let max_idle_turns_reactive =
    max 2 (min 50 (get_int ~default:15 "MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE"))
  ;;

  (** Hard ceiling for all keeper timeout constants (seconds).
      No timeout may exceed this value regardless of env override.

      Default: 900 (15 minutes), lifted from 600 in PR #13861's
      RFC-0012/0022 update permitting per-runtime turn_timeout_sec
      overrides. Local-LLM runtimes that legitimately run 27 B turns
      ≥600 s can now opt in via env or the upcoming runtime.toml
      override; remote runtimes stay at the global default 600.

      Promotion above 900 s requires a follow-up RFC plus one week of
      retry-admission and p95 duration data — see RFC-0012 §Out of scope. *)
  let timeout_hard_ceiling_sec = 900.0

  (** Retry/admission budget in seconds for a single unified turn (including all
      retries and runtime fallbacks). This value no longer kills an active turn
      solely because cumulative wall-clock elapsed.
      Env: [MASC_KEEPER_TURN_TIMEOUT_SEC]. Default: 600. Range: [60, 900].

      The default stays at 600 (the prior hard ceiling) so existing
      remote runtimes keep their budget unchanged; the lifted ceiling
      only fires when an operator opts in via env or runtime override.
      Active-runaway detection is driven by [stream_idle_timeout_sec],
      provider-attempt liveness, tool timeouts, OAS max-turn limits, HTTP error,
      and the optional supervisor stale-turn watchdog. *)
  let turn_timeout_sec =
    Float.max
      60.0
      (Float.min
         timeout_hard_ceiling_sec
         (get_float ~default:600.0 "MASC_KEEPER_TURN_TIMEOUT_SEC"))
  ;;


  (** Per-call OAS timeout override in seconds.

      Legacy/env override value is clamped to the active keepalive
      retry/admission budget. The override is still parsed for observability
      and to preserve compatibility with existing profiles, but it is not
      guaranteed to represent a distinct timeout policy anymore.

      Env: [MASC_KEEPER_OAS_TIMEOUT_SEC]. Default: none.
      Range (when set): [30, turn_timeout_sec]. *)
  let oas_timeout_sec_override =
    match Env_config_core.raw_value_opt "MASC_KEEPER_OAS_TIMEOUT_SEC" with
    | Some raw ->
      (* DET-OK: timeout override parsing is config-boundary behavior. Unknown/invalid env
         values intentionally disable override (fallback to baseline policy). *)
      (match Float.of_string_opt (String.trim raw) with
       | Some parsed ->
         Some (Float.max 30.0 (Float.min parsed turn_timeout_sec))
       | None -> None)
    | None -> None
  ;;

  (* RFC-0156/RFC-020x: OAS total timeout removed. Resolved OAS-call budget =
     override when set, else turn_timeout_sec. stream_idle_timeout handles
     per-stream idle; runtime rotation triggers on stream_idle + HTTP error +
     completion contract. Historic names
     ([oas_timeout_for_estimated_input_tokens] /
     [oas_timeout_for_estimated_input_tokens_with_turn_budget]) ignored the
     [estimated_input_tokens] and [max_turns] args — function-name-lying. *)
  let oas_call_timeout_sec : float =
    match oas_timeout_sec_override with
    | Some v -> v
    | None -> turn_timeout_sec
  ;;

  (** Deprecated compatibility knob for the removed whole-run attempt watchdog.

      The keeper runtime must not apply this as a wall-clock timeout around
      active provider/tool execution. Real liveness policy must live at a
      narrower boundary: admission/queue wait, provider connect/stream progress,
      or tool-local policy owned by the tool substrate.

      Env: [MASC_KEEPER_ATTEMPT_WATCHDOG_SAFETY_CAP_SEC].
      Default: 1800 (30 min). Range: [300, 7200]. *)
  let attempt_watchdog_safety_cap_sec =
    Float.max
      300.0
      (Float.min
         7200.0
         (get_float ~default:1800.0
            "MASC_KEEPER_ATTEMPT_WATCHDOG_SAFETY_CAP_SEC"))
  ;;

  (** Idle-gap timeout for streaming OAS provider responses.
      This bounds time between streamed lines, not total turn duration.
      Env: [MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC]. Default: 120. Range: [5, 600]. *)
  let stream_idle_timeout_sec =
    Float.max
      5.0
      (Float.min 600.0 (get_float ~default:120.0 "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC"))
  ;;

  (** OAS Agent.run inactivity deadline.

      This is progress-based rather than cumulative wall-clock: OAS resets the
      timer when the run emits progress. It complements
      [stream_idle_timeout_sec], which watches transport line gaps; this knob
      catches Agent-level no-progress stalls that still keep a transport
      connection superficially alive.

      The keeper path parses this knob but does not forward it until OAS proves
      active tool execution is excluded from idle accounting.

      Env: [MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC]. Default: disabled.
      Range when enabled: [5, 600]. Unset, invalid, [0], or a negative
      value disables it. This stays opt-in because it is an Agent.run-level
      stall detector, not provider transport policy or tool timeout policy.
      @category Timeouts
      @ops_class operator *)
  let execution_idle_timeout_sec =
    match Env_config_core.raw_value_opt "MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC" with
    | None -> None
    | Some _ ->
      let value = get_float ~default:0.0 "MASC_KEEPER_EXECUTION_IDLE_TIMEOUT_SEC" in
      if (not (Float.is_finite value)) || value <= 0.0
      then None
      else Some (Float.max 5.0 (Float.min 600.0 value))
  ;;

  (** Total HTTP body-consumption deadline for non-streaming OAS completion
      calls. In agent_sdk this wraps [Complete.complete]'s synchronous HTTP
      body read; streaming calls deliberately ignore the knob so active
      long streams are not killed by total duration. Streaming liveness is
      handled by [stream_idle_timeout_sec] and the attempt liveness observer.

      Opt-in: unset env leaves [None] so {!Runtime_agent_context} skips
      the builder wiring. Set only for sync completion callers that need a
      body-read ceiling before the outer turn cap.

      Env: [MASC_KEEPER_BODY_TIMEOUT_SEC]. Default: unset → [None].
      Range when set: [10, 600]. *)
  let body_timeout_sec_override =
    match Env_config_core.raw_value_opt "MASC_KEEPER_BODY_TIMEOUT_SEC" with
    | Some raw ->
      (match Float.of_string_opt (String.trim raw) with
       | Some v -> Some (Float.max 10.0 (Float.min 600.0 v))
       | None -> None)
    | None -> None
  ;;

  (** Stdout-idle timeout for CLI subprocess transports (Anthropic CLI today;
      other CLI providers need an OAS upstream change to expose
      [stdout_idle_timeout_s] in their transport configs).
      The CLI subprocess is aborted via SIGINT if no stdout line arrives
      within this many seconds. Read fresh per-turn via
      {!Keeper_runtime_resolved.cli_subprocess_idle_sec}.
      Env: [MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC]. Default: 120. Range: [10, 600].
      @category Timeouts
      @ops_class operator *)
  let cli_subprocess_idle_sec =
    Float.max
      10.0
      (Float.min 600.0 (get_float ~default:120.0 "MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC"))
  ;;

end

(** {1 gRPC Heartbeat Reconnect} *)

module KeeperGrpc = struct
  (** Maximum gRPC reconnect attempts before stopping the heartbeat fiber.
      Default: 5. Range: [1, 20]. *)
  let max_reconnect_attempts =
    max 1 (min 20 (get_int ~default:5 "MASC_KEEPER_GRPC_MAX_RECONNECT"))
  ;;

  (** Backoff delay between gRPC reconnect attempts in seconds.
      Default: 5.0. Range: [1.0, 60.0]. *)
  let reconnect_backoff_sec =
    Float.max
      1.0
      (Float.min 60.0 (get_float ~default:5.0 "MASC_KEEPER_GRPC_RECONNECT_BACKOFF_SEC"))
  ;;
end

(** {1 Proactive Generation} *)

module KeeperProactive = struct
  (** Maximum proactive generation attempts before falling back.
      Default: 3. Range: [1, 10]. *)
  let max_attempts =
    max 1 (min 10 (get_int ~default:3 "MASC_KEEPER_PROACTIVE_MAX_ATTEMPTS"))
  ;;

  (** Stage timing ring buffer size for Phase 0 profiling.
      Default: 100. Range: [10, 1000]. *)
  let stage_timing_ring_size =
    max 10 (min 1000 (get_int ~default:100 "MASC_KEEPER_STAGE_TIMING_RING_SIZE"))
  ;;
end

(** {1 Tool Execution} *)

module KeeperToolExec = struct
  (** Maximum consecutive failures for the same (tool_name, args_hash)
      before blocking further attempts. Prevents infinite retry loops.
      Default: 3. Range: [2, 20]. *)
  let max_consecutive_tool_failures =
    max 2 (min 20 (get_int ~default:3 "MASC_KEEPER_MAX_CONSECUTIVE_TOOL_FAILURES"))
  ;;
end

(** {1 Context Ratio Hard Cap}

    Absolute ceiling for compaction ratio_gate and handoff threshold after
    multiplier adjustment.  Prevents runaway values from disabling
    compaction/handoff.  Default: 0.95. Range: [0.80, 0.99]. *)

let context_ratio_hard_cap =
  Float.max 0.80 (Float.min 0.99 (get_float ~default:0.95 "MASC_CONTEXT_RATIO_HARD_CAP"))
;;

(** {1 Context Compaction (OAS)} *)

module ContextCompact = struct
  (** Algorithm calibration constants for the MASC-side compaction scorer and
      dynamic strategy selector.  These are intentionally not runtime env
      knobs: changing them alters reducer semantics and should go through code
      review with coverage instead of per-host tuning. *)
  let w_recency = 0.50
  let w_role = 0.35
  let w_tool = 0.15
  let role_system = 1.0
  let role_tool = 0.7
  let role_user = 0.6
  let role_assistant = 0.4
  let tool_present = 0.8
  let tool_absent = 0.5
  let anchor_boost = 0.95
  let drop_importance_threshold = 0.3
  let summarize_keep_recent = 5
  let tool_output_prune_limit = 1500
  let dynamic_multi_agent_ratio = 0.80
  let dynamic_focused_ratio = 0.70
  let small_local_floor = 64_000
  let large_cloud_floor = 500_000
end

(** {1 Dashboard Health Thresholds}

    Thresholds used by the dashboard keeper health scorer and harness health
    panels.  Distinct from compaction triggers — these affect UI display only. *)

module DashboardHealth = struct
  let ctx_critical = get_float ~default:0.9 "MASC_DASHBOARD_HEALTH_CTX_CRITICAL"
  let ctx_warn = get_float ~default:0.8 "MASC_DASHBOARD_HEALTH_CTX_WARN"
  let penalty_critical = get_float ~default:20.0 "MASC_DASHBOARD_HEALTH_PENALTY_CRITICAL"
  let penalty_warn = get_float ~default:10.0 "MASC_DASHBOARD_HEALTH_PENALTY_WARN"

  let runtime_warning_ctx_ratio =
    get_float ~default:0.95 "MASC_DASHBOARD_RUNTIME_WARNING_CTX_RATIO"
  ;;
end

(** {1 Wake-time Payload Telemetry}

    Phase 0 observability for the tiered-hydration redesign (Option C).
    When enabled, every keeper wake captures an approximation of the LLM
    request payload size just before [Keeper_turn_driver.run_named] is invoked.
    The record is appended to
    [$MASC_BASE_PATH/data/keeper-wake-payload/YYYY-MM-DD.jsonl] via
    [Dashboard_harness_health.record_wake_payload].

    Cost when disabled: a single env var lookup (bool). The entire
    measurement path is gated behind [payload_telemetry_enabled]. *)
module KeeperTelemetry = struct
  (** Master switch for wake-payload measurement. Default off so the hot
      path is untouched until a baseline sweep is explicitly requested. *)
  let payload_telemetry_enabled () = get_bool ~default:false "MASC_PAYLOAD_TELEMETRY"
end

(** {1 Runtime Saturation Signal (RFC-0153 Phase A.2)}

    Feature flag for typed [Runtime_saturation_signal.t] emission from
    structured runtime/provider errors. The signal is consumed by Phase C
    (adaptive throttling).

    Default off. Phase A.2 emit is purely additive — it increments a new
    Otel_metric_store counter ([masc_keeper_runtime_saturation_signal_total])
    with a typed [kind] label sourced from {!Runtime_saturation_signal.kind}. *)
module RuntimeSaturationSignal = struct
  let enabled () =
    get_bool ~default:false "MASC_RUNTIME_SATURATION_SIGNAL_ENABLED"
end

(* MASC_KEEPER_RUNTIME_PROVIDER_ALLOWLIST (KeeperRuntimeProviderFilter) was
   deleted (audit F8): its value was threaded as [?provider_filter] into
   [Keeper_turn_driver.run_named] and [Keeper_memory_llm_summary.make], both of
   which silently ignored it after the RFC-0206 single-runtime purge. The knob
   was dead while its docs were live; deletion documents reality. Provider
   selection is runtime.toml SSOT ([runtime].default / [[runtime.assignments]]). *)

(** {1 Transient Retry Backoff}

    Outer-loop retry parameters for transient network errors and
    recoverable runtime failures.  These govern the keeper's exponential
    backoff between re-attempts when all OAS providers fail transiently
    (e.g. TCP keepalive expiry).  They do NOT affect OAS internal
    per-provider retry (3 attempts with its own backoff). *)
module KeeperRetryBackoff = Env_config_keeper_retry_backoff

(** Print configuration summary for debugging *)
