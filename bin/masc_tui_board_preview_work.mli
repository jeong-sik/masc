(** One physical Board image preparation at a time. Cancellation of the
    waiting fiber does not imply that its system-thread work has returned. *)
type t
type admission
val create : unit -> t
val is_busy : t -> bool
val try_acquire : t -> bool
val release : t -> unit
(** For an asynchronous child, acquire before spawning and release only after
    its physical process has been reaped. *)
val stop : t -> unit
(** Prevent new work from starting, including work still waiting to enter. *)
val await_stopped : t -> unit
(** Wait for the admitted physical worker to finish its cleanup. *)
val try_run : t -> (unit -> 'a) -> 'a option
(** [None] means another worker owns the slot or shutdown has begun. A started
    worker releases its own slot only after its work returns or raises. *)
val reserve : t -> admission option
(** Reserve an idle slot before dispatching a worker. *)
val reserve_after_active : t -> admission option
(** Reserve the one waiting position, even while a physical worker is active. *)
val withdraw_pending : t -> bool
(** Revoke an unstarted reservation without releasing an active worker.
    Returns whether a reservation was withdrawn. *)
val withdraw : t -> admission -> unit
(** Revoke only the exact unstarted reservation, never a later one. *)
val run_reserved : t -> admission -> (unit -> 'a) -> 'a option
(** Start only the exact, still-current reservation. Returns [None] when the
    reservation was withdrawn or shutdown began before the worker started. *)
val run_reserved_after_active : t -> admission -> (unit -> 'a) -> 'a option
(** Wait in a system thread for the active worker to finish, then start only
    the exact reservation. Withdrawal or shutdown wakes the waiter. *)
val run : t -> (unit -> ('a, string) result) -> ('a, string) result
(** Refuse another preparation while the original worker is still running.
    The original worker releases its own slot on return or exception. *)
