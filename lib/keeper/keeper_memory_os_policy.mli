(** Keeper_memory_os_policy — structural retention order for the Memory OS.

    RFC-0247 removed the composite importance score and every input it
    multiplied. What remains is the structural order the bounded store cap and
    the write-time re-observation merge need — not a relevance ranking. *)

open Keeper_memory_os_types

(** {1 Recall and retention size policy} *)

(** Per-keeper fact retention target: the low-water size the facts cap trims
    back to. This is not the recall scan window; recall scans
    {!fact_store_max} so it can see the whole bounded store between caps. *)
val fact_recall_window : int

(** High-water fact cap trigger and full bounded-store recall scan window. *)
val fact_store_max : int

(** Low-water event-log retention target. *)
val event_recall_window : int

(** High-water event-log retention trigger. *)
val event_store_max : int

(** Low-water episode-file retention target. *)
val episode_file_window : int

(** High-water episode-file retention trigger. *)
val episode_file_store_max : int

(** Default number of keeper-local facts injected into recall context. *)
val recall_default_max_facts : int

(** Default number of memory episodes injected into recall context. *)
val recall_default_max_episodes : int

(** Default number of shared-tier facts appended after keeper-local recall. *)
val recall_default_max_shared_facts : int

(** Episode tail scan used before current/prompt-recallable filtering. *)
val recall_episode_tail_scan : int

(** Maximum age (seconds) before a Durable_knowledge fact with no explicit
    [valid_until] is considered too stale for consensus promotion.
    Only enforced when [fact_effective_valid_until] returns [None]. *)
val max_consensus_staleness : float

(** Structural retention rank for the bounded store cap (RFC-0247 §-1). NOT a
    relevance score: a deterministic two-tier order — durable categories outrank
    Ephemeral, then most-recently-verified (else first-seen) wins. Used only to
    decide which rows the size cap drops, never to rank recall. *)
val retention_rank : now:float -> fact -> float

(** Provenance of a re-observation reaching {!reobserve_fact} (RFC-0285 §8).
    [Recalled_echo] means the incoming claim's identity was recall-injected
    into the conversation window the librarian summarized — the model restated
    its own prompt, which is not fresh evidence. The write boundary decides
    this once (the production caller joins against
    {!Keeper_recall_injection_window.recently_injected}); tests exercising the
    legacy semantics pass [Independent_observation]. A closed sum rather than
    an optional flag so no call site can skip the judgment. *)
type reobservation_provenance =
  | Independent_observation
  | Recalled_echo

(** Fold a re-observation of an existing fact into that fact: for an
    [Independent_observation] the only effect is to refresh [last_verified_at]
    to [now] (re-extraction is fresh evidence the claim still holds). For a
    [Recalled_echo] the row is inherited whole — an echo must never advance the
    truth anchor that recall's recency ranking reads, or a fact can sustain its
    own recall slot indefinitely (the RFC-0285 §8 flywheel). Identity and
    first-seen provenance are preserved in both cases. The prior
    confidence-blend and access-count bump fed the deleted score and are gone —
    there is no numeric strength to move. *)
val reobserve_fact
  :  now:float
  -> provenance:reobservation_provenance
  -> existing:fact
  -> incoming:fact
  -> fact

(** Diagnostic attention threshold for the dashboard's events:fact byte ratio.
    This is not a pruning or recall-ranking policy; it only marks stores whose
    event log is large relative to facts so operators can inspect compaction
    pressure. *)
val events_to_facts_ratio_attention_threshold : float
