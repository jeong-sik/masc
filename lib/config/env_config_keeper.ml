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
  let librarian_global_slot_default = 1
  let gc_enabled_default = true
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
  let librarian_global_slot_env_key = "MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT"
  let gc_env_key = "MASC_KEEPER_MEMORY_OS_GC"
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

  (** Fleet-wide concurrency gate for librarian provider calls. Default: 1; 0
      disables the gate.
      @category Concurrency
      @ops_class operator *)
  let librarian_global_slot () =
    max
      0
      (get_int_logged
         librarian_global_slot_env_key
         ~default:librarian_global_slot_default)
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

(** {1 Keeper Keepalive Loop Constants} *)

module KeeperKeepalive = struct
  (** Heartbeat cycle interval in seconds. Default: 30.
      Range: [5, 300]. This is the foundational timing constant — every
      keeper cycle (presence, snapshot, board scan, turn, recurring) runs
      at this cadence. *)
  let interval_sec = keepalive_interval_sec_

  (** Board-reactive wakeup debounce in seconds. Prevents rapid repeated
      wakeups from the same board post. Default: 60.0.
      Range: [5, 300]. *)

  (** Interruptible sleep chunk size in seconds. Smaller = faster wakeup
      response but more CPU polling. Default: 2.0.
      Range: [0.1, 10.0]. *)
  let sleep_chunk_sec =
    Float.max 0.1 (Float.min 10.0 (get_float ~default:2.0 "MASC_KEEPER_SLEEP_CHUNK_SEC"))
  ;;

  let parse_stream_idle_timeout_sec raw =
    match Float.of_string_opt (String.trim raw) with
    | Some seconds when Float.is_finite seconds && Float.compare seconds 0.0 > 0 ->
      Ok seconds
    | Some _ | None ->
      Error "expected a finite, positive number of seconds"
  ;;

  let stream_idle_timeout_env_key = "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC"

  (** Explicit idle-gap timeout for streaming OAS provider responses.
      This bounds time between streamed lines, not total turn duration.
      Unset means disabled: MASC and OAS must not synthesize a provider/model
      default.  A configured value must be finite and strictly positive;
      malformed values are operator configuration errors, never a fallback.

      Env: [MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC]. Default: unset -> [None].
      @category Timeouts @ops_class operator *)
  let stream_idle_timeout_sec () =
    match Env_config_core.raw_value_opt stream_idle_timeout_env_key with
    | None -> None
    | Some raw ->
      (match parse_stream_idle_timeout_sec raw with
       | Ok seconds -> Some seconds
       | Error detail ->
         raise
           (Env_config_core.Config_error
              (Printf.sprintf
                 "invalid %s=%S (%s)"
                 stream_idle_timeout_env_key
                 raw
                 detail)))
  ;;

  (** Total HTTP body-consumption deadline for non-streaming OAS completion
      calls. In agent_sdk this wraps [Complete.complete]'s synchronous HTTP
      body read; streaming calls deliberately ignore the knob so active
      long streams are not killed by total duration. Streaming liveness is
      handled by an explicitly configured [stream_idle_timeout_sec] and the
      attempt liveness observer.

      Opt-in: unset env leaves [None] so {!Runtime_agent_context} skips
      the builder wiring. Set only for sync completion callers that need a
      body-read ceiling.

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

(** {1 Context Ratio Hard Cap}

    Absolute ceiling for compaction ratio_gate and handoff threshold after
    multiplier adjustment.  Prevents runaway values from disabling
    compaction/handoff.  Default: 0.95. Range: [0.80, 0.99]. *)

let context_ratio_hard_cap =
  Float.max 0.80 (Float.min 0.99 (get_float ~default:0.95 "MASC_CONTEXT_RATIO_HARD_CAP"))
;;

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

(* MASC_KEEPER_RUNTIME_PROVIDER_ALLOWLIST (KeeperRuntimeProviderFilter) was
   deleted (audit F8): its value was threaded as [?provider_filter] into
   [Keeper_turn_driver.run_named] and [Keeper_memory_llm_summary.make], both of
   which silently ignored it after the RFC-0206 single-runtime purge. The knob
   was dead while its docs were live; deletion documents reality. Provider
   selection is runtime.toml SSOT ([runtime].default / [[runtime.assignments]]). *)

(** Print configuration summary for debugging *)
