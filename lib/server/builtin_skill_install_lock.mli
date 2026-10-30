(** The installer lock of one receipt directory. A lockf lock on a file there
    excludes other processes. lockf grants the same lock to every systhread of
    the process and releases it when any descriptor of the file closes, so a
    mutex per receipt directory excludes the systhreads of this process.
    Installations into different receipt directories do not wait for each
    other. The caller creates the receipt directory first. No Eio effects. *)

type rejection = Lock_file_not_regular of string

val with_waiting :
  on_wait:(string -> unit) -> directory:string -> lock:string -> (unit -> 'a) -> ('a, rejection) result
(** Run the action holding the lock file [lock] of receipt directory
    [directory], waiting for it. [on_wait] receives [lock] once when another
    holder makes the call wait. *)

val with_if_free :
  directory:string -> lock:string -> (unit -> 'a) -> ('a option, rejection) result
(** [Ok None] without running the action when this process or another one
    holds the lock. *)
