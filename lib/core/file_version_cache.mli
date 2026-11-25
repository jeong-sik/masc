(** A value decoded from a file, kept with the version of the file it was
    decoded from.

    A version is the file's device, inode, size and modification time. A
    writer that replaces the file gives it a new inode, one that appends
    changes its size, so a reader of an unchanged file takes the kept value
    without reading the file, and any other reader decodes again. The kept
    value is shared by every reader of that version, so it must not be
    mutable. *)

type version
(** A file's device, inode, size and modification time. *)

val version_of_stats : Unix.stats -> version

val same_version : version -> version -> bool

type 'a t

val create : unit -> 'a t

val load : 'a t -> string -> decode:(unit -> ('a, 'e) result) -> ('a, 'e) result
(** [load cache path ~decode] returns the value kept for [path] when its
    version matches. Otherwise it drops that old value, runs [decode] and
    returns the result. A successful value is kept when the file had the
    same version before and after the read and the same cache slot still
    belongs to that path. Concurrent reads may each decode.
    Inspection and decoding run outside the cache lock. Errors and files
    without an observable version are never kept. *)

val forget : 'a t -> string -> unit
(** Drop what is kept for [path], and stop older decodes of that path from
    keeping their value. A writer calls it after it writes, so that a
    write that keeps the inode and the size within one file-time tick is not
    taken for the version already kept, even by a reader that was decoding
    while it wrote. *)

val keep_written : 'a t -> string -> 'a -> unit
(** [keep_written cache path value] is for a writer that has just replaced
    [path] with a new file and holds [value], what {!load}'s [decode] would
    return for the bytes it wrote. The value is kept for the version [path]
    has now, so the next reader of that file takes it without decoding.
    Like {!forget}, it stops older decodes of [path] from keeping their value.

    The caller must exclude every other writer of [path] from before its
    write until this returns, and must have replaced the file rather than
    written into it: the version read here is then the version of the bytes
    [value] stands for. A path that cannot be stat'ed keeps nothing. *)
