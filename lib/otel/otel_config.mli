(** OTel Configuration — environment-derived OpenTelemetry setup.

    Feature-flagged via [MASC_OTEL_ENABLED] (default: false). When
    disabled, all span operations are no-ops with zero allocation. *)

val enabled : bool
(** [true] iff [MASC_OTEL_ENABLED] is ["true"] or ["1"]. *)

val endpoint : string
(** OTLP exporter endpoint from [OTEL_EXPORTER_OTLP_ENDPOINT], falling
    back to {!Masc_network_defaults.otel_default_url}. *)

val service_name : string
(** [OTEL_SERVICE_NAME] or ["masc-mcp"]. *)
