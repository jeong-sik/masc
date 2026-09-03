(** Env_config_keeper — keeper runtime parameters from environment.

    {!Keeper_runtime_setting_registry} is the public inventory. Only settings
    classified there as [Toml_and_env] can be declared in
    [<resolved config root>/runtime.toml]; the remainder are explicitly
    [Env_only]. The TOML loader ({!Keeper_runtime_config.load_and_apply}) runs
    at server startup and records unset values in the process-local boot
    override store before this module initializes.

    Precedence: process env > TOML > hardcoded default below.

    See [docs/ENV-CONTRACT.md] for the environment contract. *)

open Env_config_core

(** {1 Keeper Bootstrap Configuration} *)

module KeeperBootstrap = struct
  (** Enable startup keeper bootstrap scan *)
  let enabled = Feature_flag_registry.get_bool "MASC_KEEPER_BOOTSTRAP_ENABLED"

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

module KeeperSpawn = struct
  (** Bytes of each spawned process stream [Spawn_registry] keeps. A process
      can outrun any reader, so the buffer is bounded and [read] reports every
      byte the bound cost -- a cap that says what it discarded rather than one
      that hides it.

      Default 1 MiB: enough to hold a build's output between two reads of a
      turn, small enough that a chatty watcher cannot grow a keeper's memory
      without limit. Floor 4 KiB, because a buffer smaller than a single pipe
      read drops most of what it is handed. *)
  (* Reading an env var once at module init is a pure computation: no outcome,
     no failure, no duration. What is worth observing is what the bound costs,
     and [Spawn_registry] reports that per read as [dropped_before], where a
     caller can act on it. The marker sits on the line above the binding
     because the gate reads a two-line window. *)
  (* TEL-OK *)
  let spawn_output_buffer_bytes =
    Int.max 4096 (get_int_nonneg ~default:1_048_576 "MASC_KEEPER_SPAWN_OUTPUT_BUFFER_BYTES")
  ;;

