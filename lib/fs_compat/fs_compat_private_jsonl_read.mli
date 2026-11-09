(** Private JSONL reads of [Fs_compat]: [Private_jsonl_slice],
    [Private_jsonl_rows], [Private_jsonl_fold], [Private_jsonl_unique_fold],
    [Private_jsonl_window] and [Private_jsonl_tail] with the locked read entry
    points that serve them. [Fs_compat] includes this module. *)
open Fs_compat_private_jsonl_transaction

module Private_jsonl_slice :
  sig
    type t = { bytes : string; end_offset : int; }
    type error =
        Negative_offset of int
      | Missing_file_after_offset of int
      | Offset_beyond_end of { offset : int; end_offset : int; }
      | Offset_not_at_row_boundary of int
      | Incomplete_tail of int
      | Non_regular_file of Unix.file_kind
      | Io_failed of exn
    val error_to_string : error -> string
  end

val read_private_jsonl_slice_locked_result :
  string ->
  from:int ->
  ( Private_jsonl_slice.t
  , Private_jsonl_slice.error )
  private_file_transaction_outcome

val read_private_jsonl_slice_locked_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string ->
  from:int ->
  ( Private_jsonl_slice.t
  , Private_jsonl_slice.error )
  private_file_transaction_outcome

module Private_jsonl_rows :
  sig
    type t =
        Rows_missing
      | Rows_present of { rows : string; rows_end : int; end_offset : int; }
    type error = Non_regular_file of Unix.file_kind | Io_failed of exn
    val error_to_string : error -> string
  end

val read_private_jsonl_rows_locked_result :
  string ->
  ( Private_jsonl_rows.t
  , Private_jsonl_rows.error )
  private_file_transaction_outcome

val read_private_jsonl_rows_locked_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string ->
  (Private_jsonl_rows.t, Private_jsonl_rows.error) private_file_transaction_outcome

module Private_jsonl_fold :
  sig
    type 'a t =
        Missing
      | Present of { value : 'a; rows_end : int; end_offset : int; }
    type error = Read_error of Private_jsonl_rows.error | Snapshot_changed
  end

val fold_private_jsonl_locked_result :
  string ->
  init:'a ->
  f:('a -> string -> 'a) ->
  ('a Private_jsonl_fold.t, Private_jsonl_fold.error)
  private_file_transaction_outcome

module Private_jsonl_unique_fold :
  sig
    type error =
        Non_regular_file of Unix.file_kind
      | Snapshot_changed
      | Binding_refused of
          private_jsonl_transaction_error
      | Operation_failed of
          private_jsonl_operation_failure
    val error_to_string : error -> string
  end

val fold_private_jsonl_unique_regular_locked_result :
  string -> init:'a -> f:('a -> string -> 'a) ->
  ('a Private_jsonl_fold.t, Private_jsonl_unique_fold.error)
    private_file_transaction_outcome

val fold_private_jsonl_unique_regular_locked_with_io_for_testing :
  io:private_jsonl_transaction_io_for_testing ->
  string -> init:'a -> f:('a -> string -> 'a) ->
  ('a Private_jsonl_fold.t, Private_jsonl_unique_fold.error)
    private_file_transaction_outcome

module Private_jsonl_window :
  sig
    type t =
        Window_missing
      | Window_present of { previous_row : (int * string) option;
          from_starts_row : bool; rows : string; window_end : int;
          rows_end : int; end_offset : int;
        }
  end

val read_private_jsonl_window_locked_result :
  string ->
  from:int ->
  max_rows:int ->
  previous_row_wanted:(string -> bool) ->
  ( Private_jsonl_window.t
  , Private_jsonl_rows.error )
  private_file_transaction_outcome

module Private_jsonl_tail :
  sig
    type t =
        Tail_missing
      | Tail_present of { rows : string; prefix_omitted : bool;
          incomplete_tail : bool; end_offset : int;
        }
    type error =
        Invalid_max_bytes of int
      | Read_error of Private_jsonl_rows.error
    val error_to_string : error -> string
  end

val read_private_jsonl_tail_locked_result :
  string ->
  max_bytes:int ->
  ( Private_jsonl_tail.t
  , Private_jsonl_tail.error )
  private_file_transaction_outcome
