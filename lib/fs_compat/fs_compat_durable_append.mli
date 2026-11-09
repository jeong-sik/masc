(** Durable appends of [Fs_compat]: the durable append operation, failure
    and error types, the descriptor append with its rollback, the whole-file
    locks, and the capability append with its target binding, outcome and
    test hooks. [Fs_compat] includes this module. *)
open Fs_compat_internal

type durable_append_operation =
  | Incomplete_tail_read
  | Incomplete_tail_truncate
  | Incomplete_tail_fsync
  | Write
  | Append_fsync
  | Rollback_truncate
  | Rollback_fsync

type durable_append_failure =
  | Unix_error of
      { operation : durable_append_operation
      ; error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | No_write_progress

type durable_append_error =
  { append_failure : durable_append_failure
  ; rollback_failures : durable_append_failure list
  }

val durable_append_failure_to_string : durable_append_failure -> string

val durable_append_error_to_string : durable_append_error -> string

type durable_append_io_for_testing =
  { write : Unix.file_descr -> bytes -> int -> int -> int
  ; ftruncate : Unix.file_descr -> int -> unit
  ; fsync : Unix.file_descr -> unit
  }

val unix_failure :
  operation:durable_append_operation ->
  Unix.error -> string -> string -> durable_append_failure

val run_unix_io :
  operation:durable_append_operation ->
  (unit -> unit) -> (unit, durable_append_failure) result

val append_fd_durable :
  io:durable_append_io_for_testing ->
  fd:Unix.file_descr ->
  original_length:int -> string -> (unit, durable_append_error) result

val append_fd_durable_for_testing :
  io:durable_append_io_for_testing ->
  fd:Unix.file_descr ->
  original_length:int ->
  string ->
  (unit, durable_append_error) result

val durable_append_unix_io : durable_append_io_for_testing

val fsync_parent_directory : string -> unit

val lock_whole_file : Unix.file_descr -> unit

val lock_whole_file_shared : Unix.file_descr -> unit

type capability_append_operation_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type capability_append_failure =
  | Capability_append_posix_descriptor_unavailable
  | Capability_append_mutation_contended
  | Capability_append_operation_failed of capability_append_operation_failure

type capability_append_target_binding =
  | Capability_append_target_not_checked
  | Capability_append_target_verified
  | Capability_append_target_changed
  | Capability_append_target_check_failed of capability_append_operation_failure

type capability_append_outcome =
  { requested_bytes : int
  ; bytes_written : int
  ; write_failure : capability_append_failure option
  ; sync_failure : capability_append_operation_failure option
  ; target_binding : capability_append_target_binding
  }

type capability_append_open_error =
  | Capability_append_open_invalid_leaf of string
  | Capability_append_open_missing
  | Capability_append_open_failed of capability_append_operation_failure

type capability_append_file =
  { parent : Eio.Fs.dir_ty Eio.Path.t
  ; leaf : Capability_leaf.t
  ; resource : Eio.File.rw_ty Eio.Resource.t
  ; stat : Eio.File.Stat.t
  }

val capability_append_failure_to_string : capability_append_failure -> string

val capability_append_open_error_to_string : capability_append_open_error -> string

val capability_append_operation_failure :
  exn -> Printexc.raw_backtrace -> capability_append_operation_failure

val open_capability_append_file :
  sw:Eio.Switch.t ->
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  leaf:string ->
  (capability_append_file, capability_append_open_error) result

val capability_append_file_stat : capability_append_file -> Eio.File.Stat.t

val capability_append_outcome :
  requested_bytes:int ->
  ?bytes_written:int ->
  ?write_failure:capability_append_failure ->
  ?sync_failure:capability_append_operation_failure ->
  ?target_binding:capability_append_target_binding ->
  unit -> capability_append_outcome

type capability_append_io_for_testing =
  { write_substring : Unix.file_descr -> string -> int -> int -> int
  ; fsync : Unix.file_descr -> unit
  }

val append_fd_observed :
  io:capability_append_io_for_testing ->
  fd:Unix.file_descr -> string -> capability_append_outcome

val append_capability_observed :
  capability_append_file -> string -> capability_append_outcome

module Capability_append_for_testing :
  sig
    val append_capability_observed :
      after_write:(unit -> 'a) ->
      capability_append_file -> string -> capability_append_outcome
    val append_fd_observed :
      io:capability_append_io_for_testing ->
      fd:Unix.file_descr -> string -> capability_append_outcome
  end
