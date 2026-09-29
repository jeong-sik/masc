(** A value decoded from a file, kept with the version of the file it was
    decoded from.

    A version is the file's device, inode, size and modification time. A
    writer that replaces the file gives it a new inode, one that appends
    changes its size, so a reader of an unchanged file takes the kept value
    without reading the file, and any other reader decodes again. The kept
    value is shared by every reader of that version, so it must not be
    mutable. *)

type 'a t

val create : unit -> 'a t

val load : 'a t -> string -> decode:(unit -> ('a, 'e) result) -> ('a, 'e) result
(** [load cache path ~decode] returns the value kept for [path] when the
    file's current version is the one it was decoded from. Otherwise it runs
    [decode] and returns its result. The value is kept only when the file
    had the same version before and after [decode] ran, so a write that lands
    during a decode is never kept under the new version. An error is returned
    as it is and not kept. A path that cannot be stat'ed is decoded every
    time. *)

val forget : 'a t -> string -> unit
(** Drop what is kept for [path]. A writer calls it after it writes, so that
    a write that keeps the inode and the size within one file-time tick is not
    taken for the version already kept. *)
