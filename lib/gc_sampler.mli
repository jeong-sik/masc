(** OCaml GC stats sampler for Prometheus export.

    Polls [Gc.quick_stat] once per [interval] seconds and writes the six
    {!Prometheus} GC gauge metrics ([masc_gc_minor_words],
    [masc_gc_major_words], [masc_gc_heap_words], [masc_gc_live_words],
    [masc_gc_compactions], [masc_gc_promoted_words]).

    [Gc.quick_stat] does not walk the heap, so the call cost is bounded
    and safe to run on a 30s loop alongside the request path.

    @since PR-0.2.D (RFC pack: knowledge/research/2026-04-masc-ide-strategy/) *)

val sample_once : unit -> unit
(** [sample_once ()] reads [Gc.quick_stat] once and updates the six
    Prometheus GC gauges. Exposed for unit tests so the sampler can be
    exercised without spawning an Eio fiber. *)

val run :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  interval:float ->
  unit
(** [run ~sw ~clock ~interval] spawns a background fiber on [sw] that
    calls {!sample_once} every [interval] seconds. The fiber loops
    until the switch is released and respects [Eio.Cancel].

    No effort is made to align samples to wall-clock boundaries; the
    first sample fires immediately and subsequent samples follow
    [Eio.Time.sleep clock interval] after the previous tick. *)
