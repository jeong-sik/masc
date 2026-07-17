(** Pure immutable read model for compaction rows in the Keeper operation
    journal. This module has no path, codec, or append authority. *)

module Operation = Keeper_compaction_operation
module Reducer = Keeper_compaction_operation_reducer
module Record = Keeper_operation_record
module Cursor = Record.Cursor

type operation_entry =
  { snapshot : Reducer.snapshot
  ; requested_at : float
  ; request_cursor : Cursor.t
  }

type rejection =
  | Cursor_mismatch of
      { expected : Cursor.t
      ; actual : Cursor.t
      }
  | Transition_rejected of Reducer.transition_error
  | Keeper_mismatch of
      { expected : Keeper_id.Keeper_name.t
      ; actual : Keeper_id.Keeper_name.t
      }
  | Producer_already_bound of
      { producer : Tool_invocation_ref.t
      ; existing_operation_id : Operation.Operation_id.t
      }

type replay_error =
  | Rejected_row of
      { row_number : int
      ; start_cursor : Cursor.t
      ; end_cursor : Cursor.t
      ; rejection : rejection
      }

type t

val empty : keeper_name:Keeper_id.Keeper_name.t -> t
val apply : t -> Operation.event Record.row -> (t, rejection) result
val replay :
  keeper_name:Keeper_id.Keeper_name.t ->
  Operation.event Record.row list ->
  (t, replay_error) result
val end_cursor : t -> Cursor.t
val operations : t -> operation_entry list
