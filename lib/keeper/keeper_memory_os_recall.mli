(** Keeper_memory_os_recall — render bounded advisory context from Memory OS files.

    Recall is intentionally one-way at prompt time: it reads persisted facts
    and episodes, sanitizes them, and returns an advisory block suitable for
    OAS [extra_system_context]. *)

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

val render_if_enabled
  :  keeper_id:string
  -> now:float
  -> unit
  -> string option
(** [render_if_enabled ~keeper_id ~now ()] is [Some block] when the
    flag is on and the store yields advisory content, [None] otherwise.
    Intended for the [extra_system_context] assembly site. *)
