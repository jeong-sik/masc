(** Descriptor-anchored blocking filesystem operations.

    Every descendant lookup is relative to an already-open directory file
    descriptor. Path components are never re-resolved from an absolute string,
    so replacing a managed ancestor with a symlink cannot redirect an active
    transaction outside its root capability. These calls are blocking and must
    run in a system thread when invoked from Eio. *)

type t

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

val with_open_root : string -> (t -> 'a) -> 'a
(** Open an existing real directory without following a final symlink and close
    the capability after the callback. Close failures are never discarded. *)

val with_open_dir : t -> string -> (t -> 'a) -> 'a
(** Open one existing child directory without following symlinks. *)

val with_ensure_dir :
  t -> name:string -> perm:int -> enforce_perm:bool -> (t -> 'a) -> 'a
(** Open one child directory, creating and durably publishing it when absent.
    [name] must be one path segment. When [enforce_perm] is true, the opened
    directory is [fchmod]ed and fsynced before the callback. *)

val stat : t -> string -> stat option
(** Inspect one child entry without following a symlink. [None] means ENOENT;
    every other error is raised. *)

val read_file : t -> string -> string
(** Read one existing regular file without following a final symlink. *)

val save_file_atomic :
  t -> name:string -> perm:int -> string -> (unit, string) result
(** Write through an exclusive temporary file in [t], fsync it, rename it over
    [name], and fsync [t]. No path component is reopened by name outside [t]. *)

val unlink_if_exists : t -> string -> bool
(** Remove one non-directory child entry. Returns [false] only for ENOENT. *)

val rename : src_dir:t -> src:string -> dst_dir:t -> dst:string -> unit
(** Atomically move one child entry between two directory capabilities. *)

val link_no_replace : src_dir:t -> src:string -> dst_dir:t -> dst:string -> unit
(** Create a hard link without replacing [dst]. The source symlink, if any, is
    linked as a symlink rather than followed. *)

val read_dir : t -> string list
(** Return child names, excluding [.] and [..], in lexical order. *)

val fsync : t -> unit
(** Durably publish prior directory-entry changes. Unsupported operations are
    raised explicitly. *)

val same_identity : stat -> stat -> bool
