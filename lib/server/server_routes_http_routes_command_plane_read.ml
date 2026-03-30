
open Server_auth
open Server_routes_http_common

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Common = Server_routes_http_common
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime
module Keeper_stream = Server_routes_http_keeper_stream

let add_routes router =
  router
  |> Http.Router.get "/api/v1/command-plane" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_snapshot_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_summary_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/help" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = command_plane_help_http_json () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/topology" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_topology_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/units" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_units_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/operations" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_operations_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/detachments" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_detachments_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/detachment-status" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match command_plane_detachment_status_http_json ~state req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~compress:true ~status:`Bad_request ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/decisions" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_decisions_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/capacity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_capacity_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/alerts" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_alerts_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/traces" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_traces_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/swarm" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_swarm_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/orchestra" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_orchestra_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

