open Tool_command_plane_support

let handle_unit_update (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.unit_update_json ctx.config ~actor:ctx.agent_name args)

let handle_unit_reparent (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.unit_reparent_json ctx.config ~actor:ctx.agent_name args)

let handle_unit_reassign (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.unit_reassign_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_pause (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.pause_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_resume (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.resume_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_stop (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.stop_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_finalize (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.finalize_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_plan (ctx : (_, _) context) args : tool_result =
  (true, Yojson.Safe.to_string (Command_plane_v2.dispatch_plan_json ctx.config args))

let handle_dispatch_route (ctx : (_, _) context) args : tool_result =
  handle_dispatch_plan ctx args

let handle_dispatch_assign (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.dispatch_assign_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_rebalance (ctx : (_, _) context) args : tool_result =
  json_result
    (Command_plane_v2.dispatch_rebalance_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_escalate (ctx : (_, _) context) args : tool_result =
  json_result
    (Command_plane_v2.dispatch_escalate_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_recall (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.dispatch_recall_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_tick (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.dispatch_tick_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_status (ctx : (_, _) context) : tool_result =
  (true, Yojson.Safe.to_string (Command_plane_v2.policy_status_json ctx.config))

let handle_policy_approve (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.policy_approve_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_deny (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.policy_deny_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_update (ctx : (_, _) context) args : tool_result =
  json_result (Command_plane_v2.policy_update_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_freeze_unit (ctx : (_, _) context) args : tool_result =
  json_result
    (Command_plane_v2.policy_freeze_unit_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_kill_switch (ctx : (_, _) context) args : tool_result =
  json_result
    (Command_plane_v2.policy_kill_switch_json ctx.config ~actor:ctx.agent_name args)
