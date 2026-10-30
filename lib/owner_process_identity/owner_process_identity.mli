(** Identity-bound graceful signaling of a kernel-observed workspace lease owner.
    The caller must validate the lease descriptor's private directory, ownership
    and inode and obtain explicit owner authorization before termination. *)
type t
type error = No_owner | Owner_changed | Unsupported | Unavailable | Closed
val capture : lease_fd:Unix.file_descr -> (t, error) result
(** Uses F_GETLK, never PID-file contents. Capture does not signal the owner. *)
val request_termination : t -> (unit, error) result
(** SIGTERM to the captured process incarnation only; never PID fallback or
    SIGKILL escalation. Success means requested, not drained or restarted. *)
val close : t -> unit
