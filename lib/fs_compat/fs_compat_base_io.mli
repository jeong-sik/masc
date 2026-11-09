(** Base file I/O of [Fs_compat]: the process-wide Eio filesystem, the blocking
    Unix fallbacks for load, save, append and [mkdir_p], the atomic replace
    entry points with their failure types, and the test-home guard. The other
    pieces of [Fs_compat] build on this module and [Fs_compat] includes it. *)
open Fs_compat_internal

type cleanup_directory = Owned_tree_cleanup.directory =
  { path : string; device : int; inode : int; owner_uid : int; permissions : int }

val remove_owned_tree : cleanup_directory list -> (unit, string) result

module Atomic_orphan_size_class = Atomic_orphan_size_class

module Durable_file_identity = Durable_file_identity

val set_fs : Eio.Fs.dir_ty Eio.Path.t -> unit

val clear_fs : unit -> unit

val get_fs_opt : unit -> Eio.Fs.dir_ty Eio.Path.t option

val has_fs : unit -> bool

type execution_context = Execution_context.t =
  | Eio_fiber
  | Non_eio

val execution_context : unit -> execution_context

exception Test_isolation_breach of string

val test_exec_home_guard : op:string -> string -> unit

val with_fs_or_fallback :
  path:string ->
  fallback:(unit -> 'a) -> (Eio.Fs.dir_ty Eio.Path.t -> 'a) -> 'a

val read_channel_and_close :
  before_read:(unit -> 'a) -> string -> in_channel -> string

val write_all_and_close : Unix.file_descr -> string -> unit

val get_append_path_mutex : string -> Mutex.t

val append_file_unix : string -> string -> unit

val mkdir_p_unix : string -> unit

val labelled : string -> string -> string

val on_systhread : label:string -> (unit -> 'a) -> 'a

val load_file : string -> string

val save_file : string -> string -> unit

val save_file_atomic : string -> string -> (unit, string) Result.t

val sync_file_and_parent_strict : string -> (unit, string) Result.t

val save_file_atomic_rename_only : string -> string -> (unit, string) Result.t

type atomic_replace_failure_stage =
  Atomic_replace.atomic_replace_failure_stage =
  | Before_rename
  | After_rename

type atomic_replace_failure =
  Atomic_replace.atomic_replace_failure =
  { path : string
  ; stage : atomic_replace_failure_stage
  ; exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

val atomic_replace_failure_to_string : atomic_replace_failure -> string

val save_file_atomic_rename_only_staged :
  string -> string -> (unit, atomic_replace_failure) result

val save_file_atomic_strict_staged :
  string -> string -> (unit, atomic_replace_failure) result

val write_file_atomic_strict_staged_blocking :
  string ->
  write:(out_channel -> unit) -> (unit, atomic_replace_failure) result

val write_file_atomic_strict_staged :
  string ->
  write:(out_channel -> unit) -> (unit, atomic_replace_failure) result

val save_file_atomic_strict : string -> string -> (unit, string) Result.t

module Atomic_replace_for_testing :
  sig
    val save_file_atomic_strict_staged :
      ?sync_file:(string -> unit) ->
      sync_parent:(string -> unit) ->
      string -> string -> (unit, atomic_replace_failure) result
    val write_file_atomic_strict_staged :
      ?sync_file:(string -> unit) ->
      sync_parent:(string -> unit) ->
      string ->
      write:(out_channel -> unit) -> (unit, atomic_replace_failure) result
  end
