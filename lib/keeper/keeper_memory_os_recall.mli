(** Keeper_memory_os_recall — render exact stored context from Memory OS files.

    Recall is intentionally one-way at prompt time: it reads persisted facts
    and episodes and returns their exact text in an advisory block suitable for
    OAS [extra_system_context].

    masc#25052 P1: recall used to inject every current fact/episode in the
    store, unbounded. It now applies a selection budget
    ([Keeper_config.keeper_memory_os_recall_max_facts] /
    [_max_episodes], live-tunable, default sized above all observed real
    volumes): within budget, nothing changes (same items, same order); over
    budget, the most-recent-[reference_time]/[created_at] items survive,
    still rendered in their original relative order, and the drop is logged
    plus counted (never silent).

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

val render_context
  :  keeper_id:string
  -> now:float
  -> unit
  -> string
(** Render every current fact and episode in persisted source order, up to
    the configured selection budget (see the module doc). Below budget this
    is byte-for-byte the old "no truncation, ranking, deduplication, or
    fixed-size slices" behavior; over budget, the most recent items are kept
    and a truncation is logged and counted. *)

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
