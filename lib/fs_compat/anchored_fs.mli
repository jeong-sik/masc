(** Descriptor-anchored blocking filesystem operations.

    Every descendant lookup is relative to an already-open directory file
    descriptor. Path components are never re-resolved from an absolute string,
    so replacing a managed ancestor with a symlink cannot redirect an active
    transaction outside its root capability. These calls are blocking and must
    run in a system thread when invoked from Eio. *)

type t

module Segment : sig
  type t = private string

  type error =
    | Empty
    | Dot
    | Dot_dot
    | Contains_separator
    | Contains_nul

  val of_string : string -> (t, error) result
  val to_string : t -> string
  val error_to_string : error -> string
end

type kind =
  | Regular_file
  | Directory
  | Symbolic_link
  | Other

type stat =
  { kind : kind
  ; size : int64
  ; device : int64
  ; inode : int64
  ; link_count : int64
  }

type mutation_error =
  | Not_committed of
      { cause : exn
      ; cleanup_error : exn option
      }
  | Committed_not_durable of exn

val mutation_error_to_string : mutation_error -> string

val with_open_root : string -> (t -> 'a) -> 'a
(** Open an existing real directory without following a final symlink and close
    the capability after the callback. Close failures are never discarded. *)

val with_open_dir : t -> Segment.t -> (t -> 'a) -> 'a
(** Open one existing child directory without following symlinks. *)

val with_open_dir_opt : t -> Segment.t -> (t -> 'a) -> 'a option
(** Open one child directory using the open operation itself as the existence
    test. [None] means ENOENT; symlinks and all other failures are raised. *)

val with_ensure_dir :
  t -> name:Segment.t -> perm:int -> enforce_perm:bool -> (t -> 'a) -> 'a
(** Open one child directory, creating and durably publishing it when absent.
    When [enforce_perm] is true, the opened directory is [fchmod]ed. Creation is
    committed as [mkdirat -> openat -> fchmod -> fsync(child) -> fsync(parent)]. *)

val stat : t -> Segment.t -> stat option
(** Inspect one child entry without following a symlink. [None] means ENOENT;
    every other error is raised. This is a diagnostic snapshot, not authority
    for a later path-based operation. *)

val read_file : t -> Segment.t -> string
(** Read one existing regular file without following a final symlink. *)

val read_file_opt : t -> Segment.t -> string option
(** Read a regular file using [openat] itself as the existence test. *)

val fsync_file : t -> Segment.t -> stat
(** Fsync one existing regular file and return the identity of the opened file.
    The final entry is opened with [O_NOFOLLOW]. *)

val chmod_file : t -> Segment.t -> int -> unit
(** Apply permissions to one existing regular file through its opened file
    descriptor, without following a final symlink. *)

val atomic_replace :
  t -> name:Segment.t -> perm:int -> string -> (unit, mutation_error) result
(** Write through an exclusive temporary file, fsync it, rename it over [name],
    and fsync the directory. A visible rename followed by failed directory fsync
    is reported as {!Committed_not_durable}, never as an untyped failure. *)

val unlink_if_exists :
  t -> Segment.t -> ([ `Missing | `Removed ], mutation_error) result
(** Remove and durably publish removal of one non-directory child entry. *)

val rename :
  src_dir:t ->
  src:Segment.t ->
  dst_dir:t ->
  dst:Segment.t ->
  (unit, mutation_error) result
(** Atomically move one child entry between two directory capabilities. *)

val link_no_replace :
  src_dir:t ->
  src:Segment.t ->
  dst_dir:t ->
  dst:Segment.t ->
  (unit, mutation_error) result
(** Create and durably publish a hard link without replacing [dst]. The source
    symlink, if any, is linked as a symlink rather than followed. *)

val read_dir : t -> Segment.t list
(** Return child names, excluding [.] and [..], in lexical order. *)

val fsync : t -> unit
(** Durably publish prior directory-entry changes. Unsupported operations are
    raised explicitly. *)

val same_identity : stat -> stat -> bool
