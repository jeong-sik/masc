(** Per-binding provider concurrency gate.

    RFC-0153 §4.2.3 deferred a per-runtime cap to post-merge measurement. This
    module activates the binding [max_concurrent] field (runtime.toml
    [<provider>.<model>] [max-concurrent], RFC-0058 §3.4) as an interim
    per-binding gate. The previous global [Fd_accountant.Provider_http]
    semaphore (default 16, shared across every provider) could not hold a single
    over-subscribed endpoint under its own limit when several keepers were
    assigned to the same runtime binding.

    The gate is a process-global registry of one [Eio.Semaphore.t] per capacity
    key (provider:model@base_url — see {!Runtime_candidate.capacity_key}).
    Acquisition is bounded by a mandatory caller-supplied timeout; a saturated
    key fails as typed backpressure rather than blocking forever. The holder is
    released on normal return, exception, or fiber cancellation.

    {b Note on granularity:} the current enforcement wraps the whole provider
    attempt (multi-turn + local tool execution), which is coarser than the
    eventual per-HTTP-call target mentioned in RFC-0153. This is an intentional
    interim trade-off: it is simple to reason about and immediately protects
    endpoints from keeper-storm overload. Finer-grained HTTP-call or
    endpoint-discovery enforcement is future work once fleet-wide concurrency
    data is available. *)

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
