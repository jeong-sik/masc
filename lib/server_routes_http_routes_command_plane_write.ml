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

  let add_routes ~sw ~clock router =
  router
  |> Http.Router.post "/api/v1/command-plane/units" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_unit_define" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_define_http_json ~state req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/units/reparent" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_unit_reparent" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_reparent_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/units/reassign" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_unit_reassign" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_unit_reassign_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operation_start" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_start_http_json ~state req ~args with
             | Ok json ->
                 respond_json_with_cors ~status:`Created request reqd
                   (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/pause" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operation_pause" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_pause_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/resume" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operation_resume" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_resume_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/stop" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operation_stop" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_stop_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/finalize" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operation_finalize" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_operation_finalize_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/operations/checkpoint" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operation_checkpoint" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match
               command_plane_operation_checkpoint_http_json ~state req ~args
             with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
        )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/plan" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_dispatch_plan" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_plan_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/assign" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_dispatch_assign" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_assign_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/rebalance" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_dispatch_rebalance" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_rebalance_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/escalate" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_dispatch_escalate" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_escalate_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/recall" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_dispatch_recall" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_recall_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/dispatch/tick" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_dispatch_tick" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_dispatch_tick_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.get "/api/v1/command-plane/policy" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = command_plane_policy_status_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/approve" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_policy_approve" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_approve_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/deny" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_policy_deny" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_deny_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/update" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_policy_update" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_update_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/freeze" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_policy_freeze_unit" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_freeze_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/command-plane/policy/kill-switch" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_policy_kill_switch" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match command_plane_policy_kill_switch_http_json ~state req ~args with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (command_plane_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (command_plane_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.get "/api/v1/operator" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = operator_snapshot_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/operator/digest" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match operator_digest_http_json ~state ~sw ~clock req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
         | Error message ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json message))
       ) request reqd)

  |> Http.Router.post "/api/v1/operator/action" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operator_action" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_action_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (operator_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/operator/confirm" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operator_confirm" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_confirm_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (operator_error_json message))
           with Yojson.Json_error e ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json ("invalid json: " ^ e)))
         )
       ) request reqd)
