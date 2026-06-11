(** OTel Metrics — OpenTelemetry metrics adapter for masc-mcp.

    Drop-in replacement surface for [Prometheus.*] during the
    Prometheus → OTel migration (task-814).

    When [MASC_OTEL_ENABLED=true] metrics are dual-written to the
    Prometheus in-memory store (for /metrics text endpoint) and the
    OTel OTLP exporter pipeline.  When disabled, only the Prometheus
    sink is populated — zero-cost for the OTel path.

    @since 2.150.0 *)

val enabled : unit -> bool
(** Whether OTel-side metrics export is active (reads [MASC_OTEL_ENABLED]). *)

val register_counter   : name:string -> help:string -> ?labels:(string * string) list -> unit -> unit
val register_gauge     : name:string -> help:string -> ?labels:(string * string) list -> unit -> unit
val register_histogram : name:string -> help:string -> ?labels:(string * string) list -> unit -> unit

val inc_counter     : string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit
val set_gauge       : string -> ?labels:(string * string) list -> float -> unit
val inc_gauge       : string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit
val dec_gauge       : string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit
val observe_histogram : string -> ?labels:(string * string) list -> float -> unit

val flush : unit -> unit
(** Flush accumulated OTel metrics into the exporter's GC_metrics queue. *)

val to_prometheus_text : unit -> string
(** Return the Prometheus text-format snapshot (delegates to [Prometheus_store]). *)