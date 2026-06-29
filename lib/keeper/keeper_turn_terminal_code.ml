(* RFC-0042 PR-1: closed sum type for keeper turn terminal code.

   See [.mli] for the public contract. This file holds the type
   definition, the wire-format serialisation, and the canonical bridge
   from [Keeper_registry.failure_reason]. *)

type t =
  | Healthy
  | Stale_turn_timeout_idle
  | Stale_turn_timeout_in_turn
  | Stale_turn_timeout_no_progress
  | Stale_turn_timeout_noop
  | Stale_termination_storm
  | Stale_fleet_batch
  | Heartbeat_failures
  | Turn_failures
  | Provider_runtime_error of string
  | Ambiguous_partial_commit_post_commit_timeout
  | Ambiguous_partial_commit_post_commit_failure
  | Fiber_unresolved
  | Turn_overflow_pause
  | Turn_livelock_pause
  | Exception_unhandled of string
  | Sdk_error of string

let to_wire = function
  | Healthy -> "healthy"
  | Stale_turn_timeout_idle
  | Stale_turn_timeout_in_turn
  | Stale_turn_timeout_no_progress
  | Stale_turn_timeout_noop ->
    (* Existing wire emission collapses the three sub-classes into one
         cohort key. Preserved here so dashboards / Otel_metric_store labels do
         not see a sudden cardinality change at PR-3 cutover. *)
    "stale_turn_timeout"
  | Stale_termination_storm -> "stale_termination_storm"
  | Stale_fleet_batch -> "stale_fleet_batch"
  | Heartbeat_failures -> "heartbeat_failures"
  | Turn_failures -> "turn_failures"
  | Provider_runtime_error code -> code
  | Ambiguous_partial_commit_post_commit_timeout
  | Ambiguous_partial_commit_post_commit_failure -> "ambiguous_partial_commit"
  | Fiber_unresolved -> "fiber_unresolved"
  | Turn_overflow_pause -> "turn_overflow_pause"
  | Turn_livelock_pause -> "turn_livelock_pause"
  | Exception_unhandled _ -> "exception"
  | Sdk_error wire -> wire
;;

let of_wire = function
  | "healthy" -> Some Healthy
  | "stale_turn_timeout" ->
    (* Lossy: the wire string lost the sub-class. Canonicalise to
         [Stale_turn_timeout_in_turn], the terminal-code canonical for a
         stale turn whose kill-class sub-class was not preserved on the
         wire. PR-4 removes [of_wire] callers. *)
    Some Stale_turn_timeout_in_turn
  | "stale_termination_storm" -> Some Stale_termination_storm
  | "stale_fleet_batch" -> Some Stale_fleet_batch
  | "heartbeat_failures" -> Some Heartbeat_failures
  | "turn_failures" -> Some Turn_failures
  | "ambiguous_partial_commit" ->
    (* Lossy in the same way as [stale_turn_timeout]. Canonicalise
         to [Post_commit_timeout]. *)
    Some Ambiguous_partial_commit_post_commit_timeout
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "turn_overflow_pause" -> Some Turn_overflow_pause
  | "turn_livelock_pause" -> Some Turn_livelock_pause
  | "exception" -> Some (Exception_unhandled "")
  | _other ->
    (* Could be a [Provider_runtime_error] / [Tool_required_unsatisfied]
         original [code] string, or an unrecognised legacy code from a
         pre-RFC emit site. Returning [None] forces the caller to make
         the policy choice rather than silently mis-classifying. *)
    None
;;

let of_failure_reason : Keeper_registry.failure_reason -> t = function
  | Keeper_registry.Heartbeat_consecutive_failures _ -> Heartbeat_failures
  | Keeper_registry.Turn_consecutive_failures _ -> Turn_failures
  | Keeper_registry.Stale_turn_timeout (Keeper_registry.Idle_turn _) ->
    Stale_turn_timeout_idle
  | Keeper_registry.Stale_turn_timeout (Keeper_registry.Mid_turn_no_progress _) ->
    Stale_turn_timeout_no_progress
  | Keeper_registry.Stale_turn_timeout (Keeper_registry.Noop_failure_loop _) ->
    Stale_turn_timeout_noop
  | Keeper_registry.Stale_termination_storm _ -> Stale_termination_storm
  | Keeper_registry.Stale_fleet_batch _ -> Stale_fleet_batch
  | Keeper_registry.Provider_timeout_loop _ ->
    Provider_runtime_error "provider_timeout_loop"
  | Keeper_registry.Provider_runtime_error { code; _ } -> Provider_runtime_error code
  | Keeper_registry.Completion_contract_violation _ ->
    Provider_runtime_error "completion_contract_violation"
  | Keeper_registry.Ambiguous_partial_commit
      { kind = Keeper_registry.Post_commit_timeout; _ } ->
    Ambiguous_partial_commit_post_commit_timeout
  | Keeper_registry.Ambiguous_partial_commit
      { kind = Keeper_registry.Post_commit_failure; _ } ->
    Ambiguous_partial_commit_post_commit_failure
  | Keeper_registry.Fiber_unresolved _ -> Fiber_unresolved
  | Keeper_registry.Turn_overflow_pause -> Turn_overflow_pause
  | Keeper_registry.Turn_livelock_pause -> Turn_livelock_pause
  | Keeper_registry.Exception msg -> Exception_unhandled msg
;;

let of_failure_reason_option = function
  | Some fr -> of_failure_reason fr
  | None ->
    (* A stale keeper without a recorded failure reason still emits the
       stale-turn cohort. Canonicalise to [Stale_turn_timeout_in_turn],
       matching the lossy [of_wire] convention for ["stale_turn_timeout"]. *)
    Stale_turn_timeout_in_turn
;;

let of_sdk_error_wire wire = Sdk_error wire
