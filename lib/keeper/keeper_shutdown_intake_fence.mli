(** Per-Keeper lifecycle shutdown fence for durable external intake.

    Keeper Owner owns turn scheduling. This module owns only the mutex that
    orders Event Queue/registry durable intake against lifecycle shutdown. *)

type reservation =
  { operation_id : Keeper_shutdown_types.Operation_id.t }

type begin_result =
  | Reserved of reservation
  | Already_reserved of reservation

type rollback_result =
  | Rolled_back
  | Not_reserved
  | Reserved_by_other of Keeper_shutdown_types.Operation_id.t

type restore_result =
  | Restored
  | Already_restored
  | Restore_conflict of Keeper_shutdown_types.Operation_id.t

type transition_result =
  | Transition_applied
  | Transition_already_applied
  | Transition_reserved_by_other of Keeper_shutdown_types.Operation_id.t

type 'a registration_commit_result =
  | Registration_committed of 'a
  | Registration_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type 'a durable_intake_result =
  | Intake_committed of 'a
  | Intake_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type 'a transfer_intake_result =
  | Transfer_intake_committed of 'a
  | Transfer_intake_source_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Transfer_intake_target_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type intake_token

val begin_shutdown
  :  base_path:string
  -> keeper_name:string
  -> operation_id:Keeper_shutdown_types.Operation_id.t
  -> begin_result

val rollback_shutdown
  :  base_path:string
  -> keeper_name:string
  -> operation_id:Keeper_shutdown_types.Operation_id.t
  -> rollback_result

val restore_shutdown
  :  base_path:string
  -> keeper_name:string
  -> operation_id:Keeper_shutdown_types.Operation_id.t
  -> restore_result

val transition_shutdown
  :  base_path:string
  -> keeper_name:string
  -> from_operation_id:Keeper_shutdown_types.Operation_id.t
  -> to_operation_id:Keeper_shutdown_types.Operation_id.t option
  -> transition_result

val shutdown_operation_id
  :  base_path:string
  -> keeper_name:string
  -> Keeper_shutdown_types.Operation_id.t option

val commit_registration_if_open
  :  base_path:string
  -> keeper_name:string
  -> (unit -> 'a)
  -> 'a registration_commit_result

val run_durable_intake_if_open
  :  base_path:string
  -> keeper_name:string
  -> (intake_token -> 'a)
  -> 'a durable_intake_result

val run_durable_intake_observing
  :  base_path:string
  -> keeper_name:string
  -> (intake_token -> 'a)
  -> 'a * Keeper_shutdown_types.Operation_id.t option
(** Run the intake whatever the slot says, and report which shutdown operation
    held it, if any. A reservation records that a shutdown began; a shutdown
    that never finalises never releases it, so refusing on the reservation
    alone stops the caller forever. Callers that must not be stoppable use
    this and log what they observed. *)

val run_transfer_intake_if_open
  :  base_path:string
  -> from_keeper:string
  -> to_keeper:string
  -> (source_intake_token:intake_token ->
      target_intake_token:intake_token ->
      'a)
  -> 'a transfer_intake_result

val intake_token_matches
  :  intake_token
  -> base_path:string
  -> keeper_name:string
  -> bool

val await_idle_after_shutdown : base_path:string -> keeper_name:string -> unit
(** Join durable intake that preceded the shutdown fence. *)

module For_testing : sig
  val reset : unit -> unit
end
