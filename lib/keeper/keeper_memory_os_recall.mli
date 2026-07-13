(** Keeper_memory_os_recall — render exact stored context from Memory OS files.

    Recall is intentionally one-way at prompt time: it reads persisted facts
    and episodes and returns their exact text in an advisory block suitable for
    OAS [extra_system_context]. *)

val render_context
  :  keeper_id:string
  -> now:float
  -> unit
  -> string
(** Render every current fact and episode in persisted source order, without
    truncation, ranking, deduplication, or fixed-size slices. *)

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
