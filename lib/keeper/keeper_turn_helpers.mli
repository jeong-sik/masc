(* Keeper_turn_helpers — string matching, event reporting, trajectory/receipt
   helpers, FSM guard post-actions, and local discovery readiness.

   Public sub-module included by [Keeper_unified_turn]. *)

open Keeper_meta_contract

val turn_event_bus_drain_interval_sec : unit -> float

val report_keeper_cycle_side_effect_issue :
  config:Workspace.config ->
  keeper_name:string ->
  side_effect:string ->
  ?severity:[< `Warn | `Error > `Warn ] ->
  string -> unit
(** Log and record a side-effect failure for a keeper cycle. *)

val finalize_trajectory_acc :
  config:Workspace.config ->
  keeper_name:string ->
  Trajectory.accumulator ->
  Trajectory.trajectory_outcome -> unit
(** Finalize a trajectory accumulator with the given outcome. Logs errors
    rather than raising (except cancellation). *)

val pre_dispatch_tool_surface : Keeper_execution_receipt.tool_surface
(** Default tool surface for pre-dispatch receipts (no tools dispatched). *)

val record_pre_dispatch_terminal_observation :
  config:Workspace.config ->
  meta:keeper_meta ->
  runtime_id:string ->
  outcome:Keeper_execution_receipt.outcome_kind ->
  terminal_reason_code:string ->
  activity_kind:string ->
  trajectory_outcome:Trajectory.trajectory_outcome ->
  ?error_kind:Keeper_execution_receipt.error_kind ->
  ?error_message:string ->
  ?keeper_turn_id:int ->
  unit -> unit
(** Record a terminal observation (receipt + activity graph event) for a
    pre-dispatch failure or early exit. *)
