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

(** {1 Byte locks}

    A byte lock is the write lock of exactly one byte that a process above
    pid 1 holds on a file. The record is the lock: it ends with its holder,
    and the caller says what a position means. The kernel reports what would
    block the caller, so a lock of the calling process is never seen. *)

type held_byte = { holder : int; byte : int }
val held_byte : Unix.file_descr -> (held_byte option, error) result
(** F_GETLK over the whole file: the lock of another process that the kernel
    names, when it is a byte lock. [Ok None] when the kernel names none, or
    names one of another shape (a read lock, a longer range, a lock without
    a process). [Error Unavailable] when the kernel could not be asked.

    When several processes hold locks on the file the kernel names one of
    them, and which one is not said, so a byte lock can stay unseen behind
    another lock. A caller that knows the byte it asks about uses
    {!byte_holder}. *)

val byte_holder : Unix.file_descr -> byte:int -> (int option, error) result
(** F_GETLK over [byte] alone: the other process that holds the byte lock at
    [byte]. A write lock has one holder, so what other processes hold on
    other bytes changes nothing in the answer. [Ok None] when no other
    process holds a byte lock there, which includes a lock of another shape
    over the byte. [Error Unavailable] when the kernel could not be asked,
    as for a negative [byte]. *)
