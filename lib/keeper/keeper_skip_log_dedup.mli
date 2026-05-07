(** Per-keeper skip-log deduplication.

    Keepalive sweeps fire every ~30s.  A paused keeper would emit an
    identical [{keeper_paused}] INFO log every sweep (~120 logs/hour).
    This module bounds emission to at most one identical-reason log per
    [ttl_sec], while still surfacing every transition (reason set change)
    immediately.  Prometheus counters are unaffected; only human-visible
    log lines are gated. *)

(** [should_emit ~keeper_name ~reasons ~now ~ttl_sec] returns [true]
    when [keeper_name] has not logged the exact same [reasons] set
    within [ttl_sec] seconds (as measured by [now]).  [reasons] are
    normalised (sorted and joined) so order differences do not create
    false transitions. *)
val should_emit :
  keeper_name:string -> reasons:string list -> now:float -> ttl_sec:float -> bool
