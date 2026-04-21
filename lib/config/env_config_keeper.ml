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

  (** Wall-clock timeout in seconds for a single unified turn (including all
      retries and cascade fallbacks). Prevents indefinite blocking when an
      upstream LLM hangs at the TCP level.
      Env: [MASC_KEEPER_TURN_TIMEOUT_SEC]. Default: 1200. Range: [60, 3600].
      Raised from 600 to 1200: keepers using GLM-5.1 + local 27B need more
      wall-clock time for multi-turn research cycles. *)
  let turn_timeout_sec =
    Float.max 60.0 (Float.min 3600.0
      (get_float ~default:1200.0 "MASC_KEEPER_TURN_TIMEOUT_SEC"))

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
      Otherwise, {!oas_timeout_for_context} computes an adaptive timeout:
        base + ctx/1K × per_1k + min(max_turns, 40) × per_turn
      References {!oas_max_turns_per_call} (default 15) directly to avoid
      default drift.  Previous formula used 4× headroom on a default of 5,
      producing min(5, 40)=5 effective turns.  Using the actual per-call
      turn budget keeps scheduled-autonomous and reactive channels aligned
      with the timeout heuristic.

      At 262K context, 15 turns/call:
        120 + 393 + min(15,40)×30 = 120+393+450 = 963

      Env: [MASC_KEEPER_OAS_TIMEOUT_SEC]. Default: adaptive.
      Range: [30, turn_timeout_sec]. *)
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
      leaving the keeper in an ambiguous state. With 15 turns per call and
      adaptive timeout, each turn gets a realistic time budget. Budget=5
      was too low: mutation boundary blocks tools after the first write,
      leaving only 1 productive action per cycle.
      Env: [MASC_KEEPER_OAS_MAX_TURNS_PER_CALL]. Default: 15. Range: [1, 50]. *)
  let oas_max_turns_per_call =
    max 1 (min 50 (get_int ~default:15 "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL"))

  (** Smaller turn budget for scheduled autonomous cycles so one keeper does
      not monopolize the autonomous semaphore for minutes at a time.
      Reactive turns keep the general budget because they correspond to
      explicit external stimuli.

      Default lowered from 5 to 2 (masc-mcp#6810): with LLM turns at ~22s
      and [semaphore_wait_timeout_sec] = 60s, a budget of 5 meant one
      keeper could hold the autonomous slot for 110s+, causing peers
      queued behind it to time out at 60s.  Budget of 2 caps hold time
      around 44s (~60s with tools), keeping peers within the wait window.
      Reactive turns retain the larger budget.

      Env: [MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS].
      Default: min(global, 2). Range: [1, global]. *)
  let oas_max_turns_per_call_scheduled_autonomous =
    let default = min oas_max_turns_per_call 2 in
    max 1
      (min oas_max_turns_per_call
         (min 50
            (get_int ~default
               "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS")))

  let oas_timeout_for_context_with_turn_budget ~(max_context : int)
      ~(max_turns : int) : float =
    match oas_timeout_sec_override with
    | Some v -> v
    | None ->
      let base = 120.0 in
      let per_1k =
        get_float ~default:1.5 "MASC_KEEPER_OAS_TIMEOUT_PER_1K"
      in
      let per_turn =
        get_float ~default:30.0 "MASC_KEEPER_OAS_TIMEOUT_PER_TURN"
      in
      let context_time = Float.of_int max_context /. 1000.0 *. per_1k in
      (* Cap at 40 effective turns even if the configured per-call turn
         budget is higher. This is a deliberate safety cap: with
         per_turn=30s, 40 turns alone consume 1200s — the entire
         turn_timeout_sec budget. Users pushing beyond 40 turns should
         instead raise turn_timeout_sec or split the work. *)
      let effective_turns =
        Float.of_int (min max_turns 40)
      in
      let turn_time = effective_turns *. per_turn in
      Float.max 30.0
        (Float.min turn_timeout_sec (base +. context_time +. turn_time))

  let oas_timeout_for_context ~(max_context : int) : float =
    oas_timeout_for_context_with_turn_budget ~max_context
      ~max_turns:oas_max_turns_per_call

  (** Backward-compatible accessor: returns the env override or 300s default.
      Prefer {!oas_timeout_for_context} when max_context is available. *)
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
      Env: [MASC_KEEPER_DOCKER_PLAYGROUND]. Default: false. *)
  let enabled =
    Feature_flag_registry.get_bool "MASC_KEEPER_DOCKER_PLAYGROUND"

  (** Docker container name for keeper playground execution.
      Env: [MASC_KEEPER_DOCKER_CONTAINER]. Default: "keeper-playground". *)
  let container_name =
    get_string ~default:"keeper-playground" "MASC_KEEPER_DOCKER_CONTAINER"

  (** Container-side root under which keeper playground bundles are mounted.
      Host [<base_path>/.masc/playground/<keeper>/…] maps to
      [<container_playground_root>/<keeper>/…] inside the container.
      Env: [MASC_KEEPER_DOCKER_PLAYGROUND_ROOT].
      Default: "/home/keeper/playground". *)
  let container_playground_root =
    get_string ~default:"/home/keeper/playground"
      "MASC_KEEPER_DOCKER_PLAYGROUND_ROOT"
