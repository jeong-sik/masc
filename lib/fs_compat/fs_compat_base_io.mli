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

val canonical_append_mutex_path : string -> string

type append_path_mutex_key
val capture_append_path_mutex_key : string -> append_path_mutex_key
(** Capture the existing canonical pathname key in a filesystem worker. This
    does not identify arbitrary hardlink or leaf-symlink aliases of an inode. *)
val append_path_mutex_key_path : append_path_mutex_key -> string
(** Canonicalized pathname carried by a captured mutex key, so multi-chunk
    readers can reopen the exact canonicalized path they lock. *)
val with_captured_append_path_mutex : append_path_mutex_key -> (unit -> 'a) -> 'a
(** Reenter the existing registry with the captured key and ordinary active
    entry accounting. The callback must not reenter the same path mutex. *)

val with_append_path_mutex : string -> (unit -> 'a) -> 'a

val try_with_append_path_mutex : string -> (unit -> 'a) -> 'a option

val evict_inactive_cached_writer_for_path : string -> unit

val append_path_mutex_count_for_testing : unit -> int

val canonical_append_mutex_path_for_testing : string -> string

(** Appends all of the content right after the file's last byte. A failed
    append keeps nothing to write later and removes the bytes it had
    written, or says in the message that it left them (see
    [Fs_compat_internal.Fd_append_whole]).
    @raise Sys_error when the path cannot be examined, opened or
    written. *)
val append_file_unix : string -> string -> unit

(** As {!append_file_unix} for content made of whole lines: when the file
    ends in the middle of a line, a newline is written before the lines.
    @raise Sys_error when the path cannot be examined, opened, read or
    written. *)
val append_lines_unix : string -> string -> unit

val append_file_unix_with_io_for_testing
  :  io:Fs_compat_internal.Fd_append_whole.io
  -> start:Fs_compat_internal.Fd_append_whole.start
  -> string
  -> string
  -> unit

val mkdir_p_unix : string -> unit

val labelled : string -> string -> string

val on_systhread : label:string -> (unit -> 'a) -> 'a

val load_file : string -> string

val load_file_locked : string -> string
val load_lines_rev_locked : string -> string list
(** Plain reads whose descriptor lifetime is protected by the canonical append
    path mutex. The contents reader retains [load_file]'s text opener and
    captured length; the line reader uses a binary channel and reads to EOF,
    retaining an unterminated final line in reverse physical-line order.
    Both close with [close_in_noerr]. Neither adds file ownership or kind
    checks. Eio dispatch happens before mutex acquisition, with or without a
    global filesystem; cancellation is checked after descriptor settlement.
    Coordination is by canonical path, not across distinct leaf-symlink or
    hardlink names for one inode. *)

module Locked_read_for_testing : sig
  val load_file : before_read:(Unix.file_descr -> unit) -> string -> string
  val load_lines_rev :
    before_read:(Unix.file_descr -> unit) -> string -> string list
  val path_mutex_available : string -> bool
  (** Hooks run on the blocking reader after open (and after length capture
      for [load_file]); they must not perform Eio effects or close the file.
      The nonblocking probe uses the actual canonical append path mutex. *)
end

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
