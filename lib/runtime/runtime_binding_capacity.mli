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

val with_slot : key:string -> max_concurrent:int option -> (unit -> 'a) -> 'a
(** [with_slot ~key ~max_concurrent f] runs [f] while holding one of the
    configured slots for [key].

    [None] (or [Some n] with [n <= 0]) disables the gate for that key and runs
    [f] immediately. [None] is the normal runtime.toml "unset" marker
    (RFC-0058, {!Runtime_toml.parse_binding_fields}); an unconfigured binding
    must fall back to the existing global gate, never be throttled to a
    [Eio.Semaphore.make 0] deadlock.

    The slot is released on normal return, exception, or fiber cancellation via
    [Eio.Switch.on_release]. If [f] never acquires because acquisition is
    cancelled, no slot is held and none is released.

    The cap for a key is fixed at first acquisition. runtime.toml is
    startup-only ("restart masc-mcp after edits"), so a key's cap does not
    change within a process lifetime; a later call with a different
    [max_concurrent] for the same key reuses the first semaphore and is
    ignored. *)

val with_slot_result :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?wait_timeout_sec:float ->
  key:string ->
  max_concurrent:int option ->
  (unit -> 'a) ->
  ('a, wait_timeout) result
(** [with_slot_result] is the bounded-acquire variant for hot keeper paths.

    When [clock] and a positive finite [wait_timeout_sec] are both supplied,
    waiting for a saturated key is capped by that duration. A timeout returns
    [Error wait_timeout] without running [f] and without acquiring a slot.

    Missing [clock], missing timeout, non-positive timeout, or
    [None]/non-positive [max_concurrent] preserves [with_slot]'s
    unbounded/ungated behavior. *)

val snapshot : unit -> (string * int * int) list
(** [(key, in_flight, cap)] for every key that has been gated at least once.
    Observability surface for dashboard/health: [in_flight = cap] means the
    endpoint is saturated and further turns on that binding are waiting.
    Ordered by key. *)
