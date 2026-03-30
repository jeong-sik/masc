(** Operator action and confirmation handlers *)

let operator_action_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (Server_utils.operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      net = state.Mcp_server.net;
      mcp_session_id = None;
    }
  in
  Operator_control.action_json ?actor_hint:(Server_utils.operator_actor_hint request) ctx args

let operator_confirm_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (Server_utils.operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      net = state.Mcp_server.net;
      mcp_session_id = None;
    }
  in
  Operator_control.confirm_json ?actor_hint:(Server_utils.operator_actor_hint request) ctx args

let operator_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]
