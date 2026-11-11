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
val pid : t -> int
(** The process the handle was captured for. A number to show, and to compare
    with one the kernel gave for the same moment, such as the holder of a lock.
    It signals nothing, and it outlives the process it named. *)

type held_byte = { holder : int; byte : int }
val held_byte : Unix.file_descr -> (held_byte option, error) result
(** F_GETLK over the whole file: the first lock another process holds on it,
    when that lock is a write lock of exactly one byte. [Ok None] when no other
    process holds a lock; [Error Unavailable] when the probe fails or the lock
    has another shape. The kernel reports what would block the caller, so a
    lock of the calling process is not seen. The record is the lock: it ends
    with its holder, and the caller says what a position means. *)
