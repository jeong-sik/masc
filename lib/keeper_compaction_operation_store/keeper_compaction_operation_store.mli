(** Sole durable mutation facade for one Keeper's compaction operations. *)
module Record = Keeper_compaction_operation_record
module Cursor = Record.Cursor
type row = Record.row
type operation_entry =
  { snapshot : Keeper_compaction_operation_reducer.snapshot
  ; requested_at : float
  ; request_cursor : Cursor.t
  }
type replay = { operations : operation_entry list; end_cursor : Cursor.t }
type slice = { rows : row list; end_cursor : Cursor.t }
type event_rejection =
  | Transition_rejected of Keeper_compaction_operation_reducer.transition_error
  | Keeper_mismatch of
      { expected : Keeper_id.Keeper_name.t
      ; actual : Keeper_id.Keeper_name.t
      }
  | Producer_already_bound of
      { producer : Tool_invocation_ref.t
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
  | Not_committed of Fs_compat.durable_append_error
  | Outcome_unknown of Fs_compat.durable_append_error
  | Access_failed of exn
type append_error =
  | Encode_failed of Record.envelope_error
  | Existing_history_invalid of history_error
  | Event_rejected of event_rejection
  | Transaction_error of transaction_error
val journal_path :
  base_path:string -> keeper_name:Keeper_id.Keeper_name.t -> string
val replay :
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t ->
  (replay, read_error) result
val read_slice :
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t ->
  from:Cursor.t ->
  (slice, read_error) result
(** Structural decode only; it never invents prior reducer state. *)
val append :
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t ->
  recorded_at:float ->
  Keeper_compaction_operation.event ->
  (row, append_error) result
