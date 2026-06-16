(** Per-binding provider concurrency gate (RFC-0153 §4.2.3).

    Activates the [max_concurrent] binding limit (runtime.toml
    [<provider>.<model>] [max-concurrent], RFC-0058 §3.4) that
    {!Runtime_candidate} already carries but the runtime rebirth (RFC-0206)
    left inert: [register_http_probe_capable] discards it and the
    [Runtime_client_capacity] machinery was gutted to no-ops
    ([declared_client_capacity] returns [None]). Before this module the only
    active provider gate was the single global [Fd_accountant.Provider_http]
    semaphore (default 16), shared across every provider — so it cannot hold a
    single over-subscribed endpoint (e.g. ollama.com, ~10 concurrent) under its
    own limit when several keepers are assigned to it (live runtime.toml
    assigns 8 keepers to [ollama_cloud.deepseek-v4-flash]).

    The gate is a process-global registry of one [Eio.Semaphore.t] per capacity
    key (provider:model@base_url — see {!Runtime_candidate.capacity_key}).
    Acquisition blocks until a slot is free: this is backpressure (the caller
    waits its turn on the endpoint), not failure. The wait is bounded by the
    caller's existing OAS stream/body timeout — the holder is released when its
    turn completes, errors, or is cancelled. *)

val with_slot : key:string -> max_concurrent:int -> (unit -> 'a) -> 'a
(** [with_slot ~key ~max_concurrent f] runs [f] while holding one of the
    [max_concurrent] slots for [key].

    [max_concurrent <= 0] disables the gate for that key and runs [f]
    immediately. [0] is the runtime.toml "unset/required" marker (RFC-0058,
    {!Runtime_toml.parse_binding_fields}); an unconfigured binding must fall
    back to the existing global gate, never be throttled to a
    [Eio.Semaphore.make 0] deadlock.

    The slot is released on normal return, exception, or fiber cancellation
    (release cannot raise, so the [Fun.protect] finally is total). If [f]
    never acquires because acquisition is cancelled, no slot is held and none
    is released.

    The cap for a key is fixed at first acquisition. runtime.toml is
    startup-only ("restart masc-mcp after edits"), so a key's cap does not
    change within a process lifetime; a later call with a different
    [max_concurrent] for the same key reuses the first semaphore and is
    ignored. *)

val snapshot : unit -> (string * int * int) list
(** [(key, in_flight, cap)] for every key that has been gated at least once.
    Observability surface for dashboard/health: [in_flight = cap] means the
    endpoint is saturated and further turns on that binding are waiting.
    Ordered by key. *)
