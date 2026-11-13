(** Private JSONL transactions of [Fs_compat]: the blocking private-file
    transaction runner, [Private_jsonl_cursor], the snapshot, operation,
    failure and outcome types with their strings, the descriptor and cleanup
    bookkeeping, and the stable lock files with their binding checks.
    [Fs_compat] includes this module. *)
open Fs_compat_durable_append

val run_blocking_private_file_transaction :
  label:string -> path:'a -> (unit -> 'b) -> 'b

module Private_jsonl_cursor :
  sig
    type t =
        Missing
      | Present of { device : int; inode : int; end_offset : int; }
    val equal : t -> t -> bool
    val is_missing : t -> bool
    val to_string : t -> string
    val fingerprint : t -> string
    val prefix_end_offset :
      t -> device:int -> inode:int -> file_length:int -> int option
  end

type private_jsonl_snapshot =
  { bytes : string
  ; cursor : Private_jsonl_cursor.t
  }

type private_jsonl_transaction_operation =
  | Create_parent_directory
  | Canonicalize_parent_directory
  | Inspect_stable_lock
  | Open_stable_lock
  | Set_stable_lock_permissions
  | Sync_stable_lock_parent
  | Acquire_stable_lock
  | Read_stable_lock_state
  | Write_stable_lock_state
  | Sync_stable_lock
  | Close_stable_lock
  | Open_transaction_data
  | Set_transaction_data_permissions
  | Inspect_transaction_data
  | Inspect_transaction_path
  | Read_transaction_data
  | Close_transaction_data
  | Create_rewrite_stage
  | Set_rewrite_stage_permissions
  | Write_rewrite_stage
  | Sync_rewrite_stage
  | Close_rewrite_stage
  | Rename_rewrite_stage
  | Sync_rewrite_parent
  | Inspect_rewritten_data
  | Remove_rewrite_stage
  | Truncate_transaction_data
  | Sync_transaction_data
  | Remove_transaction_data
  | Sync_removal_parent

