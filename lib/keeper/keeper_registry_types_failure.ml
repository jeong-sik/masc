(* Keeper_registry_types_failure — failure reason types and helpers.
   Extracted from keeper_registry_types.ml during godfile decomposition.
   Contains the failure_reason ADT and its cohort key. *)

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
  | Stale_termination_storm of { count : int }
  (** #10765 Phase 2: latched when [record_stale_termination] returns a
          window count >= [escalation_threshold]. This remains a typed
          observation; the supervisor restarts only the affected Keeper. *)
  | Provider_runtime_error of
      { code : string
      ; detail : string
      ; provider_id : string option
      ; http_status : int option
      ; runtime_id : string option
      ; agent_core_timeout : Keeper_turn_terminal_code.agent_core_timeout option
          (** Typed timeout observation carried from the terminal code
              (RFC-0371 §6.1(3)); [Some] only on the Provider_error
              construction path where the original agent-core error was in
              hand. Lets consumers classify timeouts without re-parsing
              [code]. [None] on rehydrated or non-agent-core paths. *)
      ; reason : Keeper_meta_contract.runtime_exhaustion_reason option
          (** Typed runtime-exhaustion reason, [Some] only on the
              runtime-exhausted construction path
              ([keeper_unified_turn_types.runtime_exhausted_failure_reason_of_raw_error]).
              Lets the supervisor decide retryability via
              [Keeper_meta_contract.runtime_exhaustion_reason_retryable]
              instead of reparsing [code]. [None] for non-exhaustion
              provider/runtime errors. *)
      }
  | Turn_configuration_error of
      { code : string
      ; field : string option
      ; detail : string
      }
  (** A typed Agent Core configuration error that cannot recover without a
      configuration or process-environment change. Kept separate from
      provider runtime failures so health can require operator action without
      parsing rendered error text. *)
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
  | Stale_termination_storm { count } ->
    Printf.sprintf "stale_termination_storm(count=%d)" count
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
  | Turn_configuration_error { code; field; detail } ->
    let field = Option.fold field ~none:"" ~some:(Printf.sprintf " field=%s") in
    Printf.sprintf "turn_configuration_error(%s:%s%s)" code detail field
  | Fiber_unresolved Graceful_shutdown -> "fiber_unresolved(graceful_shutdown)"
  | Fiber_unresolved Cancelled_by_parent -> "fiber_unresolved(cancelled_by_parent)"
  | Fiber_unresolved Unexpected -> "fiber_unresolved(unexpected)"
  | Exception s -> Printf.sprintf "exception(%s)" s
  | Turn_overflow_failure -> "turn_overflow_failure"
  | Operator_interrupt -> "operator_interrupt"
;;
