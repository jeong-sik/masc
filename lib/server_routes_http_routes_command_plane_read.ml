[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth
open Server_tts_proxy
open Server_trpg_rest
open Server_dashboard_http
open Server_routes_http_common
open Server_routes_http_pages
open Server_routes_http_runtime
open Server_routes_http_keeper_stream

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

  |> Http.Router.get "/api/v1/chains/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match command_plane_chain_summary_http_json ~state req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~status:(chain_http_error_status message) ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/chains/events" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         command_plane_chain_events_http ~request:req reqd
       ) request reqd)

  |> Http.Router.prefix_get "/api/v1/chains/runs/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let req_path = Http.Request.path req in
         let prefix = "/api/v1/chains/runs/" in
         let run_id =
           String.sub req_path (String.length prefix)
             (String.length req_path - String.length prefix)
         in
         match command_plane_chain_run_http_json ~state req run_id with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             Http.Response.json ~status:(chain_http_error_status message) ~request:req
               (Yojson.Safe.to_string (command_plane_error_json message))
               reqd
       ) request reqd)
