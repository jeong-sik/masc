(* Keeper_registry_types_failure — failure reason types and helpers.
   Extracted from keeper_registry_types.ml during godfile decomposition.
   Contains kill-class type re-exports, failure_reason ADT, cohort key,
   and stale watchdog failure classification. *)

type stale_kill_class = Keeper_registry_types_kill_class.stale_kill_class =
  | Idle_turn of { stall_seconds : float }
  | Mid_turn_no_progress of
      { active_seconds : float
      ; since_progress_seconds : float
      ; progress_timeout_threshold : float
      ; last_progress_kind : string option
      }
  | Noop_failure_loop of { noop_count : int }

let progress_kind_label = Keeper_registry_types_kill_class.progress_kind_label
let stale_kill_class_to_string =
  Keeper_registry_types_kill_class.stale_kill_class_to_string

(** Issue #18901: Cause carried inside [Fiber_unresolved].
    Forces emit sites to distinguish graceful shutdown (SIGTERM/SIGINT
    racing the supervisor finally) from genuine missed-resolution.
    Without this payload both collapsed into a single ERROR-level
    crash_log row and supervisor pause cohort, inflating the 24h
    "27 keeper crashes" count to 100% noise on shutdown days. *)
type fiber_drop_cause =
  | Graceful_shutdown
  (** Supervisor saw shutdown in progress (flag, cancel context, or
            explicit shutdown reason). Emitted at INFO severity, does not
            authorize a lifecycle transition or trigger runtime enrichment. *)
  | Cancelled_by_parent
  (** Fiber observed [Eio.Cancel.Cancelled] from a parent switch
            (supervisor restart, sibling failure propagating cancel)
            while shutdown was not in progress. Operationally a transient
            cancel that the supervisor itself triggered. Emitted at WARN
            severity as a separate cohort from [Unexpected], the genuine
            missed-resolution bug. *)
  | Unexpected
  (** Fiber finally ran with [resolved=false] outside any shutdown
            context and without a parent cancellation signal. Genuine
            missed-resolution bug. Emitted at ERROR severity. Drives the
            existing [cohort=fiber_unresolved] supervisor pause path. *)

type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Stale_turn_timeout of stale_kill_class
  | Stale_termination_storm of { count : int }
  (** #10765 Phase 2: latched when [record_stale_termination] returns a
          window count >= [escalation_threshold]. This remains a typed
          observation; the supervisor restarts only the affected Keeper. *)
  | Stale_fleet_batch of { distinct_count : int }
  (** Legacy wire value for stale watchdog fleet-batch state. Current
          fleet-batch detection is observation-only and must not create this
          failure reason; if old runtime state still contains it, the
          supervisor treats it like a restartable watchdog crash. *)
  | Provider_runtime_error of
      { code : string
      ; detail : string
      ; provider_id : string option
      ; http_status : int option
      ; runtime_id : string option
      ; reason : Keeper_meta_contract.runtime_exhaustion_reason option
          (** Typed runtime-exhaustion reason, [Some] only on the
              runtime-exhausted construction path
              ([keeper_unified_turn_types.runtime_exhausted_failure_reason_of_raw_error]).
              Lets the supervisor decide retryability via
              [Keeper_meta_contract.runtime_exhaustion_reason_retryable]
              instead of reparsing [code]. [None] for non-exhaustion
              provider/runtime errors. *)
      }
  | Fiber_unresolved of fiber_drop_cause
  (** Fiber exited without resolving [done_r].
          Issue #18901: cause payload distinguishes graceful shutdown
          artifacts (SIGTERM/SIGINT during turn — INFO severity, no
          runtime) from genuine missed-resolution bugs (ERROR severity,
          runtime attempt enrichment + per-Keeper restart). Compile-time
          exhaustive match forces the emit site to commit to a cause
          rather than letting a race between [Shutdown.is_shutting_down_global]
          flag and fiber finally collapse both into the same telemetry. *)
  | Exception of string
  | Turn_overflow_failure
  | Operator_interrupt

