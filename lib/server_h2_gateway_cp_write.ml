[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth
open Server_dashboard_http
open Server_routes_http
open Server_h2_gateway_helpers

(* Command-plane POST route handler.
   Returns [true] if the route was handled, [false] otherwise. *)
let dispatch ~h2_reqd ~httpun_request ~cors ~sw ~clock path =
  let h2_authorize_tool state ~tool_name =
    authorize_tool_request
      ~base_path:state.Mcp_server.room_config.base_path
      ~tool_name httpun_request
  in
  let handle_cp_post ~tool_name ~handler ~error_json =
    let state = get_server_state () in
    (match h2_authorize_tool state ~tool_name with
     | Error err ->
         let status = http_status_of_auth_error err in
         h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
     | Ok () ->
         h2_read_body h2_reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             (match handler ~state ~httpun_request ~args with
              | Ok json ->
                  h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                    ~extra_headers:cors
              | Error message ->
                  h2_respond_json h2_reqd
                    (Yojson.Safe.to_string (error_json message))
                    ~status:`Bad_request ~extra_headers:cors)
           with Yojson.Json_error msg ->
             h2_respond_json h2_reqd
               (Yojson.Safe.to_string
                  (error_json (Printf.sprintf "invalid json: %s" msg)))
               ~status:`Bad_request ~extra_headers:cors));
    true
  in
  let cp_post ~tool_name ~handler =
    handle_cp_post ~tool_name ~handler ~error_json:command_plane_error_json
  in
  let op_post ~tool_name ~handler =
    handle_cp_post ~tool_name ~handler ~error_json:operator_error_json
  in
  ignore (sw, clock);
  match path with
  | "/api/v1/command-plane/units" ->
      cp_post ~tool_name:"masc_unit_define"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_unit_define_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/units/reparent" ->
      cp_post ~tool_name:"masc_unit_reparent"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_unit_reparent_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/units/reassign" ->
      cp_post ~tool_name:"masc_unit_reassign"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_unit_reassign_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/operations" ->
      cp_post ~tool_name:"masc_operation_create"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_operation_create_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/operations/checkpoint" ->
      cp_post ~tool_name:"masc_operation_checkpoint"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_operation_checkpoint_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/operations/pause" ->
      cp_post ~tool_name:"masc_operation_pause"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_operation_pause_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/operations/resume" ->
      cp_post ~tool_name:"masc_operation_resume"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_operation_resume_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/operations/stop" ->
      cp_post ~tool_name:"masc_operation_stop"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_operation_stop_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/operations/finalize" ->
      cp_post ~tool_name:"masc_operation_finalize"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_operation_finalize_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/dispatch/plan" ->
      cp_post ~tool_name:"masc_dispatch_plan"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_dispatch_plan_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/dispatch/assign" ->
      cp_post ~tool_name:"masc_dispatch_assign"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_dispatch_assign_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/dispatch/rebalance" ->
      cp_post ~tool_name:"masc_dispatch_rebalance"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_dispatch_rebalance_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/dispatch/escalate" ->
      cp_post ~tool_name:"masc_dispatch_escalate"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_dispatch_escalate_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/dispatch/recall" ->
      cp_post ~tool_name:"masc_dispatch_recall"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_dispatch_recall_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/dispatch/tick" ->
      cp_post ~tool_name:"masc_dispatch_tick"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_dispatch_tick_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/policy/approve" ->
      cp_post ~tool_name:"masc_policy_approve"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_policy_approve_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/policy/deny" ->
      cp_post ~tool_name:"masc_policy_deny"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_policy_deny_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/policy/update" ->
      cp_post ~tool_name:"masc_policy_update"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_policy_update_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/policy/freeze" ->
      cp_post ~tool_name:"masc_policy_freeze_unit"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_policy_freeze_http_json ~state httpun_request ~args)
  | "/api/v1/command-plane/policy/kill-switch" ->
      cp_post ~tool_name:"masc_policy_kill_switch"
        ~handler:(fun ~state ~httpun_request ~args ->
          command_plane_policy_kill_switch_http_json ~state httpun_request ~args)
  | "/api/v1/operator/action" ->
      op_post ~tool_name:"masc_operator_action"
        ~handler:(fun ~state ~httpun_request:_ ~args ->
          operator_action_http_json ~state ~sw ~clock httpun_request ~args)
  | "/api/v1/operator/confirm" ->
      op_post ~tool_name:"masc_operator_confirm"
        ~handler:(fun ~state ~httpun_request:_ ~args ->
          operator_confirm_http_json ~state ~sw ~clock httpun_request ~args)
  | _ -> false
