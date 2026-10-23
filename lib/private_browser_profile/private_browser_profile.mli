(** A browser profile that masc created for its own use, and the process that
    holds its lock.

    masc opens a profile's lock file through exactly one descriptor
    ([lock_file]) and keeps it until [close_lock]. Closing any descriptor for a
    file drops every POSIX record lock this process holds on that file, so a
    captured [holder] never holds a descriptor for the lock file, and this
    module opens no other one.

    This is the only module that sends SIGKILL, and it signals only a process
    that holds the lock of a file opened here. The workspace lease owner is
    signalled through [Owner_process_identity], which never sends SIGKILL. *)

val remove : label:string -> ?last:string -> string -> (unit, string) result
(** [remove ~label ?last path] removes the profile tree at [path]. It never
    follows a symbolic link, refuses an entry another uid owns or a file with
    more than one link, and keeps whatever it could not remove. [last] names a
    top-level entry removed after every other entry and before the profile
    directory itself. [label] begins each refusal, e.g. ["Chrome profile"]. *)

type lock_file

type open_result =
  | Lock_file of lock_file
  | No_lock_file

val open_lock : profile:string -> name:string -> (open_result, string) result
(** Opens [profile]/[name] read-write without following a symbolic link at
    either step. [profile] must be a directory and [name] a regular file, both
    owned by this user, and the file must have exactly one link. The caller has
    already checked the private directory that contains [profile]. *)

type holder

type inspection =
  | Unlocked
  | Held_by of holder
  | Changing  (** The holder ended or changed while it was being captured. *)
  | Unreadable of string

val inspect : lock_file -> inspection
(** Asks the kernel (F_GETLK) who holds the write lock. It never reads a PID
    file. This process's own lock is not reported. *)

type lock_result =
  | Locked
  | Held_elsewhere

val lock : lock_file -> (lock_result, string) result
(** Takes the write lock without waiting. While this process holds it, a
    browser that starts on the profile finds it in use. *)

val close_lock : lock_file -> unit
(** Closes the descriptor once, which also drops this process's lock. *)

val pid : holder -> int

val executable : holder -> string option
(** The executable path the kernel reports for the holder's PID. It is read by
    PID after the capture, so it is a record for people, not an identity. *)

val same_process : holder -> holder -> bool
(** Whether two captures name the same process incarnation. *)

type signal_error =
  | Holder_changed  (** The captured process no longer holds the lock. *)
  | Other_lock_file  (** The lock file is not the one the holder was captured from. *)
  | Lock_file_closed
  | Released
  | Unsupported
  | Failed

val request_termination : holder -> lock_file -> (unit, signal_error) result
val request_kill : holder -> lock_file -> (unit, signal_error) result
(** Each checks, through [lock_file], that the holder still holds the lock of
    the file it was captured from, then signals that process incarnation
    only. Success means sent, not ended. *)

val release : holder -> unit
(** Releases what the capture keeps for later signals. It holds no lock file
    descriptor, so releasing never changes a lock. *)
