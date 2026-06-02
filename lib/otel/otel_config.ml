(** OTel Configuration — reads environment variables for OpenTelemetry setup.

    Feature-flagged via [MASC_OTEL_ENABLED] (default: false).
    When disabled, all span operations are no-ops with zero allocation. *)

let enabled =
  match Sys.getenv_opt "MASC_OTEL_ENABLED" with
  | Some "true" | Some "1" -> true
  | _ -> false

let endpoint =
  Sys.getenv_opt "OTEL_EXPORTER_OTLP_ENDPOINT"
  |> Option.value ~default:Masc_network_defaults.otel_default_url

let service_name =
  Sys.getenv_opt "OTEL_SERVICE_NAME"
  |> Option.value ~default:"masc-mcp"
