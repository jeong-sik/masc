(* Keeper_turn_helpers — string matching, event reporting, trajectory/receipt
   helpers, FSM guard post-actions, and local discovery readiness.

   Public sub-module included by [Keeper_unified_turn]. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

(** Interval (seconds) for the per-turn background fiber that drains the
    [keeper_turn] subscription on the OAS event bus. *)
val default_turn_event_bus_drain_interval_sec : float

val turn_event_bus_drain_interval_sec : unit -> float

val string_contains_substring : needle:string -> string -> bool
(** Delegates to [String_util.string_contains_substring]. *)

val string_contains_substring_ci : needle:string -> string -> bool
(** Delegates to [String_util.string_contains_substring_ci]. *)

val report_keeper_cycle_side_effect_issue :
  config:Workspace.config ->
  keeper_name:string ->
  side_effect:string ->
  ?severity:[< `Warn | `Error > `Warn ] ->
  string -> unit
(** Log and record a side-effect failure for a keeper cycle. *)

val dispatch_keeper_phase_event_checked :
  config:Workspace.config ->
  keeper_name:string ->
  side_effect:string ->
  Keeper_state_machine.event -> unit
(** Dispatch a phase event and log on error instead of raising. *)

val finalize_trajectory_acc :
  config:Workspace.config ->
  keeper_name:string ->
  Trajectory.accumulator ->
  Trajectory.trajectory_outcome -> unit
(** Finalize a trajectory accumulator with the given outcome. Logs errors
    rather than raising (except cancellation). *)

val record_execution_receipt_gap :
  config:Workspace.config ->
  meta:keeper_meta ->
  stale_reason:string ->
  error:string ->
  unit -> unit
(** Record a coverage gap when an execution receipt could not be appended. *)

val post_assign_task : any_pending:bool -> channel:string -> unit
(** FSM guard post-action for [AssignTask]. *)

val post_empty_queue_sleep : any_pending:bool -> channel:string -> unit
(** FSM guard post-action for [EmptyQueueSleep]. *)

val post_turn_complete_task : cycle_completed:bool -> unit
(** FSM guard post-action for [TurnComplete]. *)

val pre_dispatch_tool_surface : Keeper_execution_receipt.tool_surface
(** Default tool surface for pre-dispatch receipts (no tools dispatched). *)

val record_pre_dispatch_terminal_observation :
  config:Workspace.config ->
  meta:keeper_meta ->
  generation:int ->
  runtime_id:string ->
  outcome:Keeper_execution_receipt.outcome_kind ->
  terminal_reason_code:string ->
  activity_kind:string ->
  trajectory_outcome:Trajectory.trajectory_outcome ->
  ?error_kind:Keeper_execution_receipt.error_kind ->
  ?error_message:string ->
  ?degraded_retry_applied:bool ->
  ?degraded_retry_runtime:string ->
  ?fallback_reason:Keeper_error_classify.degraded_retry_reason ->
  ?runtime_rotation_attempts:Keeper_execution_receipt.runtime_rotation_attempt list ->
  ?keeper_turn_id:int ->
  unit -> unit
(** Record a terminal observation (receipt + activity graph event) for a
    pre-dispatch failure or early exit. *)

val ensure_local_discovery_ready :
  ?refresh:(string list -> bool) ->
  string list ->
  (unit, string) result
(** Ensure local-provider discovery is refreshed before a turn when the
    selected labels depend on runtime discovery. *)

module For_testing : sig
  val with_local_discovery_refresh :
    (string list -> bool) -> (unit -> 'a) -> 'a
  (** Install a scoped refresh override and force the discovery branch for
      deterministic preflight tests. *)
end
