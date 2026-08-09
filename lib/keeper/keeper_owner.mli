(** Single-fiber metadata owner for one Keeper.

    Producers communicate through a bounded mailbox.  [apply_meta],
    and [exact_projection] apply backpressure when the mailbox is full;
    commands are never dropped or coalesced. Once enqueued, a request settles
    before caller cancellation can release its surrounding authority scope.
    Routine reads use {!projection} and do not enter the mailbox. *)

val mailbox_capacity : int

type store =
  { replace : Keeper_meta_contract.keeper_meta -> (unit, string) result
  ; remove : Keeper_meta_contract.keeper_meta -> (unit, string) result
  }

module Chat_operation = Keeper_chat_operation

type operation_projection =
  { queued_count : int
  ; running_operation_id : Chat_operation.Operation_id.t option
  ; terminal_count : int
  }

type turn_lane =
  | Autonomous
  | Chat_operation
  | Maintenance

type turn_in_flight =
  { lane : turn_lane
  ; started_at : float
  }

type autonomous_block =
  | Turn_busy of turn_in_flight option
  | Shutdown_requested of Keeper_shutdown_types.Operation_id.t

type operation_acceptance =
  { operation : Chat_operation.t
  ; existing : bool
  ; queued_count : int
  }

type operation_error_kind =
  | Invalid_operation_input
  | Unknown_operation
  | Operation_not_queued
  | Operation_idempotency_conflict
  | Operation_store_unavailable

type error =
  | Reducer_rejected of Keeper_owner_reducer.error
  | Operation_rejected of Keeper_chat_operation_store.error
  | Store_unavailable of string
  | Owner_stopping
  | Owner_closed

type operation_execution =
  | Operation_succeeded of { outcome_ref : string }
  | Operation_failed of
      { kind : string
      ; detail : string
      ; outcome_ref : string option
      }

type operation_executor =
  sw:Eio.Switch.t ->
  keeper_name:string ->
  claim:(unit -> (Chat_operation.t option, error) result) ->
  operation_execution
(** One Owner-owned child execution. The executor must not cache an operation
    body before [claim]: [claim] is the mailbox-linearized Queued-to-Running
    boundary and returns the latest edited input. *)

type t

val start
  :  sw:Eio.Switch.t
  -> store:store
  -> operation_store_path:string
  -> now:(unit -> float)
  -> operation_executor:operation_executor option
  -> keeper_name:string
  -> initial_meta:Keeper_meta_contract.keeper_meta option
  -> (t, error) result

val projection : t -> Keeper_owner_reducer.projection
(** Lock-free immutable snapshot. *)

val operation_projection : t -> operation_projection
(** Lock-free immutable operation inventory. *)

val turn_in_flight : t -> turn_in_flight option
(** Lock-free immutable projection of the single Owner-owned child turn. *)

val autonomous_block_to_string : autonomous_block -> string
val autonomous_block_to_yojson : autonomous_block -> Yojson.Safe.t

val run_autonomous_if_idle
  :  t
  -> (unit -> 'a)
  -> ([ `Ran of 'a | `Busy of autonomous_block ], error) result
(** Mailbox-linearized autonomous admission. The callback runs in the Owner's
    child switch, while the actor remains responsive. A queued/running chat or
    another autonomous child returns [`Busy] without consuming turn input. *)

val run_maintenance_if_idle
  :  t
  -> (unit -> 'a)
  -> ([ `Ran of 'a | `Busy of autonomous_block ], error) result
(** Mailbox-linearized exclusive maintenance attempt. *)

val exact_projection
  :  t
  -> (Keeper_owner_reducer.projection, error) result
(** Mailbox-linearized projection for mutation and exact-operation paths. *)

val apply_meta
  :  t
  -> Keeper_owner_reducer.meta_command
  -> (Keeper_meta_contract.keeper_meta option, error) result

val exact_operation
  :  t
  -> Chat_operation.Operation_id.t
  -> (Chat_operation.t option, error) result

val submit_operation
  :  t
  -> operation_id:Chat_operation.Operation_id.t
  -> source:Yojson.Safe.t
  -> input:Yojson.Safe.t
  -> (operation_acceptance, error) result

val list_queued_operations
  :  t
  -> after_sequence:int64 option
  -> limit:int
  -> (Chat_operation.t list, error) result

val edit_queued_operation
  :  t
  -> operation_id:Chat_operation.Operation_id.t
  -> input:Yojson.Safe.t
  -> (Chat_operation.t, error) result

val move_queued_operation_to_end
  :  t
  -> Chat_operation.Operation_id.t
  -> (Chat_operation.t, error) result

val cancel_queued_operation
  :  t
  -> Chat_operation.Operation_id.t
  -> (Chat_operation.t, error) result

val claim_next_operation : t -> (Chat_operation.t option, error) result

val succeed_running_operation
  :  t
  -> operation_id:Chat_operation.Operation_id.t
  -> outcome_ref:string
  -> (Chat_operation.t, error) result

val fail_running_operation
  :  t
  -> operation_id:Chat_operation.Operation_id.t
  -> kind:string
  -> detail:string
  -> outcome_ref:string option
  -> (Chat_operation.t, error) result

val begin_stopping : t -> (unit, error) result
(** Reject new mutation and submit commands, cancel an active child turn, and
    return only after its terminal operation transition has been attempted. *)
(** Reject future external commands. *)

val error_to_string : error -> string
val operation_error_kind : Keeper_chat_operation_store.error -> operation_error_kind

module For_testing : sig
  val mailbox_depth : t -> int
end
