(** Keeper_memory_os_recall — render bounded advisory context from Memory OS files.

    Recall is intentionally one-way at prompt time: it reads persisted facts
    and episodes, sanitizes them, and returns an advisory block suitable for
    OAS [extra_system_context]. *)

val render_context
  :  keeper_id:string
  -> now:float
  -> ?max_facts:int
  -> ?max_episodes:int
  -> ?seed:string
  -> unit
  -> string
(** [?seed] (RFC-0244) is the current-turn text. When present, facts are reranked
    by deterministic lexical relevance to it; when absent, the output is identical
    to the pre-RFC-0244 recency/score ranking. *)

val enabled : unit -> bool
(** Kill-switch flag [MASC_KEEPER_MEMORY_OS_RECALL] (default [true]).
    Read side of Memory OS; the write side (librarian) is gated
    separately by [MASC_KEEPER_MEMORY_OS_LIBRARIAN]. *)

val render_if_enabled
  :  keeper_id:string
  -> now:float
  -> ?seed:string
  -> unit
  -> string option
(** [render_if_enabled ~keeper_id ~now ?seed ()] is [Some block] when the
    flag is on and the store yields advisory content, [None] otherwise.
    [?seed] (RFC-0244) is the current-turn text used for lexical reranking.
    Intended for the [extra_system_context] assembly site. *)
