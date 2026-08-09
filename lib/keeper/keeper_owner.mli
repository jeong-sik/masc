(** Single-fiber owner for one Keeper.

    Producers communicate through a bounded mailbox.  [apply_meta],
    [exact_projection], and [start_turn] apply backpressure when the mailbox is
    full; commands are never dropped or coalesced.  Routine reads use
    {!projection} and do not enter the mailbox. *)

val mailbox_capacity : int

type store =
  { replace : Keeper_meta_contract.keeper_meta -> (unit, string) result
  ; remove : Keeper_meta_contract.keeper_meta -> (unit, string) result
  }

type error =
  | Reducer_rejected of Keeper_owner_reducer.error
  | Operation_rejected of Keeper_chat_operation_store.error
  | Store_unavailable of string
  | Owner_closed

type turn_start =
  | Started of turn_handle
  | Busy of { running_operation_id : string }

and turn_terminal =
  | Turn_succeeded
  | Turn_failed of string
  | Turn_cancelled

and turn_handle

type operation_terminal =
  | Operation_succeeded of
      { completed_at : float
      ; outcome_ref : string
      }
  | Operation_failed of
      { completed_at : float
      ; kind : Keeper_chat_operation_store.failure_kind
      ; detail : string
      ; outcome_ref : string option
      }

type operation_turn_start =
  | Operation_started of
      { operation : Keeper_chat_operation_store.operation
      ; handle : turn_handle
      }
  | Operation_queue_empty
  | Operation_busy of { running_operation_id : string }

type t

val start
  :  sw:Eio.Switch.t
  -> store:store
  -> base_path:string
  -> keeper_name:string
  -> initial_meta:Keeper_meta_contract.keeper_meta option
  -> (t, error) result

val projection : t -> Keeper_owner_reducer.projection
(** Lock-free immutable snapshot. *)

val exact_projection
  :  t
  -> (Keeper_owner_reducer.projection, error) result
(** Mailbox-linearized projection for mutation and exact-operation paths. *)

val apply_meta
  :  t
  -> Keeper_owner_reducer.meta_command
  -> (Keeper_meta_contract.keeper_meta option, error) result

val submit_operation
  :  t
  -> operation_id:string
  -> Keeper_chat_operation_store.input
  -> (Keeper_chat_operation_store.submit_result, error) result

val lookup_operation
  :  t
  -> operation_id:string
  -> (Keeper_chat_operation_store.operation, error) result

val list_queued_operations
  :  t
  -> after_sequence:int64 option
  -> limit:int
  -> (Keeper_chat_operation_store.operation list, error) result

val edit_operation
  :  t
  -> operation_id:string
  -> Keeper_chat_operation_store.edit_input
  -> (Keeper_chat_operation_store.operation, error) result

val move_operation_to_end
  :  t
  -> operation_id:string
  -> (Keeper_chat_operation_store.operation, error) result

val cancel_operation
  :  t
  -> operation_id:string
  -> completed_at:float
  -> (Keeper_chat_operation_store.operation, error) result

val start_next_queued_turn
  :  t
  -> started_at:float
  -> run:
       (Eio.Switch.t ->
        Keeper_chat_operation_store.operation ->
        operation_terminal)
  -> (operation_turn_start, error) result
(** Linearize the FIFO durable [Queued -> Running] claim, reducer turn
    admission, and child fork in one actor command. The child returns only
    after transcript and connector terminal effects; the actor alone commits
    the operation terminal state. *)

val start_turn
  :  t
  -> operation_id:string
  -> run:(Eio.Switch.t -> unit)
  -> (turn_start, error) result
(** Admit one child turn and return after actor admission, without waiting for
    the child.  A child exception is contained by the owner and releases the
    running slot. *)

val await_turn : turn_handle -> turn_terminal
val turn_handle_operation_id : turn_handle -> string

val begin_stopping : t -> (unit, error) result
(** Reject future external mutations, cancel the active child under its
    actor-owned switch, and join its typed terminal settlement before
    returning. The root switch remains the actor lifetime authority. *)

val error_to_string : error -> string

module For_testing : sig
  val start
    :  sw:Eio.Switch.t
    -> store:store
    -> keeper_name:string
    -> initial_meta:Keeper_meta_contract.keeper_meta option
    -> (t, error) result

  val mailbox_depth : t -> int
  val startup_interrupted_count : t -> int
end
