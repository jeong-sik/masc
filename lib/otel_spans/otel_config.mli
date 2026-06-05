(** OTel Configuration — environment-derived OpenTelemetry setup.

    Feature-flagged via [MASC_OTEL_ENABLED] (default: true). When
    explicitly disabled, all span operations are no-ops with zero allocation. *)

val enabled : bool
(** [false] iff [MASC_OTEL_ENABLED] is ["false"] or ["0"]. *)

val endpoint : string
(** OTLP exporter endpoint from [OTEL_EXPORTER_OTLP_ENDPOINT], falling
    back to {!Masc_network_defaults.otel_default_url}. *)

val service_name : string
(** [OTEL_SERVICE_NAME] or ["masc"]. *)