end

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

  (** Master switch for diagnostic MASC->AGENT_CORE wire capture. Default off.
      @category Policies @ops_class operator *)
  let enabled () = Feature_flag_registry.get_bool "MASC_KEEPER_WIRE_CAPTURE"

  let retention_days_default = 3
  let retention_days_ceiling = 30
  let max_bytes_default = 64 * 1024 * 1024
  let max_bytes_ceiling = 1024 * 1024 * 1024

  (** Maximum age for [<masc_root>/wire-capture] day files retained by the
      diagnostic MASC->AGENT_CORE wire-capture harness. Default is 3 days. Range:
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

(** {1 Autonomous turn configuration} *)

module KeeperAutonomous = struct
  (** Upper bound on the wake prompt, in bytes.

      This value is not a system prompt: it is appended to the durable
      checkpoint as the user turn of every autonomous cycle, so its cost is
      paid again on each subsequent turn that replays the history. A long
      operator string therefore consumes prompt budget permanently rather
      than once, which is why the bound is enforced where the value is read
      instead of being left to the operator's judgement. *)
  let max_wake_prompt_bytes = 2048

  (** Contract for the fleet env var. [Error] carries an operator-facing
      reason; blank is rejected rather than folded into the default, so
      "unset" and "set to nothing" stay distinguishable. *)
  let validate_wake_prompt raw =
    let trimmed = String.trim raw in
    if String.equal trimmed ""
    then Error "autonomous wake prompt must not be blank"
    else if String.length trimmed > max_wake_prompt_bytes
    then
      Error
        (Printf.sprintf
           "autonomous wake prompt is %d bytes, over the %d-byte bound (it is \
            appended to the durable checkpoint on every autonomous turn)"
           (String.length trimmed)
           max_wake_prompt_bytes)
    else Ok trimmed
  ;;

  (** The wording used when neither the fleet nor a keeper configures one.

      Read from the binary, not from [<config-root>/prompts]. That runtime
      copy is derived distribution state: [Managed_asset_sync] overwrites it
      from this same embedded tree on every boot, and prompt customization
      lives in [prompt_overrides.json] instead — so the two are the same bytes
      and reading the copy only adds a way to fail.

      It added a real one. This binding is a value, so it runs at module load;
      the sync that produces the copy runs later, inside [main]. An asset
      newly added to the manifest therefore had no copy yet on any boot, and
      the boot that would have created it died first. *)
  let default_wake_prompt =
    let asset = "prompts/keeper.autonomous.wake.txt" in
    match Embedded_config.read asset with
    | None ->
      (* The crunch tree is the repository's own [config/], so a missing key
         means the binary was built without the asset. Nothing at runtime can
         supply it. *)
      raise
        (Env_config_core.Config_error
           ("autonomous wake prompt is not embedded in this binary: " ^ asset))
    | Some contents ->
      (match validate_wake_prompt (String.trim contents) with
       | Ok prompt -> prompt
       | Error detail ->
         raise
           (Env_config_core.Config_error
              (Printf.sprintf "invalid embedded autonomous wake prompt %s: %s" asset detail)))
  ;;

  (** Fleet-wide wake prompt, or [None] when unset. Read as a function: the
      value is steerable through the boot override store, and a keeper process
      outlives module-load time. *)
  let wake_prompt_opt () =
    match Env_config_core.raw_value_opt "MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT" with
    | None -> None
    | Some raw ->
      (match validate_wake_prompt raw with
       | Ok value -> Some value
       | Error reason ->
         raise
           (Env_config_core.Config_error
              (Printf.sprintf "MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT: %s" reason)))
  ;;

  (** Fleet value else the literal default. This is what a keeper that states
      no override of its own is woken with, and what the operator settings
      projection reports. *)
  let wake_prompt () = Option.value (wake_prompt_opt ()) ~default:default_wake_prompt
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
  type librarian_config_state =
    | Enabled
    | Disabled
    | Invalid

  let get_int_logged = Env_config_memory.get_int_logged

  let recall_enabled_default = true
  let librarian_enabled_default = true
  let librarian_cadence_turns_default = 3
  let librarian_max_messages_default = 24

  (* Env-key SSOT: the config-introspection registry
     (env_config_snapshot.ml memory_entries) and the tests reference these
     constants instead of re-spelling the literals, so a knob rename breaks
     compilation instead of silently drifting into a phantom registry entry. *)
  let recall_env_key = "MASC_KEEPER_MEMORY_OS_RECALL"
  let librarian_env_key = "MASC_KEEPER_MEMORY_OS_LIBRARIAN"
  let librarian_cadence_turns_env_key = "MASC_KEEPER_MEMORY_OS_LIBRARIAN_CADENCE_TURNS"
  let librarian_max_messages_env_key = "MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_MESSAGES"

  let get_bool_logged ?(invalid = Env_config_memory.Default) name ~default =
    Env_config_memory.get_bool_logged
      ~invalid
      name
      ~default
  ;;

  let librarian_config_state () =
    match Env_config_memory.env_opt librarian_env_key with
    | None ->
      if librarian_enabled_default then Enabled else Disabled
    | Some raw ->
      (match Env_config_memory.parse_bool_token raw with
       | Some true -> Enabled
       | Some false -> Disabled
       | None -> Invalid)
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

  let max_output_tokens_default = 64 * 1024
  let max_output_tokens_floor = 4096
  let max_output_tokens_ceiling = 128 * 1024

  (** Maximum output tokens for the one-shot vision sub-call. On the
      OpenAI-compatible /v1 endpoint the vision fleet uses, this single budget is
      shared by the model's reasoning phase and the visible answer, so a cap that
      only fits the answer lets reasoning drain it and truncate the reply
      mid-JSON (2026-08-27 MiniMax M3 finding). Default 65536 clears OpenAI's
      >= 25000 reasoning-plus-output reserve with headroom and matches OSS
      reasoning tooling; it is a ceiling billed only for tokens generated, not a
      target, so raising it costs nothing on a normal reply. Range:
      [4096, 131072], the ceiling being M3's declared output limit.

      @category Policies @ops_class operator *)
  let max_output_tokens () =
    get_int_nonneg ~default:max_output_tokens_default "MASC_KEEPER_VISION_MAX_OUTPUT_TOKENS"
    |> clamp_int ~min_value:max_output_tokens_floor ~max_value:max_output_tokens_ceiling
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

(** Shared keepalive interval, read early so WorkAsHeartbeat can reference it.
    Any positive interval is valid; the scheduler must not silently rewrite an
    operator-selected cadence.

    @category Thresholds
    @ops_class operator *)
let keepalive_interval_sec_ =
  let interval_sec = get_int ~default:300 "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" in
  if interval_sec > 0
  then interval_sec
  else
    raise
      (Config_error
         "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC must be a positive integer")
;;

(** {1 Work-as-Heartbeat Configuration (Phase 1)} *)

module WorkAsHeartbeat = struct
  (** Master switch. When true, successful Workspace.heartbeat after a
      unified turn counts as presence proof, allowing the next cycle to skip
      the full ensure_keeper_workspace_presence call. *)
  let enabled = Feature_flag_registry.get_bool "MASC_KEEPER_WORK_AS_HEARTBEAT"
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
  (** Heartbeat cycle interval in seconds. Default: 300.
      Every positive operator-selected cadence is preserved exactly. This is
      the foundational timing constant — every keeper cycle (presence,
      snapshot, board scan, turn) runs at this cadence.

      It is a ceiling, not a fixed spacing: a queued stimulus wakes the lane
      inside [sleep_chunk_sec], so a keeper with work runs more often than
      this. Measured 2026-09-03: polisher 289 s and analyst 265 s median
      between turns, pr-updater 88 s. *)
  let interval_sec = keepalive_interval_sec_

  (** Interruptible sleep chunk size in seconds: the upper bound on how long a
      keeper's heartbeat sleep takes to notice a wakeup atomic set by an incoming
      stimulus (board/mention/goal/schedule/approval). Smaller = faster wakeup
      response but more CPU polling. Default: 0.5 (was 2.0) — a queued event now
      wakes the lane within 0.5s instead of up to 2s; at ~2 CAS checks/sec/keeper
      the extra polling is negligible, and the dominant reaction cost remains the
      turn's own LLM call, not this floor.
      Range: [0.1, 10.0].
      @category Thresholds
      @ops_class operator *)
  let sleep_chunk_sec =
    Float.max 0.1 (Float.min 10.0 (get_float ~default:0.5 "MASC_KEEPER_SLEEP_CHUNK_SEC"))
  ;;

  (** Upper bound for the failure-route backoff sleep computed after a failed
      keepalive cycle. A provider rate-limit ([429]) or capacity route makes
      the next cycle wait longer than the plain cadence would, but the wait is
      capped so a misread [Retry-After] header (or a stale env override) can
      never park a lane indefinitely: [interruptible_sleep] still wakes within
      [sleep_chunk_sec] of any queued stimulus. Default: 900 (15 min).
      Range: [60.0, 3600.0].
      @category Thresholds
      @ops_class operator *)
  let rate_limit_backoff_cap_sec =
    Float.max
      60.0
      (Float.min 3600.0 (get_float ~default:900.0 "MASC_KEEPER_RATE_LIMIT_BACKOFF_CAP_SEC"))
  ;;

  let parse_stream_idle_timeout_sec raw =
    match Float.of_string_opt (String.trim raw) with
    | Some seconds when Float.is_finite seconds && Float.compare seconds 0.0 > 0 ->
      Ok seconds
    | Some _ | None ->
      Error "expected a finite, positive number of seconds"
  ;;

  let stream_idle_timeout_env_key = "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC"
  let stream_idle_failsafe_floor_sec = 600.0

  (** Explicit idle-gap timeout for streaming AGENT_CORE provider responses.
      This bounds time between streamed lines, not total turn duration.
      Unset means disabled: MASC and AGENT_CORE must not synthesize a provider/model
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

  let first_event_timeout_env_key = "MASC_KEEPER_FIRST_EVENT_TIMEOUT_SEC"

  (* Fail-safe bound for the silent first-event (TTFT/prefill) wait; the
     substitution rule lives in Keeper_runtime_resolved. Same magnitude as
     [stream_idle_failsafe_floor_sec]: an order above real silent prefill
     observed in production (152s mimo 1M-context 2026-07-20; ~200-525s local
     MLX 20.7K-token keeper prompts 2026-08-16), not a per-provider tuning
     (RFC-AC-037 §3). *)
  let first_event_failsafe_floor_sec = 600.0

  (** Explicit first-event (TTFT/prefill) timeout for streaming AGENT_CORE
      provider responses. Bounds only the wait for the FIRST provider event;
      [stream_idle_timeout_sec] bounds the gaps after it. Providers that emit
      no keepalives while prefilling are legitimately silent in this phase,
      so this budget is distinct from — and typically longer than — the
      inter-line idle gap (RFC-AC-037). Unset means no explicit value; the
      resolved layer substitutes {!first_event_failsafe_floor_sec}. A
      configured value must be finite and strictly positive; malformed values
      are operator configuration errors, never a fallback. Same value grammar
      as the idle knob, hence the shared parser.

      Env: [MASC_KEEPER_FIRST_EVENT_TIMEOUT_SEC]. Default: unset -> [None].
      @category Timeouts @ops_class operator *)
  let first_event_timeout_sec () =
    match Env_config_core.raw_value_opt first_event_timeout_env_key with
    | None -> None
    | Some raw ->
      (match parse_stream_idle_timeout_sec raw with
       | Ok seconds -> Some seconds
       | Error detail ->
         raise
           (Env_config_core.Config_error
              (Printf.sprintf
                 "invalid %s=%S (%s)"
                 first_event_timeout_env_key
                 raw
                 detail)))
  ;;

  (** Total HTTP body-consumption deadline for non-streaming AGENT_CORE completion
      calls. In agent_core this wraps [Complete.complete]'s synchronous HTTP
      body read; streaming calls deliberately ignore the knob so active
      long streams are not killed by total duration. Streaming liveness is
      handled by an explicitly configured [stream_idle_timeout_sec] and the
      attempt liveness observer.

      Opt-in: unset env leaves [None] so {!Runtime_agent_context} skips
      the builder wiring. Set only for sync completion callers that need a
      body-read ceiling.

      Env: [MASC_KEEPER_BODY_TIMEOUT_SEC]. Default: unset → [None].
      Range when set: [10, 600]. *)
  let body_timeout_sec_override_live () =
    match Env_config_core.raw_value_opt "MASC_KEEPER_BODY_TIMEOUT_SEC" with
    | Some raw ->
      (match Float.of_string_opt (String.trim raw) with
       | Some v -> Some (Float.max 10.0 (Float.min 600.0 v))
       | None -> None)
    | None -> None
  ;;

  let body_timeout_sec_override = body_timeout_sec_override_live ()

  (** Total wall-clock deadline for a single provider call attempt (whole
      operation, independent of streaming progress) — distinct from
      [stream_idle_timeout_sec] (bounds the GAP between streamed lines, and
      per RFC-0345 falls back to a 600s failsafe floor when unset) and
      [body_timeout_sec_override] (non-streaming calls only, no failsafe).
      Neither narrower knob bounds a call stuck before its first token
      (Admission/Queue/pre-stream phases) or a non-streaming call left
      unconfigured, which is exactly the gap #27349 measured: 4 keepers
      in-flight 25+ minutes with neither narrower knob set.

      Opt-in: unset env leaves [None] so the provider-attempt caller skips
      the [Eio.Time.with_timeout_exn] wrap and the call runs unbounded,
      same as before this knob existed. Deliberately NO failsafe floor
      (unlike [stream_idle_timeout_sec]'s RFC-0345 fallback): a reasonable
      total-call ceiling depends on provider and workload (tool-heavy turns
      legitimately run minutes between chunks), so MASC does not guess one.
      The operator sets it from measured turn durations.

      On expiry the caller classifies the failure as the existing typed
      [Api (Timeout { phase = Some Wall_clock })] and routes it through the
      existing declared-lane rotation — no new recovery mechanism.

      Range when set: [30, 3600] — wider than [body_timeout_sec_override]'s
      [10, 600] on purpose: this bounds an entire agentic turn's provider
      call, not one HTTP body read.

      Env: [MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC]. Default: unset -> [None].
      @category Timeouts
      @ops_class operator *)
  let provider_call_deadline_sec_override_live () =
    match
      Env_config_core.raw_value_opt "MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC"
    with
    | Some raw ->
      (match Float.of_string_opt (String.trim raw) with
       | Some v -> Some (Float.max 30.0 (Float.min 3600.0 v))
       | None -> None)
    | None -> None
  ;;

  let provider_call_deadline_sec_override =
    provider_call_deadline_sec_override_live ()
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
  (** Stage timing ring buffer size for Phase 0 profiling.
      Default: 100. Range: [10, 1000]. *)
  let stage_timing_ring_size =
    max 10 (min 1000 (get_int ~default:100 "MASC_KEEPER_STAGE_TIMING_RING_SIZE"))
  ;;
end

(** {1 Dashboard Health Thresholds}

    Thresholds used by the dashboard keeper health scorer and harness health
    panels. These affect UI display only. *)

module DashboardHealth = struct
  let runtime_warning_ctx_ratio =
    get_float ~default:0.95 "MASC_DASHBOARD_RUNTIME_WARNING_CTX_RATIO"
  ;;
end

(* MASC_KEEPER_RUNTIME_PROVIDER_ALLOWLIST (KeeperRuntimeProviderFilter) was
   deleted (audit F8): its value was threaded as [?provider_filter] into
   [Keeper_turn_driver.run_named], which silently ignored it after the RFC-0206
   single-runtime purge. The knob was dead while its docs were live; deletion
   documents reality. Provider selection is runtime.toml SSOT
   ([runtime].default / [[runtime.assignments]]). *)

(** Print configuration summary for debugging *)
