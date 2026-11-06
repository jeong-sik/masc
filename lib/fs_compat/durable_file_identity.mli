(** The identity of a file or directory that a record keeps across process
    restarts and reboots: its path and inode.

    The device number is not part of it. macOS renumbers an APFS volume's
    [st_dev] across reboots, so a record that kept it would name another
    device after the next boot. Inode numbers are stored by the filesystem
    and stay the same.

    A check between two observations inside one process, such as a stat
    before and after opening a file, compares [(st_dev, st_ino)] directly and
    does not use this type. *)

type t = private
  { path : string
  ; inode : int
  }

val of_stat : path:string -> Unix.stats -> t
(** [path] as given, and [stats.st_ino]. *)

val equal : t -> t -> bool

val to_json : t -> Yojson.Safe.t
(** [{"path": ..., "inode": ...}]. *)

val of_json : Yojson.Safe.t -> (t, string) result
(** Exactly the fields [path] and [inode]. A relative or blank path, a
    negative inode and any other field are refused. *)