let failure_reason_to_string = function
  | Heartbeat_consecutive_failures n ->
    Printf.sprintf "heartbeat_consecutive_failures(%d)" n
  | Turn_consecutive_failures n -> Printf.sprintf "turn_consecutive_failures(%d)" n
  | Stale_turn_timeout cls ->
    Printf.sprintf "stale_turn_timeout(%s)" (stale_kill_class_to_string cls)
  | Stale_termination_storm { count } ->
    Printf.sprintf "stale_termination_storm(count=%d)" count
  | Stale_fleet_batch { distinct_count } ->
    Printf.sprintf "stale_fleet_batch(distinct_count=%d)" distinct_count
  | Provider_runtime_error { code; detail; provider_id; http_status; runtime_id = _ } ->
    let prov =
      Option.fold provider_id ~none:""
        ~some:(Printf.sprintf " provider=%s")
    in
    let http =
      Option.fold http_status ~none:""
        ~some:(Printf.sprintf " http=%d")
    in
    Printf.sprintf "provider_runtime_error(%s:%s%s%s)" code detail prov http
  | Fiber_unresolved Graceful_shutdown -> "fiber_unresolved(graceful_shutdown)"
  | Fiber_unresolved Cancelled_by_parent -> "fiber_unresolved(cancelled_by_parent)"
  | Fiber_unresolved Unexpected -> "fiber_unresolved"
  (* Backward-compat string form: [Unexpected] preserves the legacy
     "fiber_unresolved" wire value so existing log-line / dashboard
     greps and persisted crash_log rows continue to match. Graceful
     and cancelled-by-parent variants get distinct suffixes so 24h
     fleet audits can split the noise:signal ratio (Issue #18901) and
     supervisor restart/back-off can treat parent-cancel differently
     from genuine missed-resolution. *)
  | Exception s -> Printf.sprintf "exception(%s)" s
  | Turn_overflow_failure -> "turn_overflow_failure"
  | Operator_interrupt -> "operator_interrupt"
;;

(** #10584: cohort key for grouping failures by variant, ignoring
    parameters (e.g. failure count, timeout seconds).  Lives next to
    [failure_reason_to_string] in the source-of-truth module so any
    new variant added to [failure_reason] forces a same-PR update of
    BOTH conversion arms — the consumer in keeper_supervisor (and
    any other dashboard / metrics call site) just delegates here.
    This is Option B from #10584: avoid the recurring-P0 pattern
    where consumer-side exhaustive matches catch up to upstream
    variant additions only after the warn-error build trip. *)
let failure_reason_cohort_key = function
  | Some (Heartbeat_consecutive_failures _) -> "heartbeat_failures"
  | Some (Turn_consecutive_failures _) -> "turn_failures"
  | Some (Stale_turn_timeout _) -> "stale_turn_timeout"
  | Some (Stale_termination_storm _) -> "stale_termination_storm"
  | Some (Stale_fleet_batch _) -> "stale_fleet_batch"
  | Some (Provider_runtime_error _) -> "provider_runtime_error"
  | Some (Fiber_unresolved Graceful_shutdown) -> "fiber_unresolved_graceful"
  | Some (Fiber_unresolved Cancelled_by_parent) -> "fiber_unresolved_cancelled"
  | Some (Fiber_unresolved Unexpected) -> "fiber_unresolved"
  (* Graceful shutdown and parent cancellation stay distinct from an unexpected
     unresolved fiber for dashboard and metric observation. *)
  | Some (Exception _) -> "exception"
  | Some Turn_overflow_failure -> "turn_overflow_failure"
  | Some Operator_interrupt -> "operator_interrupt"
  | None -> "unknown"
;;

let stale_kill_failure_reason ~prior ~kill_class =
  match prior with
  | Some
      ( Provider_runtime_error _
      | Turn_consecutive_failures _
      | Turn_overflow_failure
      | Heartbeat_consecutive_failures _
      | Exception _
      | Operator_interrupt ) -> prior
  | Some
      ( Stale_termination_storm _
      | Stale_fleet_batch _
      | Stale_turn_timeout _
      | Fiber_unresolved _ )
  | None -> Some (Stale_turn_timeout kill_class)
;;
