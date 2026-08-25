(** Periodically sampled runtime health surfaces (masc#29023: sampling
    is driven by the store-writer fiber, not the OTLP export tick, so
    the values exist with or without a collector). Covers surfaces with
    no at-source store cell: console-sink writer health (#20684: dropped mirror lines +
    queue depth), keeper transition-audit drain queue depth (#20677), fd
    accounting (open/limit/pressure/in-flight per kind), event-bus
    backpressure (#20676: masc_event_bus_* subscriber depth / drops /
    publish-blocked seconds for the masc_domain and agent_core_runtime buses),
    HTTP pool occupancy (masc_pool_* from Pool_metrics.current_snapshot —
    this IS the pool export wiring), and on-disk telemetry store sizes
    (#20682: masc_store_bytes / masc_store_files, directory walks cached
    for 60s).

    RFC-0217 observable pattern: the registered source is polled on each
    exporter tick, so every sample is present from process start — no
    absence-vs-zero ambiguity for these surfaces. *)

(** Register the sample source with [Otel_metrics]. Idempotent; call once
    from server bootstrap (next to
    [Otel_metric_store.register_otel_source_once]). [masc_root] anchors the
    watched store directories. *)
(** Start the maintenance fiber that refreshes the store cells every
    half minute (the first write happens synchronously before the fiber starts). Call once from server bootstrap next to the
    other maintenance fibers. *)
val start_store_writer :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  masc_root:string ->
  unit ->
  unit

module For_testing : sig
  val samples : masc_root:string -> unit -> Otel_metrics.sample list

  (** Compute the samples once and land them in [Otel_metric_store]
      cells via [set_gauge] (masc#29023) — the internal step the
      {!start_store_writer} fiber repeats. Returns how many samples
      were written. Exposed for tests; production callers go through
      {!start_store_writer}. *)
  val write_samples_to_store : masc_root:string -> unit -> int
  val reset_store_cache : unit -> unit
end
