(** Env_config_keeper — keeper runtime parameters from environment.

    All [MASC_KEEPER_*] env vars in this module can also be set
    declaratively in [<resolved config root>/keeper_runtime.toml].
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
    without a rebuild. Same fragmentation class as the watchdog
    thresholds extracted in {!KeeperWatchdog} (#10740): operator-tunable
    cadence is a load-bearing config knob in production, not an
    implementation detail.

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

  (** Autonomous-turn semaphore queue poll interval in seconds.

      Polled inside the autonomous-turn admission loop in
      {!Keeper_keepalive}. Lower values reduce ticket-grant latency
      under contention; higher values lower idle CPU.
      Must be >= 0.001 (1ms floor — anything tighter is busy-loop).
      Default: 0.05. *)
  let autonomous_queue_poll_sec =
    Float.max 0.001 (get_float ~default:0.05 "MASC_KEEPER_AUTONOMOUS_QUEUE_POLL_SEC")
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

(** {1 Keeper Context Reducer Configuration}

    Controls for the {!Agent_sdk.Context_reducer} stages applied to the
    keeper message history before each turn.  Extracted from a hardcoded
    literal (masc-mcp PR #xxxx) so the reducer cap can be tuned per
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
  (** Master switch. When true, successful Coord.heartbeat after a
      unified turn counts as presence proof, allowing the next cycle to skip
      the full ensure_keeper_room_presence call. *)
  let enabled = Feature_flag_registry.get_bool "MASC_KEEPER_WORK_AS_HEARTBEAT"

  (** Maximum seconds since last successful room heartbeat before presence
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
  let board_debounce_sec =
    Float.max
      5.0
      (Float.min 300.0 (get_float ~default:60.0 "MASC_KEEPER_BOARD_DEBOUNCE_SEC"))
  ;;

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

      With tool_choice=Any, keepers always call tools.  Idle detection
      now only fires when the same tool+args pattern repeats.  Higher
      thresholds allow legitimate multi-step exploration (e.g., calling
      keeper_tool_search with different queries). *)

  (** Max idle turns for scheduled autonomous keeper turns.
      With tool_choice=Any and max_turns=50, keepers have room to
      explore.  10 idle turns × ~5K tokens = ~50K budget.
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
      RFC-0012/0022 update permitting per-cascade turn_timeout_sec
      overrides. Local-LLM cascades that legitimately run 27 B turns
      ≥600 s can now opt in via env or the upcoming cascade.toml
      override; remote cascades stay at the global default 600.

      Promotion to 1 800 s requires a follow-up RFC plus one week of
      [masc_keeper_turns_total{terminated_by="turn_timeout"}] and p95
      duration data — see RFC-0012 §Out of scope. *)
  let timeout_hard_ceiling_sec = 900.0

  (** Wall-clock timeout in seconds for a single unified turn (including all
      retries and cascade fallbacks). Prevents indefinite blocking when an
      upstream LLM hangs at the TCP level.
      Env: [MASC_KEEPER_TURN_TIMEOUT_SEC]. Default: 600. Range: [60, 900].

      The default stays at 600 (the prior hard ceiling) so existing
      remote cascades keep their budget unchanged; the lifted ceiling
      only fires when an operator opts in via env or cascade override.
      RFC-0156: post-removal there is no per-provider OAS cap layered
      below this — [oas_call_timeout_sec] reuses [turn_timeout_sec]
      directly; cascade rotation is driven by [stream_idle_timeout_sec]
      + HTTP error + completion contract. *)
  let turn_timeout_sec =
    Float.max
      60.0
      (Float.min
         timeout_hard_ceiling_sec
         (get_float ~default:600.0 "MASC_KEEPER_TURN_TIMEOUT_SEC"))
  ;;

  (** Maximum time a proactive keeper will wait in the MASC admission queue
      before abandoning the current OAS attempt.

      With admission max_concurrent=1 (MLX decode serial), a keeper may wait
      for the full duration of the preceding keeper's turn. Observed turn
      durations: 180-963s. Default 180s covers the common case (GLM cascade
      completes in ~180s) while avoiding indefinite waits.

      Env: [MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC]. Default: 180.0.
      Range: [5, 1200]. *)
  let admission_wait_timeout_sec =
    Float.max
      5.0
      (Float.min
         1200.0
         (get_float ~default:180.0 "MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC"))
  ;;

  (** Maximum time a scheduled autonomous keeper will wait for the local
      keeper turn gate before skipping the cycle. Reactive turns still wait
      indefinitely because they correspond to explicit external triggers.
      Env: [MASC_KEEPER_AUTONOMOUS_SLOT_WAIT_TIMEOUT_SEC]. Default: 30.0.
      Range: [5, 300]. *)
  let autonomous_slot_wait_timeout_sec =
    Float.max
      5.0
      (Float.min
         300.0
         (get_float ~default:30.0 "MASC_KEEPER_AUTONOMOUS_SLOT_WAIT_TIMEOUT_SEC"))
  ;;

  (** Per-call OAS timeout override in seconds.

      Legacy/env override value is clamped to the active keepalive
      wall-clock cap so this does not extend a single attempt beyond the
      keeper turn budget. The override is still parsed for observability
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

  (** Maximum turns per single OAS Agent.run call.
      Keeper resumes via checkpoint in the next keepalive cycle when
      {!Cascade_runner.TurnBudgetExhausted} is returned.
      Previous default of 200 caused "ambiguous partial commit" errors:
      the 300s timeout would fire mid-turn after tools had already executed,
      leaving the keeper in an ambiguous state. With 30 turns per call and
      adaptive timeout, each turn gets a realistic time budget. Budget=5
      was too low: mutation boundary blocks tools after the first write,
      leaving only 1 productive action per cycle.
      Env: [MASC_KEEPER_OAS_MAX_TURNS_PER_CALL]. Default: 30. Range: [1, 100]. *)
  let oas_max_turns_per_call =
    max 1 (min 100 (get_int ~default:30 "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL"))
  ;;

  (** Smaller turn budget for scheduled autonomous cycles so one keeper does
      not monopolize the autonomous semaphore for minutes at a time.
      Reactive turns keep the general budget because they correspond to
      explicit external stimuli.

      Default raised to 10 after Docker oas_env propagation was restored so
      autonomous keepers can complete deeper handoff tasks without relying on
      per-profile overrides.
      Reactive turns retain the larger budget.

      Env: [MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS].
      Default: min(global, 10). Range: [1, global]. *)
  let oas_max_turns_per_call_scheduled_autonomous =
    let default = min oas_max_turns_per_call 10 in
    max
      1
      (min
         oas_max_turns_per_call
         (min
            100
            (get_int ~default "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS")))
  ;;

  (* RFC-0156: OAS total timeout removed. Resolved OAS-call timeout = override
     when set, else turn_timeout_sec (wall-clock cap). stream_idle_timeout
     handles per-stream cap; cascade rotation triggers on stream_idle + HTTP
     error + completion contract. Historic names
     ([oas_timeout_for_estimated_input_tokens] /
     [oas_timeout_for_estimated_input_tokens_with_turn_budget]) ignored the
     [estimated_input_tokens] and [max_turns] args — function-name-lying. *)
  let oas_call_timeout_sec : float =
    match oas_timeout_sec_override with
    | Some v -> v
    | None -> turn_timeout_sec
  ;;

  (** Idle-gap timeout for streaming OAS provider responses.
      This bounds time between streamed lines, not total turn duration.
      Env: [MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC]. Default: 120. Range: [5, 600]. *)
  let stream_idle_timeout_sec =
    Float.max
      5.0
      (Float.min 600.0 (get_float ~default:120.0 "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC"))
  ;;

  (** Total HTTP body-consumption deadline for one OAS streaming call.
      Wraps the body callback in [Eio.Time.with_timeout_exn] in agent_sdk;
      on expiry [Retry.Timeout] surfaces and cascade falls forward to the
      next provider at the attempt boundary. Complements
      [stream_idle_timeout_sec] (which only caps inter-line silence):
      this catches the case where a single bulk read hangs without
      producing line breaks.

      Opt-in: unset env leaves [None] so {!Cascade_agent_context} skips
      the builder wiring. Set to a value strictly less than the effective
      OAS attempt cap for attempt-level fall-forward; set
      [<= stream_idle_timeout_sec] for a strict overall cap.

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

  (** Stdout-idle timeout for CLI subprocess transports (Provider_c CLI today;
      Claude Code / Provider_f CLI / Codex CLI need an OAS upstream change to
      expose [stdout_idle_timeout_s] in their transport configs).
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

  (** Consecutive idle tool repetitions before on_idle hook issues Skip.
      Below this: graduated Nudge messages.
      With tool_choice=Any, the model always calls tools, so idle
      detection triggers on repeated tool calls.  4 catches loops
      quickly while still allowing legitimate exploration.
      Env: [MASC_KEEPER_IDLE_SKIP_THRESHOLD]. Default: 4. *)
  let idle_skip_threshold =
    max 2 (min 20 (get_int ~default:4 "MASC_KEEPER_IDLE_SKIP_THRESHOLD"))
  ;;
end

(** {1 Keeper Watchdog Configuration}

    Thresholds for the stale-turn watchdog fiber
    ({!Keeper_stale_watchdog}). Previously hardcoded; extracted so
    operators can tune per deployment without a rebuild.

    Precedence: process env > hardcoded default below. *)

module KeeperWatchdog = struct
  (** Seconds since last turn before a Running keeper is considered idle-stale.
      Must be >= 60. Default: 300 (5 minutes).

      Invariant: [stale_threshold_sec] must not exceed [turn_timeout_sec].
      If the operator overrides push it above the turn cap, we clamp and log
      a warning so the watchdog does not declare a keeper stale later than
      the turn itself could possibly run. *)
  let stale_threshold_sec =
    let raw =
      Float.max 60.0 (get_float ~default:300.0 "MASC_KEEPER_WATCHDOG_STALE_SEC")
    in
    if raw > KeeperKeepalive.turn_timeout_sec
    then (
      Log.warn
        "MASC_KEEPER_WATCHDOG_STALE_SEC (%.1f) exceeds turn_timeout_sec (%.1f); clamping \
         to turn_timeout_sec"
        raw
        KeeperKeepalive.turn_timeout_sec;
      KeeperKeepalive.turn_timeout_sec)
    else raw
  ;;

  (** Seconds since the last in-turn progress signal before an active turn is
      considered mid-turn-stale. Default: 300 (5 minutes).

      This is intentionally separate from [stale_threshold_sec] (idle keepers)
      and [turn_timeout_sec] (outer wall clock). It catches no-first-token and
      inter-chunk-idle stalls while preserving the larger total turn budget for
      turns that continue to make progress.

      @category Timeouts
      @ops_class operator *)
  let progress_timeout_sec =
    let raw =
      Float.max 60.0 (get_float ~default:300.0 "MASC_KEEPER_WATCHDOG_PROGRESS_SEC")
    in
    if raw > KeeperKeepalive.turn_timeout_sec
    then (
      Log.warn
        "MASC_KEEPER_WATCHDOG_PROGRESS_SEC (%.1f) exceeds turn_timeout_sec (%.1f); \
         clamping to turn_timeout_sec"
        raw
        KeeperKeepalive.turn_timeout_sec;
      KeeperKeepalive.turn_timeout_sec)
    else raw
  ;;

  (** Watchdog poll interval in seconds. Must be >= 5.
      Default: 30. *)
  let poll_sec = Float.max 5.0 (get_float ~default:30.0 "MASC_KEEPER_WATCHDOG_POLL_SEC")

  (** Consecutive noop turns before considering the keeper stuck in a
      failure loop. Must be >= 2. Default: 3. *)
  let noop_threshold = max 2 (get_int ~default:3 "MASC_KEEPER_WATCHDOG_NOOP_THRESHOLD")

  (** Grace period after fiber start before idle-stale detection activates.
      Prevents false positives on server restart when [last_turn_ts] is
      carried over from a previous server lifecycle.
      Must be >= 0. Default: 360 (6 minutes — covers proactive warmup
      up to 255 s plus one heartbeat cycle). *)
  let grace_period_sec =
    Float.max 0.0 (get_float ~default:360.0 "MASC_KEEPER_WATCHDOG_GRACE_SEC")
  ;;

  (** Sliding window for stale-termination escalation tracking.
      Default: 21600 (6 hours). *)
  let termination_window_sec =
    Float.max 3600.0 (get_float ~default:21600.0 "MASC_KEEPER_TERMINATION_WINDOW_SEC")
  ;;

  (** Number of stale terminations within [termination_window_sec] before
      escalating to [Stale_termination_storm]. Default: 5. *)
  let escalation_threshold = max 1 (get_int ~default:5 "MASC_KEEPER_ESCALATION_THRESHOLD")

  (** Fleet batch-termination detection window in seconds.
      Default: 60. *)
  let batch_window_sec =
    Float.max 1.0 (get_float ~default:60.0 "MASC_KEEPER_BATCH_WINDOW_SEC")
  ;;

  (** Number of distinct keepers terminating within [batch_window_sec] before
      emitting a fleet batch alert. Default: 5. *)
  let batch_threshold = max 1 (get_int ~default:5 "MASC_KEEPER_BATCH_THRESHOLD")
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

(** {1 Cascade Saturation Signal (RFC-0153 Phase A.2)}

    Feature flag for typed [Cascade_saturation_signal.t] emission from
    structured cascade/provider errors. The signal is consumed by Phase B
    (tier admission semaphore) and Phase C (adaptive throttling).

    Default off. Phase A.2 emit is purely additive — it increments a new
    Prometheus counter ([masc_keeper_cascade_saturation_signal_total])
    with a typed [kind] label sourced from {!Cascade_saturation_signal.kind}. *)
module CascadeSaturationSignal = struct
  let enabled () =
    get_bool ~default:false "MASC_CASCADE_SATURATION_SIGNAL_ENABLED"
end

(** {1 Cascade Tier Admission (RFC-0153 Phase B.2)}

    Runtime kill switch for per-tier inflight admission in the main keeper
    cascade path. Default on: RFC-0153 Phase B.2 is intended to prevent
    keeper stampedes before provider dispatch. Operators can set the flag
    false as an emergency rollback without also disabling the additive Phase
    A.2 saturation-signal metric. *)
module CascadeTierAdmission = struct
  let enabled () =
    Feature_flag_registry.get_bool "MASC_CASCADE_TIER_ADMISSION_ENABLED"
end

module CascadeTierWait = struct
  let enabled () =
    Feature_flag_registry.get_bool "MASC_CASCADE_TIER_WAIT_ENABLED"

  let timeout_s () =
    get_float_nonneg ~default:30.0 "MASC_CASCADE_TIER_WAIT_TIMEOUT_S"

  let max_retries () =
    let v = get_string ~default:"" "MASC_CASCADE_TIER_WAIT_MAX_RETRIES" in
    match v with
    | "" | "none" | "unlimited" -> None
    | s -> (try Some (int_of_string s) with _ -> None)
end

(** {1 Cascade Runtime Overrides}

    Runtime-only narrowing of the MASC cascade provider set. The underlying
    cascade profile (loaded from [cascade.toml]) is unchanged; this filter is
    applied by the named-cascade execution path via [~provider_filter] on every
    keeper turn, so switching between full cascade and a single-provider
    fallback is a pure env-var change with no file or code edit.

    Use case: GLM endpoint outage (e.g. z.ai quota exhausted), Ollama-only
    hard mode, or A/B testing a single provider. *)
module KeeperCascade = struct
  (** Comma-separated provider kind allowlist for every keeper cascade call.
      Values are OAS [Provider_config.string_of_provider_kind]:
      [ollama], [provider_k], [provider_a], [provider_f], [openai_compat], [cli_tool_d],
      [provider_c], [cli_tool_c], [cli_tool_b], [cli_tool_a].
      Matching is case-insensitive; empty entries are dropped.

      Semantics: when set, keeper turns pass this list as [provider_filter]
      into [Keeper_turn_driver.run_named], which applies it during MASC cascade
      provider resolution. The runtime keeps only matching providers from
      the resolved profile; if the filter leaves zero providers, OAS falls back
      to the unfiltered profile (see [apply_provider_filter] safety net).

      [None] (env var unset or blank) = full cascade, unfiltered.

      Env: [MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST]. Default: unset. *)
  let provider_allowlist () : string list option =
    match Env_config_core.raw_value_opt "MASC_KEEPER_CASCADE_PROVIDER_ALLOWLIST" with
    | None -> None
    | Some raw ->
      let parts =
        raw
        |> String.split_on_char ','
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
      in
      (match parts with
       | [] -> None
       | _ -> Some parts)
  ;;
end

(** {1 Transient Retry Backoff}

    Outer-loop retry parameters for transient network errors and
    recoverable cascade failures.  These govern the keeper's exponential
    backoff between re-attempts when all OAS providers fail transiently
    (e.g. TCP keepalive expiry).  They do NOT affect OAS internal
    per-provider retry (3 attempts with its own backoff). *)
module KeeperRetryBackoff = Env_config_keeper_retry_backoff

(** Print configuration summary for debugging *)
