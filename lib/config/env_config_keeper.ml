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
  let enabled =
    Feature_flag_registry.get_bool "MASC_KEEPER_BOOTSTRAP_ENABLED"

  (** Keeper considered stale when last turn exceeds this threshold (seconds) *)
  let stale_turn_seconds =
    get_float ~default:3600.0 "MASC_KEEPER_BOOTSTRAP_STALE_TURN_SEC"

  (** Max keeper meta files to scan during bootstrap *)
  let max_scan =
    get_int ~default:10000 "MASC_KEEPER_BOOTSTRAP_MAX_SCAN"

  (** Maximum concurrently active keepers. Guards keeper creation and bootstrap. *)
  let max_active_keepers =
    get_int ~default:10000 "MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS"

  (** Polling interval (seconds) for the lazy-startup wait loop in
      [server_bootstrap_loops.ml]. The autoboot fiber wakes up every
      [lazy_startup_poll_interval_sec] to re-check whether all
      registered lazy startup tasks have completed before kicking off
      keeper bootstrap. Default 0.25s preserves the inline literal at
      [server_bootstrap_loops.ml:157] (responsive enough for unit
      tests while keeping the idle CPU cost negligible). Floor 0.05s
      protects against operator typos that would burn CPU. *)
  let lazy_startup_poll_interval_sec =
    Float.max 0.05
      (get_float ~default:0.25
         "MASC_KEEPER_BOOTSTRAP_LAZY_STARTUP_POLL_INTERVAL_SEC")

  (** Polling interval (seconds) for the keeper-lifecycle listener
      retry loop in [server_bootstrap_loops.ml]. After a listener
      iteration raises (non-cancellation) the loop sleeps for this
      interval before retrying — keeping the spinning under control
      when an upstream subsystem is briefly down. Default 0.25s
      preserves the inline literal at [server_bootstrap_loops.ml:240]. *)
  let keeper_listener_retry_interval_sec =
    Float.max 0.05
      (get_float ~default:0.25
         "MASC_KEEPER_BOOTSTRAP_LISTENER_RETRY_INTERVAL_SEC")

  (** Settle delay (seconds) between lazy-startup completion and the
      keeper bootstrap fan-out. The autoboot fiber sleeps for this
      duration so SSE/board/orchestrator subsystems get a chance to
      finish their first tick before keeper boot competes for them.
      Default 5.0s preserves the inline literal at
      [server_bootstrap_loops.ml:482]. Operators on cold-start machines
      may raise this; setting to 0 is allowed (no settle) but unwise
      under load. *)
  let post_startup_settle_sec =
    Float.max 0.0
      (get_float ~default:5.0
         "MASC_KEEPER_BOOTSTRAP_POST_STARTUP_SETTLE_SEC")
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
    Feature_flag_registry.get_bool "MASC_KEEPER_ALERT_ENABLED"

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
    Feature_flag_registry.get_bool "MASC_KEEPER_ALERT_BOARD_ENABLED"

  let board_author =
    get_string ~default:"keeper-alert-bot" "MASC_KEEPER_ALERT_BOARD_AUTHOR"

  let board_hearth =
    get_string ~default:"keeper-alert" "MASC_KEEPER_ALERT_BOARD_HEARTH"

  let board_visibility =
    get_string ~default:"internal" "MASC_KEEPER_ALERT_BOARD_VISIBILITY"

  (** Slack fanout configuration *)
  let slack_enabled =
    Feature_flag_registry.get_bool "MASC_KEEPER_ALERT_SLACK_ENABLED"

  let slack_webhook_url =
    get_string ~default:"" "MASC_KEEPER_ALERT_SLACK_WEBHOOK_URL"

  (** Slack DM fanout configuration *)
  let slack_dm_enabled =
    Feature_flag_registry.get_bool "MASC_KEEPER_ALERT_SLACK_DM_ENABLED"

  let slack_dm_user_id =
    get_string ~default:"" "MASC_KEEPER_ALERT_SLACK_DM_USER_ID"

  (** GitHub issue fanout configuration *)
  let github_enabled =
    Feature_flag_registry.get_bool "MASC_KEEPER_ALERT_GITHUB_ENABLED"

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

  (** Paused keeper file TTL: seconds before stale paused keeper meta files
      are removed from disk. Default: 86400 (24 hours). *)
  let paused_cleanup_ttl_sec =
    Float.max 300.0 (get_float ~default:Masc_time_constants.day "MASC_KEEPER_PAUSED_CLEANUP_TTL_SEC")
