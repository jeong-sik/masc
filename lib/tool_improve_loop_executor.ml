(** Tool_improve_loop_executor — plan execution (team session + merge). *)

open Tool_improve_loop_types

let team_session_goal_of_plan (state : state) (plan : action_plan) =
  let candidate = plan.candidate in
  let candidate_ref =
    match candidate.kind with
    | Conflict_pr | Failing_pr | Merge_ready_pr ->
        Printf.sprintf "PR #%d" candidate.number
    | Priority_issue | Backlog_issue ->
        Printf.sprintf "Issue #%d" candidate.number
  in
  let header =
    Printf.sprintf
      "Improve-loop lane for %s in repo %s.\nTitle: %s\nPhase: %s"
      candidate_ref state.repo candidate.title plan.phase
  in
  let worktree_hint =
    match plan.worktree_path, plan.branch_name with
    | Some worktree_path, Some branch_name ->
        Printf.sprintf
          "\nPreferred worktree path: %s\nPreferred branch: %s"
          worktree_path branch_name
    | _ -> ""
  in
  let commands =
    if plan.commands = [] then
      ""
    else
      "\nPlanned commands:\n"
      ^ String.concat "\n" (List.map (fun line -> "- " ^ line) plan.commands)
  in
  let notes =
    if plan.notes = [] then
      ""
    else
      "\nConstraints:\n"
      ^ String.concat "\n" (List.map (fun line -> "- " ^ line) plan.notes)
  in
  String.concat "\n"
    [
      header ^ worktree_hint;
      "Required workflow:";
      "- reproduce or inspect the candidate first";
      "- use worktree-first changes";
      "- patch narrowly";
      "- run targeted verification";
      "- open or update a draft PR only after local verification";
      "- do not merge without cross-model review and green required checks";
      commands;
      notes;
    ]

let execute_team_session_plan (ctx : _ context) (state : state) (plan : action_plan) =
  match ctx.sw, ctx.clock with
  | Some sw, Some clock ->
      let team_ctx : _ Tool_team_session.context =
        {
          Tool_team_session.config = ctx.config;
          agent_name = ctx.agent_name;
          sw;
          clock;
          proc_mgr = ctx.proc_mgr;
          net = ctx.net;
        }
      in
      let args =
        `Assoc
          [
            ("goal", `String (team_session_goal_of_plan state plan));
            ("duration_seconds", `Int 1800);
            ("checkpoint_interval_sec", `Int 120);
            ("min_agents", `Int 2);
            ("execution_scope", `String "limited_code_change");
            ("orchestration_mode", `String "assist");
            ("communication_mode", `String "broadcast");
            ("instruction_profile", `String "standard");
            ("alert_channel", `String "both");
          ]
      in
      (match Tool_team_session.dispatch team_ctx ~name:"masc_team_session_start" ~args with
       | Some (true, body) -> (
           try
             let json = Yojson.Safe.from_string body in
             Ok
               (`Assoc
                 [
                   ("mode", `String "team_session_started");
                   ("plan", action_plan_to_json plan);
                   ("session", json);
                 ])
           with Yojson.Json_error _ ->
             Ok
               (`Assoc
                 [
                   ("mode", `String "team_session_started");
                   ("plan", action_plan_to_json plan);
                   ("session_raw", `String body);
                 ]))
       | Some (false, message) ->
           Error ("team session start failed: " ^ message)
       | None ->
           Error "team session dispatch unavailable")
  | _ ->
      Error "team session runtime unavailable for improve-loop execute path"

let execute_merge_plan driver (state : state) (plan : action_plan) =
  match plan.merge_command with
  | None -> Error "merge plan missing merge command"
  | Some _ ->
      let argv =
        [
          "gh";
          "pr";
          "merge";
          string_of_int plan.candidate.number;
          "--repo";
          state.repo;
          Printf.sprintf "--%s" state.merge_policy;
          "--delete-branch";
        ]
      in
      let result = run_and_capture driver argv in
      if command_ok result then
        Ok
          (`Assoc
            [
              ("mode", `String "executed");
              ("merged_pr", `Int plan.candidate.number);
            ])
      else
        Error ("gh pr merge failed: " ^ String.trim result.stderr)

let execute_plan driver (_repo_root : string) (ctx : _ context) state
    (plan : action_plan) =
  match plan.phase with
  | "issue_burn_down" | "pr_failing_checks" | "pr_conflict" ->
      execute_team_session_plan ctx state plan
  | "merge_ready" ->
      let plan =
        { plan with merge_command = Tool_improve_loop_planner.merge_command_if_ready state ~review_ok:true plan.candidate }
      in
      execute_merge_plan driver state plan
  | _ -> Error ("unknown phase: " ^ plan.phase)
