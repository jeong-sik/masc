(** Lock-free atomic wake bitmask and signal-safe Eio wake trigger.

    POSIX signal handlers invoke {!ring_from_signal}, which performs only a
    lock-free atomic bitmask CAS on immediate integers and an optional
    non-blocking 1-byte write to a pre-allocated self-pipe — zero heap
    allocations and zero mutex/condition acquisitions in signal context.

    Normal Eio fibers and sibling domains (e.g. {!Masc_tui_net.Ui_bus} or
    {!Masc_tui_term.Terminal_out}) invoke {!ring}, which coalesces the wake bit
    and broadcasts on the internal {!Eio.Condition.t}. *)

type source =
  | Ui_bus
  | Resize
  | Interrupt
  | Terminate

val all_sources : source list
val equal_source : source -> source -> bool
val bit_of_source : source -> int
val mask_of_source : source -> int
val sources_of_mask : int -> source list

type t

val create : unit -> t

val attach_signal_pipe : sw:Eio.Switch.t -> t -> unit
(** Attach a non-blocking self-pipe drained by a daemon fiber bound to [sw].
    Enables {!ring_from_signal} to wake a sleeping {!await} / {!await_until_ns}
    call across domains without touching {!Eio.Condition.t} inside a POSIX
    signal handler. Both pipe descriptors are detached and closed on
    [Eio.Switch.on_release sw]. *)

val ring : t -> source -> unit
(** Atomically set [source]'s bit and broadcast to waiters. Safe to call from
    any domain or Eio fiber. *)

val ring_from_signal : t -> source -> unit
(** Signal-handler-safe wake: lock-free atomic CAS on immediate bitmask plus
    best-effort non-blocking 1-byte write to the attached self-pipe (if any).
    Zero heap allocations and zero locks. *)

val peek_mask : t -> int
(** Non-destructive read of the current pending bitmask. *)

val is_rung : t -> bool
(** [true] iff at least one wake bit is currently pending. *)

val drain_mask : t -> int
(** Atomically clear and return the pending bitmask. *)

val drain : t -> source list
(** Atomically clear the pending bitmask and return all sources that rang, in
    deterministic {!all_sources} order. *)

val await : t -> unit
(** Suspend cooperatively until at least one wake bit is set. Returns
    immediately when {!is_rung} is already [true]. *)

val await_until_ns :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  now_ns:int64 ->
  deadline_ns:int64 option ->
  t ->
  [ `Woken | `Timeout ]
(** Wait until {!is_rung} becomes [true] or monotonic [deadline_ns] elapses.
    When [deadline_ns = None], performs pure 0 Hz sleep (zero timers, 0% CPU)
    until the bell rings. *)
