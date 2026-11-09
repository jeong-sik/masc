(** Private JSONL writes of [Fs_compat]: [Private_jsonl_absence], the purge,
    read-locked, recover, replace, append and rewrite entry points under the
    stable lock, and their test hooks. [Fs_compat] includes this module. *)
open Fs_compat_private_jsonl_transaction

module Private_jsonl_absence :
  sig
    type error =
        Binding_refused of
          private_jsonl_transaction_error
      | Operation_failed of
          private_jsonl_operation_failure
    val check : string -> (unit, error) result
  end

val private_jsonl_open_existing :
  close_fd:(Unix.file_descr -> unit) ->
  string ->
  Unix.open_flag list ->
  (Unix.file_descr option,
   private_jsonl_transaction_error)
  result

val purge_private_jsonl_durable_locked_result :
  string -> (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val purge_private_jsonl_durable_locked_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string -> (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val private_jsonl_read_byte : Unix.file_descr -> bytes -> int -> char

val purge_private_jsonl_durable_locked_at_snapshot_result :
  string -> expected:private_jsonl_snapshot ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val purge_private_jsonl_durable_locked_at_snapshot_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string -> expected:private_jsonl_snapshot ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val read_private_jsonl_durable_locked_result :
  string ->
  after:Private_jsonl_cursor.t option ->
  (private_jsonl_snapshot, private_jsonl_transaction_error) result

val private_jsonl_last_complete_row_length : string -> int

val recover_private_jsonl_durable_locked_result :
  string ->
  (private_jsonl_snapshot, private_jsonl_transaction_error) result

val read_private_jsonl_durable_locked_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string ->
  after:Private_jsonl_cursor.t option ->
  (private_jsonl_snapshot, private_jsonl_transaction_error) result

type private_jsonl_append_observation =
  { before : Unix.stats; after : Unix.stats; suffix : string }

val append_private_jsonl_durable_stable_result :
  string ->
  string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val append_private_jsonl_durable_observed_result :
  string -> string ->
  (Private_jsonl_cursor.t * private_jsonl_append_observation option,
   private_jsonl_transaction_error) result

val append_private_jsonl_durable_locked_at_cursor_result :
  string ->
  expected:Private_jsonl_cursor.t ->
  string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val append_private_jsonl_durable_locked_at_cursor_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string ->
  expected:Private_jsonl_cursor.t ->
  string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val append_private_jsonl_durable_locked_at_snapshot_result :
  string -> expected:private_jsonl_snapshot -> string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val append_private_jsonl_durable_locked_at_snapshot_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string -> expected:private_jsonl_snapshot -> string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val rewrite_private_jsonl_durable_locked_at_cursor_result :
  string ->
  expected:Private_jsonl_cursor.t ->
  string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val rewrite_private_jsonl_durable_locked_at_cursor_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string ->
  expected:Private_jsonl_cursor.t ->
  string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val rewrite_private_jsonl_durable_locked_at_snapshot_result :
  string -> expected:private_jsonl_snapshot -> string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result

val rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing :
  ?before_sync_rewrite_parent:(string -> unit) ->
  io:private_jsonl_transaction_io_for_testing ->
  string -> expected:private_jsonl_snapshot -> string ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result
