(** The one way masc takes an OS mutex.

    A [Stdlib.Mutex] held while its Eio fiber suspends breaks three ways.
    The next fiber on the same system thread that takes it fails with
    [Sys_error "Mutex.lock: Resource deadlock avoided"]. Another domain that
    takes it blocks. A system-thread job that needs it never returns. masc
    fixed this fifteen times, one site at a time (RFC
    a-fiber-that-suspends-while-holding-an-os-mutex-fails-at-unlock).

    {!protect} called from an Eio fiber runs its section under an effect
    handler that forwards every effect to Eio. Until the section is marked,
    each effect that switches fibers is written to stderr as one {!record}
    before it is forwarded; one that comes back as a value or as an exception
    other than [Effect.Unhandled] marks the section. When the section ends
    the mutex is released first. A marked section then raises
    {!Held_across_suspension}, unless it ended in [Eio.Cancel.Cancelled],
    which is re-raised unchanged.

    Never automatically retry a section after {!Held_across_suspension}.
    Its work has already run and may have applied side effects, even if the
    section ended in an exception. Repair the critical section instead.

    The section still suspends once, as it did before. What changes is the
    holder: it fails every time the path runs, whether or not anything
    overlapped. A section whose suspended work waits for this same mutex
    never ends; the record on stderr is then all that is left.

    Called outside Eio (a system thread, a program's main), no handler is
    installed and {!protect} is [Mutex.protect]. *)

type t

(** The effect that marked a section. [Effect.t] is an open type, so an
    effect this module cannot name, such as a backend's own, counts as
    switching and is [Other]. *)
type suspension =
  | Suspend  (** The fiber waits until something wakes it. *)
  | Fork  (** A child fiber runs before the parent continues. *)
  | Run_in_systhread  (** The fiber waits for a system-thread job. *)
  | Await_readable  (** The fiber waits for a file descriptor. *)
  | Await_writable  (** The fiber waits for a file descriptor. *)
  | Other

type record =
  { mutex_name : string
  ; suspension : suspension
  ; performed_at : Printexc.raw_backtrace
  (** The stack that performed the effect. Tail calls often leave it empty
      or holding Eio's frames alone. *)
  ; protect_called_at : Printexc.raw_backtrace
  (** The stack {!protect} was called on; the handler runs on it. *)
  }

exception
  Held_across_suspension of
    { record : record
    ; body_raised : (exn * Printexc.raw_backtrace) option
    (** [None] means the section returned normally. [Some (exn, backtrace)]
        is the section's own exception. Neither means its side effects were
        rolled back. *)
    }
(** Raised when a section ends after its fiber switched while holding the
    mutex. The mutex is already released. *)

val create : name:string -> unit -> t
(** [name] is written into every record and {!Held_across_suspension}. *)

val protect : t -> (unit -> 'a) -> 'a
(** Run [f] holding the mutex, and release it however [f] ends. Without a
    switching effect, an exception of [f]'s own is re-raised with its
    backtrace. A marked section follows the rules above and must not be
    automatically retried. *)

val try_protect : t -> (unit -> 'a) -> 'a option
(** {!protect} when the mutex is free now; [None] when it is held, without
    waiting. Once acquired, the same rules as {!protect} apply, including
    {!Held_across_suspension}; [None] never means that the section failed. *)

val wait : Condition.t -> t -> unit
(** [Condition.wait] on this mutex. Call it only inside {!protect} or
    {!try_protect} on the same [t]. It blocks the system thread and performs
    no effect, so it marks nothing. *)
