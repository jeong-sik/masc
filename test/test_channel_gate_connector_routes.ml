open Alcotest

module Routes = Masc_mcp.Server_routes_http_routes_channel_gate

let test_resolve_connector_status_name_prefers_explicit_name () =
  check (option string) "name wins and normalizes" (Some "discord")
    (Routes.resolve_connector_status_name ~name:"  Discord  "
       ~channel:"telegram" ())

let test_resolve_connector_status_name_normalizes_legacy_channel () =
  check (option string) "legacy channel lowercased" (Some "discord")
    (Routes.resolve_connector_status_name ~channel:"  DISCORD  " ())

let test_resolve_connector_status_name_ignores_blank_inputs () =
  check (option string) "blank query params ignored" None
    (Routes.resolve_connector_status_name ~name:"   " ~channel:"   " ())

let () =
  run "channel_gate_connector_routes"
    [
      ( "resolve_connector_status_name",
        [
          test_case "prefers explicit name" `Quick
            test_resolve_connector_status_name_prefers_explicit_name;
          test_case "normalizes legacy channel" `Quick
            test_resolve_connector_status_name_normalizes_legacy_channel;
          test_case "ignores blank inputs" `Quick
            test_resolve_connector_status_name_ignores_blank_inputs;
        ] );
    ]
