open Server_command_plane_http_support

let command_plane_operation_checkpoint_http_json ~deps ~state request ~args =
  match
    Command_plane_v2.checkpoint_operation state.Mcp_server.room_config
      ~actor:(command_plane_actor deps request) args
  with
  | Ok operation ->
      Ok
        (`Assoc
          [
            ("status", `String "ok");
            ("result", Command_plane_v2.operation_to_json operation);
            ( "traces",
              Command_plane_v2.list_traces_json state.Mcp_server.room_config
                ~operation_id:operation.operation_id () );
          ])
  | Error message -> Error message
  | exception Invalid_argument message -> Error message

let command_plane_unit_reparent_http_json ~deps ~state request ~args =
  Command_plane_v2.unit_reparent_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_unit_reassign_http_json ~deps ~state request ~args =
  Command_plane_v2.unit_reassign_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_operation_pause_http_json ~deps ~state request ~args =
  Command_plane_v2.pause_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_operation_resume_http_json ~deps ~state request ~args =
  Command_plane_v2.resume_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_operation_stop_http_json ~deps ~state request ~args =
  Command_plane_v2.stop_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_operation_finalize_http_json ~deps ~state request ~args =
  Command_plane_v2.finalize_operation_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_dispatch_plan_http_json ~state _request ~args =
  Ok (Command_plane_v2.dispatch_plan_json state.Mcp_server.room_config args)

let command_plane_dispatch_assign_http_json ~deps ~state request ~args =
  Command_plane_v2.dispatch_assign_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_dispatch_rebalance_http_json ~deps ~state request ~args =
  Command_plane_v2.dispatch_rebalance_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_dispatch_escalate_http_json ~deps ~state request ~args =
  Command_plane_v2.dispatch_escalate_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_dispatch_recall_http_json ~deps ~state request ~args =
  Command_plane_v2.dispatch_recall_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_dispatch_tick_http_json ~deps ~state request ~args =
  Command_plane_v2.dispatch_tick_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_policy_status_http_json ~state =
  Command_plane_v2.policy_status_json state.Mcp_server.room_config

let command_plane_policy_approve_http_json ~deps ~state request ~args =
  Command_plane_v2.policy_approve_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_policy_deny_http_json ~deps ~state request ~args =
  Command_plane_v2.policy_deny_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_policy_update_http_json ~deps ~state request ~args =
  Command_plane_v2.policy_update_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_policy_freeze_http_json ~deps ~state request ~args =
  Command_plane_v2.policy_freeze_unit_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_policy_kill_switch_http_json ~deps ~state request ~args =
  Command_plane_v2.policy_kill_switch_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

