
include Server_routes_http_common
include Server_routes_http_pages
include Server_routes_http_runtime
include Server_routes_http_keeper_stream

module Http = Http_server_eio

let make_routes ~port ~host ~sw ~clock =
  (* Register connectors before routes are wired up *)
  Channel_gate_connector.register (module Channel_gate_discord_state);
  Http.Router.empty
  |> Server_routes_http_routes_frontend.add_routes ~port ~host
  |> Server_routes_http_routes_room.add_routes
  |> Server_routes_http_routes_command_plane_read.add_routes
  |> Server_routes_http_routes_command_plane_write.add_routes ~sw ~clock
  |> Server_routes_http_routes_dashboard.add_routes ~sw ~clock
  |> Server_routes_http_routes_provider_runs.add_routes ~sw
  |> Server_routes_http_routes_activity.add_routes ~sw ~clock
  |> Server_routes_http_routes_channel_gate.add_routes ~sw ~clock
