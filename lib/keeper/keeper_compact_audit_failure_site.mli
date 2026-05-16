(** Keeper_compact_audit_failure_site — closed sum for [site] label on
    [metric_keeper_compact_audit_failures] (6 sites).

    [Pending_overwrite] fires when a second [ContextCompactStarted] arrives
    for a keeper that still has a pending start (the previous start gets
    silently displaced from the in-memory pair-lookup table; the persisted
    JSONL row is unaffected and pair_events later classifies it as
    [Orphan_start]).  [Pending_ttl_evict] fires when the TTL sweeper drops
    a pending entry that never received a matching [ContextCompacted]
    (process crash mid-compaction, OAS emission gap, etc.). *)

type t =
  | Retention_prune
  | Persist_start
  | Persist_complete
  | Handle_event
  | Pending_overwrite
  | Pending_ttl_evict

val to_label : t -> string
