(** Operator_approval — OAS Approval pipeline for operator action confirmation.

    Centralizes the confirm_required logic (previously duplicated in 3 files)
    into a single OAS Approval pipeline with typed risk levels.

    @since OAS integration Phase F *)

let high_risk_actions =
  [ "namespace_pause"; "room_pause"; "team_stop"; "team_task_inject";
    "team_worker_spawn_batch"; "keeper_github_identity_login_prepare" ]

let allowed_actions =
  [ "broadcast"; "namespace_pause"; "room_pause"; "namespace_resume"; "room_resume"; "social_sweep";
    "autonomy_tick";
    "team_note"; "team_broadcast"; "team_task_inject";
    "team_worker_spawn_batch"; "team_stop";
    "keeper_message"; "keeper_probe"; "keeper_recover";
    "keeper_github_identity_login_prepare"; "keeper_github_identity_status";
    "task_inject" ]

let risk_of_action action_type : Oas.Approval.risk_level =
  if List.mem action_type high_risk_actions then High
  else if List.mem action_type allowed_actions then Low
  else Medium

let is_allowed action_type =
  List.mem action_type allowed_actions

let confirm_required action_type =
  List.mem action_type high_risk_actions

let pipeline : Oas.Approval.t =
  Oas.Approval.create [
    Oas.Approval.auto_approve_known_tools
      (List.filter (fun a -> not (List.mem a high_risk_actions)) allowed_actions);
    { Oas.Approval.name = "high_risk_gate";
      evaluate = (fun ctx ->
        if List.mem ctx.tool_name high_risk_actions then
          Decided (Oas.Hooks.Reject "requires operator confirmation")
        else Pass);
      timeout_s = None;
    };
  ]

let evaluate_action ~action_type ~agent_name ~turn =
  Oas.Approval.evaluate pipeline
    ~tool_name:action_type
    ~input:(`Assoc [])
    ~agent_name
    ~turn
