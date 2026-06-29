(** OTel Configuration — reads environment variables for OpenTelemetry setup.

    Feature-flagged via [MASC_OTEL_ENABLED] (default: true).
    When explicitly disabled, all span operations are no-ops with zero allocation.

    The endpoint defaults to [127.0.0.1] (not [localhost]) to avoid IPv6
    resolution racing with Docker's IPv4-only port binding during startup.
    Override via [OTEL_EXPORTER_OTLP_ENDPOINT] if needed. *)

(* Delegates to the shared env parser instead of an ad-hoc match so
   [MASC_OTEL_ENABLED] follows the same truthy/falsy vocabulary as every other
   MASC bool flag (case-insensitive true/1/yes/on vs false/0/no/off) and a
   malformed value warns rather than silently enabling. *)
let enabled = Env_config_core.get_bool ~default:true "MASC_OTEL_ENABLED"

let endpoint =
  let raw =
    Sys.getenv_opt "OTEL_EXPORTER_OTLP_ENDPOINT"
    |> Option.value ~default:Masc_network_defaults.otel_default_url
  in
  Masc_network_defaults.normalize_loopback_base_url raw

let service_name =
  Sys.getenv_opt "OTEL_SERVICE_NAME"
  |> Option.value ~default:"masc"
