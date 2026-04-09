
(** Command-plane and operator POST route handlers for H2 gateway.
    Returns [true] if the route was handled, [false] otherwise. *)

open Server_auth
open Server_dashboard_http
open Server_routes_http
open Server_h2_gateway_helpers

let dispatch ~sw ~clock ~h2_reqd ~httpun_request ~cors ~path
    (httpun_meth : [ `GET | `POST | `DELETE | `OPTIONS | `PUT | `HEAD
                    | `CONNECT | `TRACE | `Other of string ]) =
  let h2_authorize_tool state ~tool_name =
    authorize_tool_request
      ~base_path:state.Mcp_server.room_config.base_path
      ~tool_name httpun_request
  in
  ignore (h2_authorize_tool);
  let handled = ref true in
  (match httpun_meth, path with
      | `POST, "/api/v1/operator/action" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operator_action" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match operator_action_http_json ~state ~sw ~clock httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (operator_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_unit_define" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_unit_define_http_json ~state httpun_request
                        ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units/reparent" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_unit_reparent" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_unit_reparent_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units/reassign" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_unit_reassign" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_unit_reassign_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_start" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_operation_start_http_json ~state httpun_request
                        ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~status:`Created ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/checkpoint" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_checkpoint" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_operation_checkpoint_http_json ~state
                        httpun_request ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/pause" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_pause" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_pause_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/resume" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_resume" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_resume_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/stop" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_stop" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_stop_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/finalize" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_finalize" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_finalize_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/plan" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_plan" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_plan_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/assign" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_assign" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_assign_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/rebalance" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_rebalance" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_rebalance_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/escalate" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_escalate" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_escalate_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/recall" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_recall" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_recall_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/tick" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_tick" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_tick_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/approve" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_policy_approve" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_approve_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/deny" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_policy_deny" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_deny_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/update" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_policy_update" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_update_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/freeze" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_policy_freeze_unit" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_freeze_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/kill-switch" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_policy_kill_switch" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_kill_switch_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/operator/confirm" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operator_confirm" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match operator_confirm_http_json ~state ~sw ~clock httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (operator_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/dashboard/governance/approvals/resolve" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operator_confirm" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      dashboard_governance_approval_resolve_http_json ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (operator_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | _ -> handled := false);
  !handled
