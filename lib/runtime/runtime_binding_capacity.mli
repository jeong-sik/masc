(** Runtime_binding_capacity — per-binding provider HTTP concurrency gate
    (RFC-0153 §4.2.4).

    A process-global registry of one {!Eio.Semaphore} per capacity key
    ([provider:model@base_url], see {!Runtime_candidate.capacity_key} /
    {!Runtime_provider_binding.provider_health_key_of_config}). {!with_slot_result}
    runs a thunk while holding one of the binding's [max_concurrent] permits.

    The intended acquisition site is the provider HTTP round-trip — the OAS
    [Llm_transport] decorator's [complete_sync] / [complete_stream] — NOT the
    whole keeper turn. Holding a permit only across the HTTP call (and not across
    local tool / subprocess execution) is the distinction from a turn-level wrap:
    a keeper running local tools does not occupy a provider-concurrency slot.

    [max_concurrent = None] (or [Some n] with [n <= 0]) runs ungated: no semaphore
    is created and the thunk runs directly. Only the coarse global
    [Fd_accountant.Provider_http] pool then applies. [None] means "no per-binding
    cap", NOT "unprotected".

    Cross-domain note: this uses the same {!Eio.Semaphore} primitive as
    [Fd_accountant.Provider_http] at the same transport boundary, so its
    cross-domain gating behavior is parity with that already-accepted gate. *)

(** [default_wait_timeout_sec ()] reads [MASC_KEEPER_BINDING_SLOT_WAIT_TIMEOUT_SEC]
    (default 15.0, clamped to [[1.0, 300.0]]). It bounds how long
    {!with_slot_result} waits for a permit before returning [`Slot_timeout]. *)
val default_wait_timeout_sec : unit -> float

(** [with_slot_result ?clock ?wait_timeout_sec ~key ~max_concurrent f] runs [f]
    while holding one of [key]'s [max_concurrent] permits, acquired before [f]
    and released when [f] returns, raises, or is cancelled.

    - [max_concurrent = None] / [Some n <= 0]: ungated — returns [Ok (f ())]
      without touching any semaphore.
    - [Some n]: acquires a permit (creating the per-[key] semaphore with capacity
      [n] on first use; a later differing [n] for the same [key] reuses the first
      semaphore — caps are static config). Returns [Ok (f ())] once held.
    - [Error `Slot_timeout]: when [clock] is supplied and no permit became
      available within [wait_timeout_sec] (default {!default_wait_timeout_sec}).
      [f] is NOT run. With no [clock] the acquire blocks without a timeout.

    Release is tied to a flag set synchronously immediately after acquire and
    fired via [Eio.Switch.on_release], so a permit granted in a race with the
    wait-timeout cancellation is still released (no permit leak). *)
val with_slot_result :
  ?clock:_ Eio.Time.clock ->
  ?wait_timeout_sec:float ->
  key:string ->
  max_concurrent:int option ->
  (unit -> 'a) ->
  ('a, [ `Slot_timeout ]) result