end

module KeeperSandbox = struct
  (** Ephemeral Docker image used by sandbox_profile=docker.
      Must contain bash and the CLI tools the keeper needs. *)
  let docker_image () =
    get_string
      ~default:
        "ubuntu:24.04@sha256:cdb5fd928fced577cfecf12c8966e830fcdf42ee481fb0b91904eeddc2fe5eff"
      "MASC_KEEPER_SANDBOX_DOCKER_IMAGE"

  (** pids limit for hardened keeper containers. *)
  let pids_limit () =
    max 32 (get_int ~default:128 "MASC_KEEPER_SANDBOX_PIDS_LIMIT")

  (** Docker memory limit string, e.g. 2g / 512m. *)
  let memory () =
    get_string ~default:"2g" "MASC_KEEPER_SANDBOX_MEMORY"

  (** Writable tmpfs size inside the read-only rootfs. *)
  let tmpfs_size () =
    get_string ~default:"256m" "MASC_KEEPER_SANDBOX_TMPFS_SIZE"

  (** Optional seccomp profile path passed to [docker run --security-opt]. *)
  let seccomp_profile () =
    get_string ~default:"" "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE"

  (** Fail closed unless Docker reports rootless mode support. *)
  let require_rootless () =
    get_bool ~default:false "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS"

  (** Fail closed unless Docker reports userns support. *)
  let require_userns () =
    get_bool ~default:false "MASC_KEEPER_SANDBOX_REQUIRE_USERNS"

  (** Docker git-credential dispatch: when true, keeper_bash commands
      beginning with "git " or "gh " run in a Docker container with
      network_mode=inherit and read-only mounts of ~/.config/gh and
      ~/.gitconfig. Default commands stay on network_mode=none. Lets a
      single [sandbox_profile=docker] keeper run network-bound git/gh ops
      without granting wholesale network for all bash. *)
  let with_git_dispatch_enabled () =
    get_bool ~default:true "MASC_KEEPER_SANDBOX_GIT_DISPATCH"

  (** Host path mounted read-only at /root/.config/gh inside the docker
      git-creds execution path. Default $HOME/.config/gh. Empty string
      disables the mount (no gh auth). *)
  let gh_creds_host_path () =
    let default =
      try Filename.concat (Sys.getenv "HOME") ".config/gh"
      with Not_found -> ""
    in
    get_string ~default "MASC_KEEPER_SANDBOX_GH_CREDS"

  (** Host path mounted read-only at /root/.gitconfig. Default $HOME/.gitconfig. *)
  let gitconfig_host_path () =
    let default =
      try Filename.concat (Sys.getenv "HOME") ".gitconfig"
      with Not_found -> ""
    in
    get_string ~default "MASC_KEEPER_SANDBOX_GITCONFIG"

  (** SSH directory mount (~/.ssh). OFF by default — gh + HTTPS covers most
      flows; SSH is opt-in to keep the mount surface minimal. *)
  let ssh_dir_host_path () =
    get_string ~default:"" "MASC_KEEPER_SANDBOX_SSH_DIR"

  (** Optional GitHub token forwarded as GH_TOKEN env into the docker
      git-creds execution path. Defaults to the host GH_TOKEN; empty
      disables forwarding. *)
  let gh_token () =
    let default =
      try Sys.getenv "GH_TOKEN"
      with Not_found -> ""
    in
    get_string ~default "MASC_KEEPER_SANDBOX_GH_TOKEN"

  (** RFC-0006 Phase B-1: when true, hardened keepers' read-side tools
      (keeper_fs_read; later keeper_shell op=rg/ls/cat/find/...) are
      restricted to the keeper's playground bundle on the host even
      though the path resolver alone would have allowed broader access.

      Closes the asymmetry where keeper_bash gates execution to docker
      but keeper_fs_read still walks the host. Default off so existing
      hardened keepers (analyst/janitor/poe/minjae) keep working until
      operators flip the flag. *)
  let symmetric_read_containment () =
    get_bool ~default:false "MASC_KEEPER_SYMMETRIC_SANDBOX"

  (** RFC-0006 Phase B-2: when true (and symmetric_read_containment is
      also on), hardened keeper read-side ops route through
      [docker run --rm <image> cat <container_path>] so the
      container's mount restrictions become the primary boundary.

      The host-side containment check (B-1) remains as defense in
      depth — if the docker route is misconfigured, the host check
      still blocks. Default off because docker spawn per read is
      slower (~hundreds of ms) and only worth it for deployments
      that can absorb the latency in exchange for mount-level
      isolation. *)
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
      [ollama], [glm], [anthropic], [gemini], [openai_compat], [claude_code].
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
