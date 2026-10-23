(** A browser profile that masc created for its own use, and the process that
    holds its lock.

    Closing any descriptor for a file drops every POSIX record lock this
    process holds on that file. So this process keeps at most one descriptor
    per lock file, the one inside a [lock_file], until [close_lock]: opening a
    file that is already open here is refused, and a captured [holder] keeps no
    descriptor for the lock file. Every operation here runs under one
    process-wide mutex.

    This is the only module that sends SIGKILL to a profile lock holder, and it
    signals only a process that holds the lock of a file opened here. The
    workspace lease owner is signalled through [Owner_process_identity], which
    never sends SIGKILL. *)

val remove : label:string -> ?last:string -> string -> (unit, string) result
(** [remove ~label ?last path] removes the profile tree at [path]. It never
    follows a symbolic link, refuses an entry another uid owns or a file with
    more than one link, and keeps whatever it could not remove. [last] names a
    top-level entry that is removed only when it is the profile's last entry,
    just before the profile directory; an entry that appears meanwhile is
    refused and [last] is kept. [label] begins each refusal, e.g.
    ["Chrome profile"].

    The tree is inside a private directory of this user; an entry swapped for
    a symbolic link between its check and its removal is not detected. *)

type lock_file

val open_lock : profile:string -> name:string -> (lock_file, string) result
(** Opens [profile]/[name] read-write, creating it with mode 0600 when it is
    missing, without following a symbolic link at either step. [profile] must
    be a directory and [name] a regular file, both owned by this user, and the
    file must have exactly one link. A file this process already has open
    through another [lock_file] is refused. The caller has already checked the
    private directory that contains [profile]. *)

type holder

type inspection =
  | Unlocked
  | Held_by of holder
  | Changing  (** The holder ended or changed while it was being captured. *)
  | Unreadable of string

val inspect : lock_file -> inspection
(** Asks the kernel (F_GETLK) which process holds a lock that conflicts with a
    whole-file write lock. It never reads a PID file, and this process's own
    lock is not reported. A holder the kernel cannot name to this process, as
    in another PID namespace, is [Unreadable]. *)

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
(** Whether two captures name the same process incarnation. A released
    capture names none. *)

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
