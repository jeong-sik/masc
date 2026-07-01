(** Keeper_memory_os_recall — render bounded advisory context from Memory OS files.

    Recall is intentionally one-way at prompt time: it reads persisted facts
    and episodes, sanitizes them, and returns an advisory block suitable for
    OAS [extra_system_context]. *)

val default_max_facts : int
(** Alias for {!Keeper_memory_os_policy.recall_default_max_facts}. *)

val default_max_shared_facts : int
(** Alias for {!Keeper_memory_os_policy.recall_default_max_shared_facts}. *)

val default_max_episodes : int
(** Alias for {!Keeper_memory_os_policy.recall_default_max_episodes}. *)

val render_context
  :  keeper_id:string
  -> now:float
  -> ?max_facts:int
  -> ?max_episodes:int
  -> unit
  -> string
(** Facts are ordered by the structural truth anchor ([last_verified_at] else
    [first_seen]), most-recently-verified first. RFC-0247 removed the composite
    score, the lexical seed-rerank, and spreading-activation reranking: recall
    ordering is structural, never a learned number. *)

val enabled : unit -> bool
(** Kill-switch flag [MASC_KEEPER_MEMORY_OS_RECALL] (default [true]).
    Read side of Memory OS; the write side (librarian) is gated
    separately by [MASC_KEEPER_MEMORY_OS_LIBRARIAN]. *)

val facts_recency_ranked
  :  now:float -> Keeper_memory_os_types.fact list -> Keeper_memory_os_types.fact list
(** Filter and order facts for prompt recall: current, recallable, not
    self-observation, most-recent truth-anchor first. Exposed for tests. *)

val render_if_enabled
  :  keeper_id:string
  -> now:float
  -> trace_id:string
  -> turn:int
  -> masc_root:string
  -> unit
  -> string option
(** [render_if_enabled ~keeper_id ~now ~trace_id ~turn ~masc_root ()] is
    [Some block] when the flag is on and the store yields advisory content,
    [Some block] with a sanitized unavailable advisory when recall fails after
    the flag is on, and [None] when disabled or when no memory exists. Intended
    for the [extra_system_context] assembly site.
    As a side effect (RFC-0264 P2) it appends a best-effort recall-injection
    record — which fact/episode keys reached the prompt — keyed by
    [trace_id]/[turn]; the write never affects the returned block. *)
