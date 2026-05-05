(** Weighted Fair Queueing overflow buffer for keepers waiting on
    admission tokens.

    Layer 3 of RFC-0026 §3.4.  Holds keepers that the admission router
    (Layer 2, [Keeper_admission_router]) decided to [Wait] because all
    their above-floor candidates were temporarily throttled.  When a
    provider's bucket refills, the caller invokes [wake_one] to pull
    the highest-deficit waiter back to the router.

    Algorithmic basis: Deficit Round Robin (Shreedhar-Varghese 1996,
    extended to weights).  Per-entry deficit counter increments by
    [weight] each time the entry is skipped during a wake event;
    [wake_one] picks the entry with the highest deficit and resets it
    to zero on dequeue.  This bounds the per-keeper wait to
    O(max_packet_size / weight) — translated to admission, that means
    a high-weight keeper never waits more than 1/weight as long as a
    low-weight peer.

    What this module does NOT:

    - Decide whether a refilled provider is compatible with a queued
      keeper's candidate list.  The caller (typically the heartbeat
      loop or a refill-event hook) is responsible for re-running
      [Keeper_admission_router.schedule] after [wake_one] returns
      [Some entry].
    - Talk to [Keeper_provider_token_bucket].  The queue holds keeper
      identifiers and weights only; bucket lookup happens at wake time
      via the router.
    - Persist across restarts.  The queue is in-memory; on crash the
      caller is responsible for re-enqueuing in-flight keepers from
      durable state. *)

type entry = {
  keeper_id : string;
  weight : int;
  enqueued_at : float;  (** Unix timestamp; for FIFO tie-breaking. *)
}

type t
(** Opaque mutable WFQ queue. *)

val create : unit -> t
(** Fresh empty queue. *)

(** {1 Mutating operations} *)

val enqueue : t -> entry -> unit
(** Append [entry] to the queue.  No-op if [entry.keeper_id] is
    already in the queue (idempotent so the heartbeat loop can call
    [enqueue] without first checking membership). *)

val wake_one : t -> entry option
(** Remove and return the entry with the highest [deficit / weight]
    ratio.  All other entries' deficits are incremented by their
    [weight] (Shreedhar-Varghese DRR step).  [None] when queue empty.

    Cost: O(N) where N = current queue length.  Acceptable for
    expected fleet sizes (≤ 50 keepers).  A pairing-heap variant is
    a follow-up if profile shows hotspot. *)

val remove : t -> string -> bool
(** Remove the entry with [keeper_id]; returns [true] if removed,
    [false] if absent.  Used by the supervisor when a keeper is
    explicitly stopped while queued. *)

(** {1 Observability} *)

val snapshot : t -> entry list
(** Read-only copy of the queue contents in current insertion order
    (NOT deficit order — the deficit ordering is reconstructed by
    [wake_one]).  Used by dashboards and diagnostic scripts.  Pure
    with respect to deficit state. *)

val depth : t -> int
(** Current number of waiting entries.  O(1). *)

val deficit_of : t -> string -> int option
(** Current deficit counter for [keeper_id], or [None] if not in
    queue.  For test inspection only — production code should not
    branch on deficit values directly. *)
