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

type t

val start
  :  sw:Eio.Switch.t
  -> store:store
  -> operation_store_path:string
  -> now:(unit -> float)
  -> keeper_name:string
  -> initial_meta:Keeper_meta_contract.keeper_meta option
  -> (t, error) result

val projection : t -> Keeper_owner_reducer.projection
(** Lock-free immutable snapshot. *)

val operation_projection : t -> operation_projection
(** Lock-free immutable operation inventory. *)

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
(** Reject future external commands. *)

val error_to_string : error -> string
val operation_error_kind : Keeper_chat_operation_store.error -> operation_error_kind

module For_testing : sig
  val mailbox_depth : t -> int
end
