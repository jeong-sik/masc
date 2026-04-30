module Http = Http_server_eio

open Server_auth

let add_routes router =
  router
  |> Http.Router.get "/api/v1/git/graph" (fun request reqd ->
       with_public_read
         (fun state req reqd ->
           let limit =
             Server_utils.int_query_param req "n" ~default:120
             |> Server_utils.clamp ~min_v:20 ~max_v:500
           in
           let json =
             Git_graph_snapshot.dashboard_http_json
               ~config:state.Mcp_server.room_config ~limit
           in
           Http.Response.json ~compress:true ~request:req
             (Yojson.Safe.to_string json) reqd)
         request reqd)
