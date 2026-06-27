(** Keeper_memory_os_policy — structural retention order for the Memory OS.

    RFC-0247 removed the composite importance score and every input it
    multiplied. What remains is the structural order the bounded store cap and
    the write-time re-observation merge need — not a relevance ranking. *)

open Keeper_memory_os_types

(** Structural retention rank for the bounded store cap (RFC-0247 §-1). NOT a
    relevance score: a deterministic two-tier order — durable categories outrank
    Ephemeral, then most-recently-verified (else first-seen) wins. Used only to
    decide which rows the size cap drops, never to rank recall. *)
val retention_rank : now:float -> fact -> float

(** Fold a re-observation of an existing fact into that fact: the only effect is
    to refresh [last_verified_at] to [now] (re-extraction is fresh evidence the
    claim still holds). Identity and first-seen provenance are preserved. The
    prior confidence-blend and access-count bump fed the deleted score and are
    gone — there is no numeric strength to move. *)
val reobserve_fact : now:float -> existing:fact -> incoming:fact -> fact

(** Diagnostic attention threshold for the dashboard's events:fact byte ratio.
    This is not a pruning or recall-ranking policy; it only marks stores whose
    event log is large relative to facts so operators can inspect compaction
    pressure. *)
val events_to_facts_ratio_attention_threshold : float