end

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
    Float.max 0.1
      (get_float ~default:2.0
         "MASC_KEEPER_CRASH_PERSIST_DRAIN_INTERVAL_SEC")

  (** Autonomous-turn semaphore queue poll interval in seconds.

      Polled inside the autonomous-turn admission loop in
      {!Keeper_keepalive}. Lower values reduce ticket-grant latency
      under contention; higher values lower idle CPU.
      Must be >= 0.001 (1ms floor — anything tighter is busy-loop).
      Default: 0.05. *)
  let autonomous_queue_poll_sec =
    Float.max 0.001
      (get_float ~default:0.05
         "MASC_KEEPER_AUTONOMOUS_QUEUE_POLL_SEC")
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

  (** Keeper keepalive snapshot interval, clamped to [15, 3600]. Default: 300. *)
  let snapshot_sec =
    max 15 (min 3600 (get_int ~default:300 "MASC_KEEPER_SNAPSHOT_SEC"))

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

  (** Recent messages kept verbatim by
      {!Agent_sdk.Context_reducer.cap_message_tokens}.  Default: 3.
      Range: [1, 20].

      Env: [MASC_KEEPER_REDUCER_KEEP_RECENT]. *)
  let cap_message_keep_recent =
    max 1 (min 20 (get_int ~default:3 "MASC_KEEPER_REDUCER_KEEP_RECENT"))
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
  (** Master switch. When true, successful Coord.heartbeat after a
      unified turn counts as presence proof, allowing the next cycle to skip
      the full ensure_keeper_room_presence call. *)
  let enabled =
    Feature_flag_registry.get_bool "MASC_KEEPER_WORK_AS_HEARTBEAT"

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
    Feature_flag_registry.get_bool "MASC_KEEPER_SMART_HEARTBEAT"
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

  (** Max idle turns for reactive (board/mention triggered) keeper turns.
      Reactive turns have an explicit trigger — more patience warranted.
      Env: [MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE]. Default: 15. *)
  let max_idle_turns_reactive =
    max 2 (min 50 (get_int ~default:15 "MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE"))

  (** Hard ceiling for all keeper timeout constants (seconds).
      No timeout may exceed this value regardless of env override.
      Default: 600 (10 minutes). *)
  let timeout_hard_ceiling_sec = 600.0

  (** Wall-clock timeout in seconds for a single unified turn (including all
      retries and cascade fallbacks). Prevents indefinite blocking when an
      upstream LLM hangs at the TCP level.
      Env: [MASC_KEEPER_TURN_TIMEOUT_SEC]. Default: 3600. Range: [60, 7200].
      Raised from 1200 to 3600 (issue #9637): production fleet observed
      "turn wall-clock timeout after 1200s" with sangsu/qa-king keepers
      stalling on multi-turn research cycles using GLM-5.1 + local 27B
      cascade. The new floor matches the budgeted ceiling and gives
      operators headroom; range upper bumped to 7200 for the same reason.

      Additionally capped at [timeout_hard_ceiling_sec] (600s) so the turn
      timeout can never exceed the global hard ceiling. *)
  let turn_timeout_sec =
    Float.max 60.0 (Float.min timeout_hard_ceiling_sec
      (get_float ~default:3600.0 "MASC_KEEPER_TURN_TIMEOUT_SEC"))
>>>>>>> 8a608170c8 (feat(resilience): bulkhead pattern - ZOMBIE state, terminal_failure_latched, cascade pool)

  (** Maximum time a proactive keeper will wait in the MASC admission queue
      before abandoning the current OAS attempt.

      With admission max_concurrent=1 (MLX decode serial), a keeper may wait
      for the full duration of the preceding keeper's turn. Observed turn
      durations: 180-963s. Default 180s covers the common case (GLM cascade
      completes in ~180s) while avoiding indefinite waits.

      Env: [MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC]. Default: 180.0.
      Range: [5, 1200]. *)
  let admission_wait_timeout_sec =
    Float.max 5.0 (Float.min 1200.0
      (get_float ~default:180.0 "MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC"))

  (** Maximum time a scheduled autonomous keeper will wait for the local
      keeper turn gate before skipping the cycle. Reactive turns still wait
      indefinitely because they correspond to explicit external triggers.
      Env: [MASC_KEEPER_AUTONOMOUS_SLOT_WAIT_TIMEOUT_SEC]. Default: 30.0.
      Range: [5, 300]. *)
  let autonomous_slot_wait_timeout_sec =
    Float.max 5.0 (Float.min 300.0
      (get_float ~default:30.0 "MASC_KEEPER_AUTONOMOUS_SLOT_WAIT_TIMEOUT_SEC"))

  (** Per-call timeout in seconds for a single OAS Agent.run execution.
      Guards against indefinite LLM response waits within a turn.

      When [MASC_KEEPER_OAS_TIMEOUT_SEC] is set, that value is used directly.
      Otherwise, {!oas_timeout_for_estimated_input_tokens} returns the
      keeper wall-clock cap directly.  The previous adaptive formula used
      token count and per-turn multipliers, but those estimates were far
      below observed fleet turn latency and could timeout before a real
      multi-turn call completed.

      Env: [MASC_KEEPER_OAS_TIMEOUT_SEC]. Default: adaptive.
      Range: [30, turn_timeout_sec].

      The upstream clamp already enforces [<= turn_timeout_sec]; we keep
      that invariant here by using [turn_timeout_sec] as the ceiling. *)
  let oas_timeout_sec_override =
    match Env_config_core.raw_value_opt "MASC_KEEPER_OAS_TIMEOUT_SEC" with
    | Some raw ->
      Some (Float.max 30.0 (Float.min turn_timeout_sec
        (Option.value ~default:300.0 (Float.of_string_opt (String.trim raw)))))
    | None -> None

  (** Maximum turns per single OAS Agent.run call.
      Keeper resumes via checkpoint in the next keepalive cycle when
      {!Oas_worker.TurnBudgetExhausted} is returned.
      Previous default of 200 caused "ambiguous partial commit" errors:
      the 300s timeout would fire mid-turn after tools had already executed,
      leaving the keeper in an ambiguous state. With 30 turns per call and
      adaptive timeout, each turn gets a realistic time budget. Budget=5
      was too low: mutation boundary blocks tools after the first write,
      leaving only 1 productive action per cycle.
      Env: [MASC_KEEPER_OAS_MAX_TURNS_PER_CALL]. Default: 30. Range: [1, 100]. *)
  let oas_max_turns_per_call =
    max 1 (min 100 (get_int ~default:30 "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL"))

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
    max 1
      (min oas_max_turns_per_call
         (min 100
            (get_int ~default
               "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS")))

  let oas_timeout_for_estimated_input_tokens_with_turn_budget
      ~(estimated_input_tokens : int) ~(max_turns : int) : float =
    let _ = max_turns in
    match oas_timeout_sec_override with
    | Some v -> v
    | None ->
      (* #10008 fm2: the prior formula scaled the budget linearly with
         [max_turns * per_turn (=30s)].  #9933 recent-hour measurement
         shows fleet p50 turn latency ~16 min (960s) — the 30s-per-turn
         assumption was 32x below reality.  velvet-hammer at max_turns=10
         computed only 423.8s of OAS budget against a 1200s wall-clock
         cap; multi-turn research calls regularly hit
         [oas_timeout_budget] before a single real turn finished.

         Root-cause fix: drop the [per_turn * turns] term entirely.
         [turn_timeout_sec] is already the authoritative wall-clock
         cap the formula was trying to approach.  Keep the tiny
         [base + input_time] estimate as a lower bound so tests and
         callers that set explicit overrides still see a sensible
         value, then floor at the wall-clock cap.  [max_turns] stops
         being an input to this computation — the count controls the
         OAS agent's retry budget elsewhere, not MASC's wall-clock
         expectation. *)
      let _ = estimated_input_tokens in
      (* Use wall-clock cap directly.  Short calls exit early via
         tool-response detection; they do not need a smaller budget
         reserved up front.  [estimated_input_tokens] and the old
         [base + input_time] estimate are no longer load-bearing
         inputs — they scaled at 1.5s/1k tokens, which was
         negligible compared to the real p50 turn latency the
         multiplier was trying to reserve for.  Kept in the
         signature because callers still pass the value; ignored
         for budget computation. *)
      turn_timeout_sec

  let oas_timeout_for_estimated_input_tokens
      ~(estimated_input_tokens : int) : float =
    oas_timeout_for_estimated_input_tokens_with_turn_budget
      ~estimated_input_tokens
      ~max_turns:oas_max_turns_per_call

  (** Backward-compatible accessor: returns the env override or 300s default.
      Prefer {!oas_timeout_for_estimated_input_tokens} when a live prompt
      estimate is available. *)
  let oas_timeout_sec =
    Option.value ~default:300.0 oas_timeout_sec_override

  (** Consecutive idle tool repetitions before on_idle hook issues Skip.
      Below this: graduated Nudge messages.
      With tool_choice=Any, the model always calls tools, so idle
      detection triggers on repeated tool calls.  4 catches loops
      quickly while still allowing legitimate exploration.
      Env: [MASC_KEEPER_IDLE_SKIP_THRESHOLD]. Default: 4. *)
  let idle_skip_threshold =
    max 2 (min 20 (get_int ~default:4 "MASC_KEEPER_IDLE_SKIP_THRESHOLD"))
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
    let raw = Float.max 60.0 (get_float ~default:300.0 "MASC_KEEPER_WATCHDOG_STALE_SEC") in
    if raw > KeeperKeepalive.turn_timeout_sec then (
      Log.warn "MASC_KEEPER_WATCHDOG_STALE_SEC (%.1f) exceeds turn_timeout_sec (%.1f); clamping to turn_timeout_sec"
        raw KeeperKeepalive.turn_timeout_sec;
      KeeperKeepalive.turn_timeout_sec
    ) else raw

  (** Watchdog poll interval in seconds. Must be >= 5.
      Default: 30. *)
  let poll_sec =
    Float.max 5.0 (get_float ~default:30.0 "MASC_KEEPER_WATCHDOG_POLL_SEC")

  (** Consecutive noop turns before considering the keeper stuck in a
      failure loop. Must be >= 2. Default: 3. *)
  let noop_threshold =
    max 2 (get_int ~default:3 "MASC_KEEPER_WATCHDOG_NOOP_THRESHOLD")

  (** Grace period after fiber start before idle-stale detection activates.
      Prevents false positives on server restart when [last_turn_ts] is
      carried over from a previous server lifecycle.
      Must be >= 0. Default: 360 (6 minutes — covers proactive warmup
      up to 255 s plus one heartbeat cycle). *)
  let grace_period_sec =
    Float.max 0.0 (get_float ~default:360.0 "MASC_KEEPER_WATCHDOG_GRACE_SEC")
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

(** {1 Context Ratio Hard Cap}

    Absolute ceiling for compaction ratio_gate and handoff threshold after
    multiplier adjustment.  Prevents runaway values from disabling
    compaction/handoff.  Default: 0.95. Range: [0.80, 0.99]. *)

let context_ratio_hard_cap =
  Float.max 0.80 (Float.min 0.99 (get_float ~default:0.95 "MASC_CONTEXT_RATIO_HARD_CAP"))

(** {1 Context Compaction (OAS)} *)

module ContextCompact = struct
  let w_recency = get_float ~default:0.50 "MASC_COMPACT_W_RECENCY"
  let w_role = get_float ~default:0.35 "MASC_COMPACT_W_ROLE"
  let w_tool = get_float ~default:0.15 "MASC_COMPACT_W_TOOL"

  let role_system = get_float ~default:1.0 "MASC_COMPACT_ROLE_SYSTEM"
  let role_tool = get_float ~default:0.7 "MASC_COMPACT_ROLE_TOOL"
  let role_user = get_float ~default:0.6 "MASC_COMPACT_ROLE_USER"
  let role_assistant = get_float ~default:0.4 "MASC_COMPACT_ROLE_ASSISTANT"

  let tool_present = get_float ~default:0.8 "MASC_COMPACT_TOOL_PRESENT"
  let tool_absent = get_float ~default:0.5 "MASC_COMPACT_TOOL_ABSENT"

  let anchor_boost = get_float ~default:0.95 "MASC_COMPACT_ANCHOR_BOOST"
  let drop_importance_threshold = get_float ~default:0.3 "MASC_COMPACT_DROP_THRESHOLD"
  let summarize_keep_recent = get_int ~default:5 "MASC_COMPACT_KEEP_RECENT"

  let tool_output_prune_limit = get_int ~default:1500 "MASC_COMPACT_TOOL_PRUNE_LIMIT"

  let dynamic_multi_agent_ratio = get_float ~default:0.80 "MASC_COMPACT_DYN_MULTI_AGENT_RATIO"
  let dynamic_focused_ratio = get_float ~default:0.70 "MASC_COMPACT_DYN_FOCUSED_RATIO"
  let small_local_floor = get_int ~default:64_000 "MASC_COMPACT_SMALL_LOCAL_FLOOR"
  let large_cloud_floor = get_int ~default:500_000 "MASC_COMPACT_LARGE_CLOUD_FLOOR"
end

(** {1 Dashboard Health Thresholds}

    Thresholds used by the dashboard keeper health scorer and harness health
    panels.  Distinct from compaction triggers — these affect UI display only. *)

(** {1 Docker Playground} *)

module DockerPlayground = struct
  (** Route keeper_bash commands through a Docker container instead of
      local subprocess.  The container must be running and named
      [keeper-playground].  When disabled, commands run locally with
      the existing allowlist restrictions.
      Env: [MASC_KEEPER_DOCKER_PLAYGROUND]. Default: false.
      P2b: aliased to {!Env_config_sandbox.Runtime.docker_playground_enabled};
      [()] call freezes the value at module init to preserve the
      original [Feature_flag_registry.get_bool] semantics. *)
  let enabled =
    Env_config_sandbox.Runtime.docker_playground_enabled ()

  (** Docker container name for keeper playground execution.
      Env: [MASC_KEEPER_DOCKER_CONTAINER]. Default: "keeper-playground".
      Not yet in {!Env_config_sandbox} — kept here. *)
  let container_name =
    get_string ~default:"keeper-playground" "MASC_KEEPER_DOCKER_CONTAINER"

  (** Container-side root under which keeper playground bundles are mounted.
      Host [<base_path>/.masc/playground/<keeper>/…] maps to
      [<container_playground_root>/<keeper>/…] inside the container.
      Env: [MASC_KEEPER_DOCKER_PLAYGROUND_ROOT].
      Default: "/home/keeper/playground".
      Not yet in {!Env_config_sandbox} — kept here. *)
  let container_playground_root =
    get_string ~default:"/home/keeper/playground"
      "MASC_KEEPER_DOCKER_PLAYGROUND_ROOT"
end

module KeeperSandbox = struct
  (** P2b: this module is now a thin alias layer that delegates to
      {!Env_config_sandbox} (#10480 P2a SSOT scaffold).  Behavior is
      preserved byte-for-byte — same env vars, same defaults — so all
      ~76 call sites in [lib/keeper/*] continue to work unchanged.
      The complex [gh_token] / [For_testing] machinery stays here
      because it manages an Atomic-backed cache that is too entangled
      with this module's internals to lift out cleanly in P2b.

      Doc strings live on the underlying {!Env_config_sandbox}
      module; see {!Env_config_sandbox.Hardening} etc. for the full
      semantics, env var names, and defaults. *)

  let hard_mode = Env_config_sandbox.Hardening.hard_mode

  let docker_image = Env_config_sandbox.Runtime.docker_image

  let preflight_enabled = Env_config_sandbox.Preflight.enabled

  let pids_limit = Env_config_sandbox.Hardening.pids_limit

  let nofile_limit = Env_config_sandbox.Hardening.nofile_limit

  let memory = Env_config_sandbox.Hardening.memory

  let tmpfs_size = Env_config_sandbox.Hardening.tmpfs_size

  let relax_fs = Env_config_sandbox.Hardening.relax_fs

  let read_only_rootfs_args = Env_config_sandbox.Hardening.read_only_rootfs_args

  let tmpfs_mount = Env_config_sandbox.Hardening.tmpfs_mount

  let seccomp_profile = Env_config_sandbox.Hardening.seccomp_profile

  let require_rootless = Env_config_sandbox.Hardening.require_rootless

  let require_userns = Env_config_sandbox.Hardening.require_userns

  let cleanup_enabled = Env_config_sandbox.Cleanup.enabled

  let cleanup_stale_after_sec = Env_config_sandbox.Cleanup.stale_after_sec

  let cleanup_interval_sec = Env_config_sandbox.Cleanup.interval_sec

  let with_git_dispatch_enabled = Env_config_sandbox.Runtime.git_dispatch

  let gh_creds_host_path = Env_config_sandbox.Auth_paths.gh_creds

  let gitconfig_host_path = Env_config_sandbox.Auth_paths.gitconfig

  let ssh_dir_host_path = Env_config_sandbox.Auth_paths.ssh_dir

  let gh_token_probe_timeout_sec =
    Env_config_sandbox.Auth_paths.gh_token_probe_timeout_sec

  let close_fd_noerr fd =
    try Unix.close fd with
    | Unix.Unix_error _ -> ()

  let waitpid_nohang pid =
    try
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ -> None
      | _, status -> Some status
    with
    | Unix.Unix_error (Unix.ECHILD, _, _) -> Some (Unix.WEXITED 127)

  let terminate_process pid =
    (try Unix.kill pid Sys.sigterm with
     | Unix.Unix_error _ -> ());
    let deadline = Unix.gettimeofday () +. 0.2 in
    let rec wait_for_exit () =
      match waitpid_nohang pid with
      | Some _ -> ()
      | None when Unix.gettimeofday () < deadline ->
          ignore (Unix.select [] [] [] 0.02);
          wait_for_exit ()
      | None ->
          (try Unix.kill pid Sys.sigkill with
           | Unix.Unix_error _ -> ());
          (try
             let _status = Unix.waitpid [] pid in
             ()
           with
           | Unix.Unix_error _ -> ())
    in
    wait_for_exit ()

  let read_available fd buf =
    let chunk = Bytes.create 512 in
    let rec loop () =
      match Unix.read fd chunk 0 (Bytes.length chunk) with
      | 0 -> ()
      | n ->
          Buffer.add_subbytes buf chunk 0 n;
          loop ()
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    in
    loop ()

  let run_gh_auth_token_probe () =
    let stdout_rd, stdout_wr = Unix.pipe () in
    let stdin_fd = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
    let stderr_fd = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
    let pid_ref = ref None in
    Fun.protect
      ~finally:(fun () ->
        close_fd_noerr stdout_rd;
        close_fd_noerr stdout_wr;
        close_fd_noerr stdin_fd;
        close_fd_noerr stderr_fd)
      (fun () ->
        let pid =
          Unix.create_process "gh"
            [| "gh"; "auth"; "token"; "--hostname"; "github.com" |]
            stdin_fd stdout_wr stderr_fd
        in
        pid_ref := Some pid;
        close_fd_noerr stdout_wr;
        Unix.set_nonblock stdout_rd;
        let deadline = Unix.gettimeofday () +. gh_token_probe_timeout_sec () in
        let buf = Buffer.create 128 in
        let rec loop () =
          read_available stdout_rd buf;
          match waitpid_nohang pid with
          | Some (Unix.WEXITED 0) ->
              read_available stdout_rd buf;
              let token = String.trim (Buffer.contents buf) in
              if token = "" then None else Some token
          | Some _ -> None
          | None ->
              let remaining = deadline -. Unix.gettimeofday () in
              if remaining <= 0.0 then (
                terminate_process pid;
                None)
              else (
                ignore (Unix.select [ stdout_rd ] [] [] (min 0.05 remaining));
                loop ())
        in
        loop ())
    |> fun result ->
    match result, !pid_ref with
    | None, Some pid ->
        (match waitpid_nohang pid with
        | None -> terminate_process pid
        | Some _ -> ());
        None
    | _ -> result

  type gh_token_probe_cache =
    | Unchecked
    | Checked of string

  let gh_token_probe = Atomic.make run_gh_auth_token_probe
  let gh_token_probe_cache = Atomic.make Unchecked

  let gh_token_from_probe_cache () =
    match Atomic.get gh_token_probe_cache with
    | Checked token -> token
    | Unchecked ->
        let token =
          try
            match (Atomic.get gh_token_probe) () with
            | Some token -> String.trim token
            | None -> ""
          with _ -> ""
        in
        ignore (Atomic.compare_and_set gh_token_probe_cache Unchecked (Checked token));
        (match Atomic.get gh_token_probe_cache with
        | Checked cached -> cached
        | Unchecked -> token)

  (** GitHub token forwarded as GH_TOKEN env into the docker git-creds
      execution path. Resolution order:
        1. MASC_KEEPER_SANDBOX_GH_TOKEN env override
        2. host GH_TOKEN env (the historical default)
        3. host `gh auth token` keychain fallback — required on macOS where
           gh stores tokens in the OS keyring rather than hosts.yml; without
           this, mounting ~/.config/gh into the container yields metadata only
           and every gh/git HTTPS operation fails with HTTP 401.

      Returns "" when the host has no token configured at all; the caller
      then skips the -e GH_TOKEN injection and the container falls back to
      whatever credentials are present in the mounted hosts.yml. *)
  let gh_token () =
    if hard_mode () then
      ""
    else
      let override = get_string ~default:"" "MASC_KEEPER_SANDBOX_GH_TOKEN" in
      if override <> "" then override
      else
        let from_env =
          match Sys.getenv_opt "GH_TOKEN" with
          | Some token -> token
          | None -> ""
        in
        if from_env <> "" then from_env
        else gh_token_from_probe_cache ()

  module For_testing = struct
    let reset_gh_token_probe_cache () =
      Atomic.set gh_token_probe_cache Unchecked

    let with_gh_token_probe probe f =
      let prior = Atomic.get gh_token_probe in
      Atomic.set gh_token_probe probe;
      reset_gh_token_probe_cache ();
      Fun.protect
        ~finally:(fun () ->
          Atomic.set gh_token_probe prior;
          reset_gh_token_probe_cache ())
        f
  end

  (** Legacy RFC-0006 Phase B-1 flag.

      Read-side containment now follows [sandbox_profile=docker]
      unconditionally. This getter remains only for backward-compatible
      config surfaces and should not gate runtime sandbox policy. *)
  let symmetric_read_containment () =
    get_bool ~default:false "MASC_KEEPER_SYMMETRIC_SANDBOX"

  (** Legacy RFC-0006 Phase B-2 flag.

      Docker read routing now follows [sandbox_profile=docker]
      unconditionally. This getter remains only for backward-compatible
      config surfaces and should not gate runtime sandbox policy. *)
  let docker_read_routing () =
    get_bool ~default:false "MASC_KEEPER_DOCKER_READ"
end

module DashboardHealth = struct
  let ctx_critical = get_float ~default:0.9 "MASC_DASHBOARD_HEALTH_CTX_CRITICAL"
  let ctx_warn = get_float ~default:0.8 "MASC_DASHBOARD_HEALTH_CTX_WARN"
  let penalty_critical = get_float ~default:20.0 "MASC_DASHBOARD_HEALTH_PENALTY_CRITICAL"
  let penalty_warn = get_float ~default:10.0 "MASC_DASHBOARD_HEALTH_PENALTY_WARN"
  let runtime_warning_ctx_ratio = get_float ~default:0.95 "MASC_DASHBOARD_RUNTIME_WARNING_CTX_RATIO"
end

(** {1 Wake-time Payload Telemetry}

    Phase 0 observability for the tiered-hydration redesign (Option C).
    When enabled, every keeper wake captures an approximation of the LLM
    request payload size just before [Oas_worker.run_named] is invoked.
    The record is appended to
    [$MASC_BASE_PATH/data/keeper-wake-payload/YYYY-MM-DD.jsonl] via
    [Dashboard_harness_health.record_wake_payload].

    Cost when disabled: a single env var lookup (bool). The entire
    measurement path is gated behind [payload_telemetry_enabled]. *)
module KeeperTelemetry = struct
  (** Master switch for wake-payload measurement. Default off so the hot
      path is untouched until a baseline sweep is explicitly requested. *)
  let payload_telemetry_enabled () =
    get_bool ~default:false "MASC_PAYLOAD_TELEMETRY"
end

(** {1 Cascade Runtime Overrides}

    Runtime-only narrowing of the MASC cascade provider set. The underlying
    cascade profile (loaded from [cascade.json]) is unchanged; this filter is
    applied by the named-cascade execution path via [~provider_filter] on every
    keeper turn, so switching between full cascade and a single-provider
    fallback is a pure env-var change with no file or code edit.

    Use case: GLM endpoint outage (e.g. z.ai quota exhausted), Ollama-only
    hard mode, or A/B testing a single provider. *)
module KeeperCascade = struct
  (** Comma-separated provider kind allowlist for every keeper cascade call.
      Values are OAS [Provider_config.string_of_provider_kind]:
      [ollama], [glm], [anthropic], [gemini], [openai_compat], [claude_code],
      [kimi], [kimi_cli], [gemini_cli], [codex_cli].
      Matching is case-insensitive; empty entries are dropped.

      Semantics: when set, keeper turns pass this list as [provider_filter]
      into [Oas_worker.run_named], which applies it during MASC cascade
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
end

(** Print configuration summary for debugging *)
