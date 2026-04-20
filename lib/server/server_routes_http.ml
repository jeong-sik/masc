
include Server_routes_http_common
include Server_routes_http_pages
include Server_routes_http_runtime
include Server_routes_http_keeper_stream

module Http = Http_server_eio

let make_routes ~port ~host ~sw ~clock =
  (* Register connectors before routes are wired up *)
  Channel_gate_connector.register (module Channel_gate_discord_state);
  Channel_gate_connector.register (module Channel_gate_imessage_state);
  Http.Router.empty
  |> Server_routes_http_routes_frontend.add_routes ~port ~host
  |> Server_routes_http_routes_room.add_routes
  |> Server_routes_http_routes_dashboard.add_routes ~sw ~clock
  |> Server_routes_http_routes_provider_runs.add_routes ~sw
  |> Server_routes_http_routes_cascade.add_routes
  |> Server_routes_http_routes_verification.add_routes
  |> Server_routes_http_routes_attribution.add_routes
  |> Server_routes_http_routes_activity.add_routes ~sw ~clock
  |> Server_routes_http_routes_artifacts.add_routes
  |> Server_routes_http_routes_legendary_bash.add_routes
  |> Server_routes_http_routes_channel_gate.add_routes ~sw ~clock
  |> Server_routes_http_routes_sidecar.add_routes ~sw ~clock
