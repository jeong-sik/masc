(** Per-binding provider concurrency gate (RFC-0153 §4.2.3).

    Activates the [max_concurrent] binding limit (runtime.toml
    [<provider>.<model>] [max-concurrent], RFC-0058 §3.4) that
    {!Runtime_candidate} already carries but the runtime rebirth (RFC-0206)
    left inert: [register_http_probe_capable] discards it and the
    [Runtime_client_capacity] machinery was gutted to no-ops
    ([declared_client_capacity] returns [None]). Before this module the only
    active provider gate was the single global [Fd_accountant.Provider_http]
    semaphore (default 16), shared across every provider — so it cannot hold a
    single over-subscribed endpoint under its own limit when several keepers are
    assigned to the same runtime binding.

    The gate is a process-global registry of one [Eio.Semaphore.t] per capacity
    key (provider:model@base_url — see {!Runtime_candidate.capacity_key}).
    Acquisition can either block until a slot is free or, when the caller
    supplies a clock and wait timeout, fail as bounded backpressure. The holder
    is released when its turn completes, errors, or is cancelled. *)

type wait_timeout =
  { key : string
  ; wait_timeout_sec : float
  ; in_flight : int
  ; cap : int
  }

val with_slot_result :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  wait_timeout_sec:float ->
  key:string ->
  max_concurrent:int option ->
  (unit -> 'a) ->
  ('a, wait_timeout) result
(** [with_slot_result] acquires a binding slot with a mandatory timeout.

    Waiting for a saturated key is capped by [wait_timeout_sec]. A timeout
    returns [Error wait_timeout] without running [f] and without acquiring a
    slot.

    [None] (or [Some n] with [n <= 0]) disables the gate for that key and runs
    [f] immediately, returning [Ok (f ())]. An unconfigured binding must fall
    back to the existing global gate, never be throttled to a
    [Eio.Semaphore.make 0] deadlock.

    The slot is released on normal return, exception, or fiber cancellation via
    [Eio.Switch.on_release].

    The cap for a key is fixed at first acquisition. runtime.toml is
    startup-only, so a key's cap does not change within a process lifetime. *)

val snapshot : unit -> (string * int * int) list
(** [(key, in_flight, cap)] for every key that has been gated at least once.
    Observability surface for dashboard/health: [in_flight = cap] means the
    endpoint is saturated and further turns on that binding are waiting.
    Ordered by key. *)
