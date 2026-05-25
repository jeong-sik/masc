(* Keeper_registry_types_failure — failure reason types and helpers.
   Extracted from keeper_registry_types.ml during godfile decomposition.
   Contains kill-class type re-exports, failure_reason ADT, cohort key,
   and stale watchdog failure classification. *)

(** Structured failure reason for cohort detection in self-preservation.
    ADT matching replaces string prefix matching for crash_msg grouping. *)
type ambiguous_partial_commit_kind =
  Keeper_registry_types_kill_class.ambiguous_partial_commit_kind =
  | Post_commit_timeout
  | Post_commit_failure

type ambiguous_partial_commit =
  Keeper_registry_types_kill_class.ambiguous_partial_commit =
  { kind : ambiguous_partial_commit_kind
  ; detail : string
  }

type stale_kill_class = Keeper_registry_types_kill_class.stale_kill_class =
  | Idle_turn of { stall_seconds : float }
  | In_turn_hung of
      { active_seconds : float
      ; timeout_threshold : float
      }
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

type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Stale_turn_timeout of stale_kill_class
  | Stale_termination_storm of { count : int }
  (** #10765 Phase 2: latched when [record_stale_termination] returns a
          window count >= [escalation_threshold]. The supervisor's
          [`Crashed] branch checks this variant and skips [to_restart],
          persisting [meta.paused = true] instead so an operator must
          investigate the underlying cascade/provider/fd issue before
          resuming the keeper. *)
  | Stale_fleet_batch of { distinct_count : int }
  (** Legacy wire value for stale watchdog fleet-batch state. Current
          fleet-batch detection is observation-only and must not create this
          failure reason; if old runtime state still contains it, the
          supervisor treats it like a restartable watchdog crash. *)
  | Provider_timeout_loop of { count : int }
  (** Latched when the same keeper exhausts the OAS turn budget on
          consecutive cycles. This is a provider/cascade/runtime throughput
          failure, so the supervisor pauses instead of restarting into the
          same slow model and burning another multi-minute budget. *)
  | Provider_runtime_error of
      { code : string
      ; detail : string
      ; provider_id : string option
      ; http_status : int option
      ; cascade_name : string option
      }
  | Tool_required_unsatisfied of
      { code : string
      ; detail : string
      }
  | Ambiguous_partial_commit of ambiguous_partial_commit
  | Fiber_unresolved
  | Exception of string
  | Turn_overflow_pause
  | Turn_livelock_pause

let ambiguous_partial_commit_kind_to_string =
  Keeper_registry_types_kill_class.ambiguous_partial_commit_kind_to_string

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
  | Provider_timeout_loop { count } ->
    Printf.sprintf "provider_timeout_loop(count=%d)" count
  | Provider_runtime_error { code; detail; provider_id; http_status; cascade_name = _ } ->
    let prov =
      Option.fold provider_id ~none:""
        ~some:(Printf.sprintf " provider=%s")
    in
    let http =
      Option.fold http_status ~none:""
        ~some:(Printf.sprintf " http=%d")
    in
    Printf.sprintf "provider_runtime_error(%s:%s%s%s)" code detail prov http
  | Tool_required_unsatisfied { code; detail } ->
    Printf.sprintf "tool_required_unsatisfied(%s:%s)" code detail
  | Ambiguous_partial_commit { kind; detail } ->
    Printf.sprintf
      "ambiguous_partial_commit(%s:%s)"
      (ambiguous_partial_commit_kind_to_string kind)
      detail
  | Fiber_unresolved -> "fiber_unresolved"
  | Exception s -> Printf.sprintf "exception(%s)" s
  | Turn_overflow_pause -> "turn_overflow_pause"
  | Turn_livelock_pause -> "turn_livelock_pause"
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
  | Some (Provider_timeout_loop _) -> "provider_timeout_loop"
  | Some (Provider_runtime_error _) -> "provider_runtime_error"
  | Some (Tool_required_unsatisfied _) -> "tool_required_unsatisfied"
  | Some (Ambiguous_partial_commit _) -> "ambiguous_partial_commit"
  | Some Fiber_unresolved -> "fiber_unresolved"
  | Some (Exception _) -> "exception"
  | Some Turn_overflow_pause -> "turn_overflow_pause"
  | Some Turn_livelock_pause -> "turn_livelock_pause"
  | None -> "unknown"
;;

let stale_watchdog_failure_reason ~prior ~kill_class =
  match prior with
  | Some
      ( Provider_timeout_loop _
      | Provider_runtime_error _
      | Tool_required_unsatisfied _
      | Ambiguous_partial_commit _
      | Turn_consecutive_failures _
      | Turn_overflow_pause
      | Turn_livelock_pause
      | Heartbeat_consecutive_failures _
      | Exception _ ) -> prior
  | Some
      ( Stale_termination_storm _
      | Stale_fleet_batch _
      | Stale_turn_timeout _
      | Fiber_unresolved )
  | None -> Some (Stale_turn_timeout kill_class)
;;
