(** OTel Configuration — reads environment variables for OpenTelemetry setup.

    Feature-flagged via [MASC_OTEL_ENABLED] (default: false — no collector
    ships with the default install, and a default-on exporter spent its days
    health-checking 127.0.0.1:4318 with nothing listening). Turn it on with
    [otel] enabled = true in runtime.toml, or the env var. When disabled,
    all span operations are no-ops with zero allocation.

    The endpoint defaults to [127.0.0.1] (not [localhost]) to avoid IPv6
    resolution racing with Docker's IPv4-only port binding during startup.
    Override via [OTEL_EXPORTER_OTLP_ENDPOINT] if needed. *)

(* Delegates to the shared env parser instead of an ad-hoc match so
   [MASC_OTEL_ENABLED] follows the same truthy/falsy vocabulary as every other
   MASC bool flag (case-insensitive true/1/yes/on vs false/0/no/off) and a
   malformed value warns rather than silently enabling. *)
let enabled = Env_config_core.get_bool ~default:false "MASC_OTEL_ENABLED"

(* Same reader as [enabled] above. These two used [Sys.getenv_opt], which
   skips the boot-time config overrides, so MASC_OTEL_ENABLED could be
   declared in runtime.toml while the endpoint and service name next to it
   were ignored (#21972 P2-2).

   Still resolved once, at module load. The exporter is installed at boot and
   [OT.Globals.service_name] is assigned there, so turning these into
   functions would advertise a runtime knob the exporter does not honour. *)
let endpoint =
  Env_config_core.raw_value_opt "OTEL_EXPORTER_OTLP_ENDPOINT"
  |> Option.value ~default:Masc_network_defaults.otel_default_url
  |> Masc_network_defaults.normalize_loopback_base_url

let service_name =
  Env_config_core.raw_value_opt "OTEL_SERVICE_NAME"
  |> Option.value ~default:"masc"
