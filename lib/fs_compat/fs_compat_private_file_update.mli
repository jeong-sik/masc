(** Private file updates of [Fs_compat]: the recovery and locking types, the
    durable update, reconcile and rewrite entry points of a private file under
    its path lock, the private JSONL append error, the incomplete-tail
    truncation, the appends with an expected end offset, [append_jsonl] and
    [append_jsonl_batch]. [Fs_compat] includes this module. *)
open Fs_compat_durable_append
open Fs_compat_private_jsonl_transaction

type 'a private_jsonl_recovery_validation =
  | Recovery_authorized
  | Recovery_refused of 'a

type private_file_locking = Wait_for_lock | Try_lock

type 'a private_file_decision =
  | Refuse_update of 'a
  | Confirm_existing of 'a
  | Append_confirmed of string * 'a

val reconcile_private_file_durable_locked_with_append_io_for_testing :
  append_io:durable_append_io_for_testing -> string ->
  (string -> 'a private_file_decision) ->
  ('a, durable_append_error) private_file_transaction_outcome

val reconcile_private_file_durable_locked_result :
  ?locking:private_file_locking -> string -> (string -> 'a private_file_decision) ->
  ('a, durable_append_error) private_file_transaction_outcome

val update_private_file_durable_locked_result :
  ?create:bool ->
  string ->
  (string -> string option * 'a) ->
  ('a, durable_append_error) private_file_transaction_outcome

type 'kept private_jsonl_rows_read =
  | Rows_after_cursor of 'kept
  | Rows_from_start

type 'kept private_jsonl_rows_from_cursor =
  { read : 'kept private_jsonl_rows_read
  ; rows : string
  ; rows_end : Private_jsonl_cursor.t
  }

val update_private_jsonl_after_cursor_durable_locked_result :
  ?create:bool ->
  string ->
  after:(Private_jsonl_cursor.t * 'kept) option ->
  ('kept private_jsonl_rows_from_cursor -> string option * 'a) ->
  ('a, durable_append_error) private_file_transaction_outcome

val update_private_file_tail_durable_locked_result :
  string ->
  max_bytes:int ->
  (string -> string option * 'a) ->
  ('a, durable_append_error) private_file_transaction_outcome

val update_private_file_tail_durable_locked_with_append_io_for_testing :
  append_io:durable_append_io_for_testing ->
  string ->
  max_bytes:int ->
  (string -> string option * 'a) ->
  ('a, durable_append_error) private_file_transaction_outcome

val recover_and_update_private_jsonl_durable_locked_result :
  ?create:bool ->
  ?locking:private_file_locking ->
  validate_prefix:(string -> 'a private_jsonl_recovery_validation) ->
  string -> (string -> string option * 'a) ->
  ('a, durable_append_error) private_file_transaction_outcome

val update_private_file_durable_locked_with_io_for_testing :
  ?create:bool ->
  io:private_jsonl_transaction_io_for_testing ->
  string ->
  (string -> string option * 'a) ->
  ('a, durable_append_error) private_file_transaction_outcome

val update_existing_private_file_durable_locked_result :
  string ->
  (string -> string option * 'a) ->
  ('a option, private_jsonl_transaction_error) private_file_transaction_outcome

val update_existing_private_file_durable_locked_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string ->
  (string -> string option * 'a) ->
  ('a option, private_jsonl_transaction_error) private_file_transaction_outcome

val rewrite_private_file_durable_locked_result :
  string -> (string -> string option * 'a) -> ('a, string) result

type private_jsonl_append_error =
  | Incomplete_jsonl_tail
  | Incomplete_jsonl_tail_truncate_failed of durable_append_failure
  | Existing_jsonl_refused of string
  | Invalid_jsonl_suffix
  | Negative_expected_end_offset of int
  | End_offset_mismatch of
      { expected : int
      ; actual : int
      }
  | Durable_jsonl_append_failed of durable_append_error

val private_jsonl_append_error_to_string : private_jsonl_append_error -> string

val append_private_jsonl_durable_locked_with_end_offset_result :
  string ->
  string ->
  (int, private_jsonl_append_error) private_file_transaction_outcome

val append_private_jsonl_durable_locked_at_end_offset_result :
  string ->
  expected_end_offset:int ->
  string ->
  (int, private_jsonl_append_error) private_file_transaction_outcome

val append_private_jsonl_durable_locked_result :
  string ->
  string ->
  (unit, private_jsonl_append_error) private_file_transaction_outcome

val append_private_jsonl_durable_locked_validated_result :
  validate_first_row:(string -> (unit, string) result) ->
  string -> string ->
  (unit, private_jsonl_append_error) private_file_transaction_outcome

val append_private_jsonl_durable_locked_at_end_offset_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string ->
  expected_end_offset:int ->
  string ->
  (int, private_jsonl_append_error) private_file_transaction_outcome

val append_jsonl : string -> Yojson.Safe.t -> unit

val append_jsonl_batch : string -> Yojson.Safe.t list -> unit
