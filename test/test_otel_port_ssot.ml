(* RFC-0089 — OTLP port SSOT. [Otel_spans.probe_endpoint] resolves the OTLP
   port via [port_of_uri], which falls back to
   [Masc_network_defaults.otel_default_port] instead of inlining 4318 (which
   would silently diverge if the configured default were tuned). *)

open Alcotest

let test_explicit_port_wins () =
  check int "explicit URI port is preserved" 9999
    (Otel_spans.port_of_uri (Uri.of_string "http://collector:9999/v1/traces"))

let test_missing_port_falls_back_to_ssot () =
  check int "URI without a port resolves to the OTLP default SSOT"
    Masc_network_defaults.otel_default_port
    (Otel_spans.port_of_uri (Uri.of_string "http://collector/v1/traces"))

let test_ssot_default_value_pinned () =
  (* 4318 is the OTLP/HTTP default port. Pinning it here guards the single
     source of truth so a drive-by edit to the constant is caught. *)
  check int "otel_default_port is the OTLP/HTTP default" 4318
    Masc_network_defaults.otel_default_port

let () =
  run "otel_port_ssot"
    [
      ( "ssot",
        [
          test_case "explicit port wins" `Quick test_explicit_port_wins;
          test_case "missing port falls back to SSOT" `Quick
            test_missing_port_falls_back_to_ssot;
          test_case "default value pinned" `Quick test_ssot_default_value_pinned;
        ] );
    ]
