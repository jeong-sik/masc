(** Path_scope — a filesystem path as the command wrote it.

    A [Shell_ir.Simple] carries the written [cwd] and redirect targets. The
    path stays as written: the dispatch that runs the command decides which
    filesystem it names. Positional argv remains opaque application data and
    is not read as a path from token shape or command semantics. *)

type t

val of_raw : string -> t

val lexical_normalize_abs : string -> string
(** Collapse empty, [.], and [..] segments of an absolute path without
    consulting the filesystem ([..] at the root is dropped). The remote
    execution lane uses this for endpoint-namespace paths, where host
    resolution would substitute host symlinks and macOS firmlinks into paths
    that only exist on the endpoint. *)

val lexical_normalize_relative : string -> string
(** Collapse empty, [.], and interior [..] segments of a relative path without
    absolutizing. Leading [..] segments are preserved so callers can detect
    root escape. *)

val raw : t -> string
val is_discard_sink : t -> bool
(** [is_discard_sink t] is true for the canonical stdout/stderr discard
    target.  Policy and dispatch consumers use this predicate instead of
    matching the raw path themselves. *)
val pp : Format.formatter -> t -> unit
