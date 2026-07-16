(** Current compaction reducer/append facade over generic Keeper operation
    records. The single-writer implementation migrates separately. *)
module Record = Keeper_operation_record
module Cursor = Record.Cursor
module Projection = Keeper_compaction_operation_projection
type row = Record.row
type operation_entry = Projection.operation_entry =
  { snapshot : Keeper_compaction_operation_reducer.snapshot
  ; requested_at : float
  ; request_cursor : Cursor.t
  }
type replay = { operations : operation_entry list; end_cursor : Cursor.t }
type slice = { rows : row list; end_cursor : Cursor.t }
type t
type event_rejection = Projection.rejection =
  | Cursor_mismatch of
      { expected : Cursor.t
      ; actual : Cursor.t
      }
  | Transition_rejected of Keeper_compaction_operation_reducer.transition_error
  | Keeper_mismatch of
      { expected : Keeper_id.Keeper_name.t
      ; actual : Keeper_id.Keeper_name.t
      }
  | Producer_already_bound of
      { producer : Keeper_compaction_operation.producer_ref
      ; existing_operation_id : Keeper_compaction_operation.Operation_id.t
      }
type history_error =
  | Invalid_record of Record.decode_error
  | Rejected_row of
      { row_number : int
      ; start_cursor : Cursor.t
      ; end_cursor : Cursor.t
      ; rejection : event_rejection
      }
type read_error =
  | Read_failed of Fs_compat.Private_jsonl_slice.error
  | Invalid_history of history_error
type transaction_error =
  | Cursor_conflict of
      { expected : Cursor.t
      ; actual : Cursor.t
      }
  | Committed_cursor_mismatch of
      { expected : Cursor.t
      ; actual : Cursor.t
      }
  | Not_committed of Fs_compat.durable_append_error
  | Outcome_unknown of Fs_compat.durable_append_error
  | Storage_rejected of Fs_compat.private_jsonl_append_error
  | Access_failed of exn
type append_error =
  | Encode_failed of Record.envelope_error
  | Event_rejected of event_rejection
  | Transaction_error of transaction_error
val journal_path :
  base_path:string -> keeper_name:Keeper_id.Keeper_name.t -> string
val replay :
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t ->
  (replay, read_error) result
val open_writer :
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t ->
  (t, read_error) result
val operations : t -> operation_entry list
val end_cursor : t -> Cursor.t
val read_slice :
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t ->
  from:Cursor.t ->
  (slice, read_error) result
(** Structural decode only; it never invents prior reducer state. *)
val append :
  t ->
  recorded_at:float ->
  Keeper_compaction_operation.event ->
  (t * row, append_error) result
(** Validate against the immutable projection, then append at its exact durable
    end cursor. A successful result is the only writer state that may admit the
    next event. A stale copied state receives [Cursor_conflict] without writing
    bytes. *)