type private_jsonl_operation_failure =
  { operation : private_jsonl_transaction_operation
  ; exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type ('value, 'error) private_file_transaction_outcome =
  | Private_file_succeeded of 'value
  | Private_file_succeeded_with_cleanup_failure of
      { value : 'value
      ; cleanup_failure : private_jsonl_operation_failure
      }
  | Private_file_failed of 'error
  | Private_file_failed_with_cleanup_failure of
      { error : 'error
      ; cleanup_failure : private_jsonl_operation_failure
      }

type private_jsonl_transaction_success =
  | Snapshot_succeeded of private_jsonl_snapshot
  | Cursor_succeeded of Private_jsonl_cursor.t
  | Cursor_precondition_succeeded of Private_jsonl_cursor.t

type private_jsonl_transaction_primary =
    Transaction_succeeded of private_jsonl_transaction_success
  | Transaction_failed of private_jsonl_transaction_error
and private_jsonl_transaction_error =
    Stable_lock_contended of { lock_path : string; }
  | Unexpected_stable_lock_permissions of { path : string; actual : int; }
  | Invalid_stable_lock_state of { path : string; observed_length : int; }
  | Cursor_mismatch of { expected : Private_jsonl_cursor.t;
      actual : Private_jsonl_cursor.t;
    }
  | Unexpected_transaction_file_kind of Unix.file_kind
  | Ambiguous_transaction_file_identity of { path : string; link_count : int;
    }
  | Transaction_path_binding_changed of { path : string; }
  | Transaction_content_changed of { path : string; }
  | Incomplete_transaction_tail of { end_offset : int; }
  | Invalid_transaction_suffix
  | Private_jsonl_operation_failed of private_jsonl_operation_failure
  | Rewrite_stage_failed of { failure : private_jsonl_operation_failure;
      cleanup_failures : private_jsonl_operation_failure list;
    }
  | Rewrite_published_durability_unknown of {
      cursor : Private_jsonl_cursor.t option;
      failure : private_jsonl_operation_failure;
    }
  | Transaction_settlement_failed of {
      primary : private_jsonl_transaction_primary;
      cleanup_failures : private_jsonl_operation_failure list;
    }
  | Transaction_append_failed of
      durable_append_error

type 'a private_jsonl_success_receipt =
  { value : 'a
  ; settlement_error : private_jsonl_transaction_error option
  }

val private_jsonl_snapshot_success_receipt :
  (private_jsonl_snapshot, private_jsonl_transaction_error) result ->
  ( private_jsonl_snapshot private_jsonl_success_receipt
  , private_jsonl_transaction_error )
  result

val private_jsonl_cursor_success_receipt :
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result ->
  ( Private_jsonl_cursor.t private_jsonl_success_receipt
  , private_jsonl_transaction_error )
  result

val private_jsonl_operation_failure_to_string :
  private_jsonl_operation_failure -> string

val private_jsonl_transaction_error_to_string :
  private_jsonl_transaction_error -> string

val private_jsonl_transaction_error_is_incomplete_tail :
  private_jsonl_transaction_error -> bool

val private_jsonl_failure :
  private_jsonl_transaction_operation ->
  exn -> private_jsonl_operation_failure

val private_jsonl_capture :
  private_jsonl_transaction_operation ->
  (unit -> 'a) -> ('a, private_jsonl_operation_failure) result

val private_file_transaction_map :
  ('a -> 'b) ->
  ('a, 'c) private_file_transaction_outcome ->
  ('b, 'c) private_file_transaction_outcome

val private_jsonl_with_fd_outcome :
  close_operation:private_jsonl_transaction_operation ->
  close_fd:('a -> unit) ->
  'a ->
  (unit -> ('b, 'c) result) -> ('b, 'c) private_file_transaction_outcome

val private_jsonl_add_cleanup_failure :
  private_jsonl_transaction_error ->
  private_jsonl_operation_failure -> private_jsonl_transaction_error

val private_jsonl_with_fd :
  close_operation:private_jsonl_transaction_operation ->
  close_fd:('a -> unit) ->
  success:('b -> private_jsonl_transaction_success) ->
  'a ->
  (unit -> ('b, private_jsonl_transaction_error) result) ->
  ('b, private_jsonl_transaction_error) result

val lock_suffix : string

val is_lock_name : string -> bool

val private_jsonl_lock_path : string -> string

type private_jsonl_transaction_io_for_testing =
  { before_sync_parent : string -> unit
  ; close_fd : Unix.file_descr -> unit
  }

val private_jsonl_transaction_unix_io :
  private_jsonl_transaction_io_for_testing

type private_jsonl_stable_lock_creation =
  | Stable_lock_created
  | Stable_lock_existing

type private_jsonl_stable_lock =
  { fd : Unix.file_descr
  ; creation : private_jsonl_stable_lock_creation
  }

val private_jsonl_same_identity : Unix.stats -> Unix.stats -> bool

val private_jsonl_validate_unique_regular_binding :
  path:string ->
  path_stats:Unix.stats ->
  fd_stats:Unix.stats -> (unit, private_jsonl_transaction_error) result

val private_jsonl_validate_open_binding :
  operation:private_jsonl_transaction_operation ->
  path:string ->
  Unix.file_descr -> (unit, private_jsonl_transaction_error) result

val try_lock_whole_file : Unix.file_descr -> bool

val with_private_jsonl_stable_lock :
  io:private_jsonl_transaction_io_for_testing ->
  success:('a -> private_jsonl_transaction_success) ->
  string ->
  (dir:string -> path:string -> ('a, private_jsonl_transaction_error) result) ->
  ('a, private_jsonl_transaction_error) result

val with_private_jsonl_identified_stable_lock :
  io:private_jsonl_transaction_io_for_testing ->
  success:('a -> private_jsonl_transaction_success) ->
  string ->
  (dir:string ->
   path:string ->
   lock_identity:Unix.stats ->
   ('a, private_jsonl_transaction_error) result) ->
  ('a, private_jsonl_transaction_error) result
(** [with_private_jsonl_stable_lock] that also passes [fstat] of the held
    stable-lock descriptor, for {!private_jsonl_same_identity}. *)

val private_jsonl_requested_lock_path : string -> string
(** Spelling of the stable lock that a transaction on this requested path
    opens, before its parent directory is canonicalized. *)

val private_jsonl_cursor_of_stats :
  Unix.stats ->
  (Private_jsonl_cursor.t, private_jsonl_transaction_error) result
