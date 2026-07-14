(** Computed-at-export-tick OTel samples for runtime health surfaces with no
    store cell: console-sink writer health (#20684: dropped mirror lines +
    queue depth), keeper transition-audit drain queue depth (#20677), fd
    accounting (open/limit/pressure/in-flight per kind), event-bus resource
    pressure (#20676: live subscriber capacity / depth / published / drained /
    dropped gauges for the masc_domain and oas_runtime buses),
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
val register_once : masc_root:string -> unit -> unit

module For_testing : sig
  val samples : masc_root:string -> unit -> Otel_metrics.sample list
  val bus_samples_of
    :  bus_label:string
    -> Agent_sdk.Event_bus.t
    -> Otel_metrics.sample list
  val reset_store_cache : unit -> unit
end
