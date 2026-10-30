(** What a host-private path must be, and the sentence that refuses it.

    A refusal names what the path is for (the caller's [label]), the path,
    what was found and what is required, so an operator can fix the path
    without reading the code. Nothing here changes a file. *)

type owner =
  | Effective_user  (** The owner is the process's effective uid. *)
  | Real_user  (** The owner is the process's real uid. *)

type mode =
  | Exact of int  (** The permission bits equal this value. *)
  | Clear of int  (** None of these permission bits is set. *)
  | Any_mode

type links = Exactly_one | Any_count

type t = { kind : Unix.file_kind; owner : owner; mode : mode; links : links }

val private_directory : t
(** A directory owned by the effective uid with mode 0700. *)

val private_file : t
(** A regular file owned by the effective uid with mode 0600 and exactly one
    link. *)

val kind_name : Unix.file_kind -> string
(** "directory", "regular file", "symbolic link" and so on. *)

val check : label:string -> t -> path:string -> Unix.stats -> (unit, string) result
(** Decide [stats], read from [path] by [lstat] or [fstat]. A refusal reads,
    for example, "Firefox profile /p must be a directory owned by uid 502 with
    mode 0700; it is a directory owned by uid 502 with mode 0755". *)

val lstat : label:string -> t -> string -> (Unix.stats, string) result
(** [Unix.lstat] and then {!check}. [Unix.Unix_error] from [lstat] is raised
    unchanged, so a caller can still tell a missing path apart. *)

val canonical : label:string -> string -> (unit, string) result
(** Refuse a path that [Unix.realpath] resolves to another path, naming both.
    [Unix.Unix_error] from [realpath] is raised unchanged. *)

type identity = { device : int; inode : int }

val identity : Unix.stats -> identity

val replaced : label:string -> path:string -> expected:identity -> observed:identity -> string
(** The refusal for a pinned path whose device or inode differs, for example
    "Firefox profile /p was replaced: it was device 1 inode 2 and is now
    device 1 inode 3". *)

val keys : label:string -> found:string list -> required:string list -> string
(** The refusal for an object whose keys differ from [required], for example
    "owned Firefox configuration must have exactly the keys a, b; it has a, c". *)
