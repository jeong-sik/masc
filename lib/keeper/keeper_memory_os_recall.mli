(** Keeper_memory_os_recall — render exact stored context from Memory OS files.

    Recall is intentionally one-way at prompt time: it reads persisted facts
    and episodes and returns their exact text in an advisory block suitable for
    OAS [extra_system_context].

    Recall applies a bounded per-turn working-set projection
    ([Keeper_config.keeper_memory_os_recall_max_facts] /
    [_max_episodes], live-tunable, default 8 facts / 2 episodes). The
    most-recent-[reference_time]/[created_at] items survive, still rendered in
    their original relative order, and every drop is visible in the prompt
    gauge, logs, metrics, and recall-injection ledger. Persisted stores are not
    mutated, and selection never inspects claim or summary prose.

    RFC-0351 L3: the count budgets bound how many items are injected, not how
    large they render. A rendered byte budget
    ([Keeper_config.keeper_memory_os_recall_max_bytes]) now also applies and is
    enforced rather than merely logged — the oldest episodes are dropped until
    the block fits, survivors keep their original order, and facts are never
    dropped by it. *)

val select_pairs_within_byte_budget
  :  budget:int
  -> ('a * string) list
  -> ('a * string) list * int
(** [select_pairs_within_byte_budget ~budget pairs] keeps the most recent pairs
    whose rendered lines (the [string] of each pair, plus one byte per newline
    joiner) fit in [budget], returning them in their ORIGINAL relative order
    together with the number dropped. Length arithmetic only: no importance
    score and no inspection of line content. *)

val render_gauge_line
  :  facts_injected:int
  -> facts_stored:int
  -> episodes_injected:int
  -> episodes_stored:int
  -> rendered_bytes:int
  -> byte_budget:int
  -> string
(** Render the store gauge the recall block carries (RFC-0351 L1): what reached
    the model this turn against what is stored, plus the byte budget. Counts and
    totals only — the surrounding wording lives in
    [config/prompts/keeper.memory_os_recall.context.md]. A [byte_budget] of 0
    renders as unbounded rather than as a literal zero. *)

val render_context
  :  keeper_id:string
  -> now:float
  -> unit
  -> string
(** Render the configured working set of current facts and episodes in
    persisted source order (see the module doc). The most recent items are
    selected by typed time fields; exact text is preserved. *)

val enabled : unit -> bool
(** Kill-switch flag [MASC_KEEPER_MEMORY_OS_RECALL] (default [true]).
    Read side of Memory OS; the write side (librarian) is gated
    separately by [MASC_KEEPER_MEMORY_OS_LIBRARIAN]. *)

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
    [Some block] with an explicit unavailable advisory when recall fails after
    the flag is on, and [None] when disabled or when no memory exists. Intended
    for the [extra_system_context] assembly site.
    As a side effect (RFC-0264 P2) it appends a best-effort recall-injection
    record — which fact/episode keys reached the prompt — keyed by
    [trace_id]/[turn]; the write never affects the returned block. *)
