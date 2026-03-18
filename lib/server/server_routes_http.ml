[@@@warning "-32-33-69"]

include Server_routes_http_common
include Server_routes_http_pages
include Server_routes_http_runtime
include Server_routes_http_keeper_stream

module Http = Http_server_eio

let make_routes ~port ~host ~sw ~clock =
  Http.Router.empty
  |> Server_routes_http_routes_frontend.add_routes ~port ~host
  |> Server_routes_http_routes_room.add_routes
  |> Server_routes_http_routes_dashboard.add_routes ~sw ~clock
  |> Server_routes_http_routes_command_plane_read.add_routes
  |> Server_routes_http_routes_command_plane_write.add_routes ~sw ~clock
  |> Server_routes_http_routes_social.add_routes
