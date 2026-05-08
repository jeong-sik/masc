(* RFC-0042 PR-1: closed sum type for keeper turn terminal code.

   See [.mli] for the public contract. This file holds the type
   definition, the wire-format serialisation chosen to be byte-for-byte
   compatible with [Keeper_execution_receipt.stale_terminal_reason_code]
   as of main, and the canonical bridge from
   [Keeper_registry.failure_reason]. *)

type t =
  | Healthy
  | Stale_turn_timeout_idle
  | Stale_turn_timeout_in_turn
  | Stale_turn_timeout_noop
  | Stale_termination_storm
  | Stale_fleet_batch
  | Oas_timeout_budget
  | Heartbeat_failures
  | Turn_failures
  | Provider_runtime_error of string
  | Tool_required_unsatisfied of string
  | Ambiguous_partial_commit_post_commit_timeout
  | Ambiguous_partial_commit_post_commit_failure
  | Fiber_unresolved
  | Exception_unhandled of string
  | Sdk_error of string

let to_wire = function
  | Healthy -> "healthy"
  | Stale_turn_timeout_idle | Stale_turn_timeout_in_turn | Stale_turn_timeout_noop ->
    (* Existing wire emission collapses the three sub-classes into one
         cohort key. Preserved here so dashboards / Prometheus labels do
         not see a sudden cardinality change at PR-3 cutover. *)
    "stale_turn_timeout"
  | Stale_termination_storm -> "stale_termination_storm"
  | Stale_fleet_batch -> "stale_fleet_batch"
  | Oas_timeout_budget -> "oas_timeout_budget"
  | Heartbeat_failures -> "heartbeat_failures"
  | Turn_failures -> "turn_failures"
  | Provider_runtime_error code -> code
  | Tool_required_unsatisfied code -> code
  | Ambiguous_partial_commit_post_commit_timeout
  | Ambiguous_partial_commit_post_commit_failure -> "ambiguous_partial_commit"
  | Fiber_unresolved -> "fiber_unresolved"
  | Exception_unhandled _ -> "exception"
  | Sdk_error wire -> wire
;;

let of_wire = function
  | "healthy" -> Some Healthy
  | "stale_turn_timeout" ->
    (* Lossy: the wire string lost the sub-class. Canonicalise to
         [In_turn_hung] (the most common observed sub-class in
         production traces). PR-4 removes [of_wire] callers. *)
    Some Stale_turn_timeout_in_turn
  | "stale_termination_storm" -> Some Stale_termination_storm
  | "stale_fleet_batch" -> Some Stale_fleet_batch
  | "oas_timeout_budget" -> Some Oas_timeout_budget
  | "heartbeat_failures" -> Some Heartbeat_failures
  | "turn_failures" -> Some Turn_failures
  | "ambiguous_partial_commit" ->
    (* Lossy in the same way as [stale_turn_timeout]. Canonicalise
         to [Post_commit_timeout]. *)
    Some Ambiguous_partial_commit_post_commit_timeout
  | "fiber_unresolved" -> Some Fiber_unresolved
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
  | Keeper_registry.Stale_turn_timeout (Keeper_registry.In_turn_hung _) ->
    Stale_turn_timeout_in_turn
  | Keeper_registry.Stale_turn_timeout (Keeper_registry.Noop_failure_loop _) ->
    Stale_turn_timeout_noop
  | Keeper_registry.Stale_termination_storm _ -> Stale_termination_storm
  | Keeper_registry.Stale_fleet_batch _ -> Stale_fleet_batch
  | Keeper_registry.Oas_timeout_budget_loop _ -> Oas_timeout_budget
  | Keeper_registry.Provider_runtime_error { code; _ } -> Provider_runtime_error code
  | Keeper_registry.Tool_required_unsatisfied { code; _ } ->
    Tool_required_unsatisfied code
  | Keeper_registry.Ambiguous_partial_commit
      { kind = Keeper_registry.Post_commit_timeout; _ } ->
    Ambiguous_partial_commit_post_commit_timeout
  | Keeper_registry.Ambiguous_partial_commit
      { kind = Keeper_registry.Post_commit_failure; _ } ->
    Ambiguous_partial_commit_post_commit_failure
  | Keeper_registry.Fiber_unresolved -> Fiber_unresolved
  | Keeper_registry.Exception msg -> Exception_unhandled msg
;;

let of_failure_reason_option = function
  | Some fr -> of_failure_reason fr
  | None ->
    (* Legacy [stale_terminal_reason_code None] emitted "stale_turn_timeout".
       Canonical sub-class for that wire string is [In_turn_hung] (see
       [of_wire]); we reuse it here so [to_wire (of_failure_reason_option None)]
       is byte-for-byte equal to the pre-RFC default. *)
    Stale_turn_timeout_in_turn
;;

let of_sdk_error_wire wire = Sdk_error wire
