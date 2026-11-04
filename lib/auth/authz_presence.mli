(* HIGH-RISK-UNREVIEWED: a file that this module calls not there is read as
   absent, and an absent authorization log or external store lets a base path
   that was restored to before its bootstrap boot as a single user. *)

(** Whether a file of the authorization layer is there, without opening it.

    Opening the authorization log or the external store creates its directory
    and a lock file next to it, so the boot asks this first and opens only a
    file that is there.

    [lstat] answers ENOENT when nothing is at the path, and also when a symbolic
    link on the way is dangling, for instance a link to a volume that is not
    mounted. Only the first is {!Not_there}. After ENOENT the module goes up to
    the nearest component that [lstat] finds, and a symbolic link there must
    lead somewhere. A path that holds a NUL byte cannot be checked, because
    [Unix] answers ENOENT for it whatever is on disk.

    Anything at the path itself is {!There}: a symbolic link, a directory, or a
    file with a second hard link is refused by the open, not here. *)

type t =
  | Not_there
  | There
  | Cannot_check of string

val of_path : string -> t

(** The walk alone, for a caller that got ENOENT for [path] from another call
    ([Unix.realpath], for instance): [Ok ()] when nothing is there, and the
    reason otherwise. *)
val confirm_absent : string -> (unit, string) result
