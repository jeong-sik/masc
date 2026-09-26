(** OTel Configuration — environment-derived OpenTelemetry setup.

    Feature-flagged via [MASC_OTEL_ENABLED]. When disabled, all span
    operations are no-ops with zero allocation. *)

val enabled : bool
(** {!Env_config_runtime.Otel.enabled}, resolved once at module load. *)

val endpoint : string
(** OTLP exporter endpoint from [OTEL_EXPORTER_OTLP_ENDPOINT], falling
    back to {!Masc_network_defaults.otel_default_url}.  Loopback hosts
    ([localhost]) are normalized to [127.0.0.1] via
    {!Masc_network_defaults.normalize_loopback_base_url} to avoid IPv6
    resolution racing with Docker's IPv4-only port binding. *)

val service_name : string
(** [OTEL_SERVICE_NAME] or ["masc"]. *)
