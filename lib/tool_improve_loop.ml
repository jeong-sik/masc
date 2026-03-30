(** Tool_improve_loop — keeper-first self-improvement loop substrate for
    masc-mcp.

    The loop persists selection state locally, ranks GitHub PRs/issues, and
    prepares or executes the next burn-down action in a dedicated worktree.
    It intentionally keeps the action plan explicit so a keeper can
    inspect and drive the lane using normal MASC tools. *)

open Tool_args

(* Re-export types and helpers from sub-modules *)
include Tool_improve_loop_types
include Tool_improve_loop_gh
include Tool_improve_loop_planner
include Tool_improve_loop_executor

let schemas = Tool_improve_loop_schemas.schemas

let resolve_selected_candidate state queue =
  match state.current_candidate with
  | Some current ->
      option_or_else
        (List.find_opt
           (fun candidate -> String.equal (candidate_id candidate) (candidate_id current))
           queue)
        (fun () -> list_hd_opt queue)
  | None -> list_hd_opt queue

let tick_with_driver (driver : driver) (ctx : _ context) args : result =
  let state = load_state ctx.config in
  let limit = max 1 (get_int args "limit" 10) in
  let review_ok = get_bool args "review_ok" false in
  if not state.enabled || state.status = Disabled then
    (true, Yojson.Safe.pretty_to_string (state_status_json state))
  else if state.status = Paused then
    (true, Yojson.Safe.pretty_to_string (state_status_json state))
  else
    let now = driver.now () in
    match driver.list_prs ~repo:state.repo, driver.list_issues ~repo:state.repo with
    | Error pr_error, _ ->
        let updated = mark_failure state ~now ("gh pr list failed: " ^ pr_error) in
        save_state ctx.config updated;
        append_event ctx.config "tick_failure"
          (`Assoc [ ("reason", `String pr_error) ]);
        (false, Yojson.Safe.pretty_to_string (state_status_json updated))
    | _, Error issue_error ->
        let updated = mark_failure state ~now ("gh issue list failed: " ^ issue_error) in
        save_state ctx.config updated;
        append_event ctx.config "tick_failure"
          (`Assoc [ ("reason", `String issue_error) ]);
        (false, Yojson.Safe.pretty_to_string (state_status_json updated))
    | Ok prs, Ok issues ->
        let queue = rank_candidates ~review_ok ~prs ~issues () in
        match resolve_selected_candidate state queue with
        | None ->
            let updated =
              {
                (mark_success state ~now ~phase:"idle" "queue_empty") with
                current_candidate = None;
              }
            in
            save_state ctx.config updated;
            append_event ctx.config "tick_idle"
              (`Assoc [ ("repo", `String state.repo) ]);
            (true, Yojson.Safe.pretty_to_string (state_status_json ~queue:(queue, limit) updated))
        | Some candidate ->
            let repo_root = repo_root ctx.config in
            let planned_state =
              {
                state with
                current_candidate = Some candidate;
                current_phase = Some (candidate_kind_to_string candidate.kind);
                updated_at = now;
              }
            in
            let plan = plan_for_candidate repo_root planned_state ~review_ok candidate in
            let execute = get_bool args "execute" (not state.dry_run) in
            if not execute || state.dry_run then begin
              save_state ctx.config planned_state;
              append_event ctx.config "tick_planned"
                (`Assoc
                  [
                    ("candidate", candidate_to_json candidate);
                    ("plan", action_plan_to_json plan);
                  ]);
              (true,
               Yojson.Safe.pretty_to_string
                 (state_status_json ~plan ~queue:(queue, limit) planned_state))
            end else
              match execute_plan driver repo_root ctx planned_state plan with
              | Ok exec_json ->
                  let updated =
                    mark_success planned_state ~now ~phase:plan.phase
                      (Printf.sprintf "executed %s" plan.action_id)
                      ?merged_pr:
                        (if plan.phase = "merge_ready" then Some candidate.number else None)
                  in
                  save_state ctx.config updated;
                  append_event ctx.config "tick_executed"
                    (`Assoc
                      [
                        ("candidate", candidate_to_json candidate);
                        ("plan", action_plan_to_json plan);
                        ("execution", exec_json);
                      ]);
                  let json =
                    match state_status_json ~plan ~queue:(queue, limit) updated with
                    | `Assoc fields -> `Assoc (("execution", exec_json) :: fields)
                    | other -> other
                  in
                  (true, Yojson.Safe.pretty_to_string json)
              | Error message ->
                  let updated = mark_failure planned_state ~now message in
                  save_state ctx.config updated;
                  append_event ctx.config "tick_failure"
                    (`Assoc
                      [
                        ("candidate", candidate_to_json candidate);
                        ("plan", action_plan_to_json plan);
                        ("reason", `String message);
                      ]);
                  let json =
                    match state_status_json ~plan ~queue:(queue, limit) updated with
                    | `Assoc fields -> `Assoc (("execution_error", `String message) :: fields)
                    | other -> other
                  in
                  (false, Yojson.Safe.pretty_to_string json)

let handle_start (ctx : _ context) args =
  let current = load_state ctx.config in
  let now = Time_compat.now () in
  let state =
    {
      current with
      enabled = true;
      status = Running;
      keeper_name = get_string args "keeper_name" current.keeper_name;
      poll_interval_sec = max 30 (get_int args "poll_interval_sec" current.poll_interval_sec);
      repo = get_string args "repo" current.repo;
      repo_scope = default_repo_scope;
      merge_policy = default_merge_policy;
      dry_run = get_bool args "dry_run" current.dry_run;
      paused_reason = None;
      updated_at = now;
    }
  in
  save_state ctx.config state;
  append_event ctx.config "loop_started"
    (`Assoc
      [
        ("agent_name", `String ctx.agent_name);
        ("state", state_to_json state);
      ]);
  (true, Yojson.Safe.pretty_to_string (state_status_json state))

let handle_status (ctx : _ context) _args =
  let state = load_state ctx.config in
  (true, Yojson.Safe.pretty_to_string (state_status_json state))

let handle_pause (ctx : _ context) args =
  let current = load_state ctx.config in
  let state =
    {
      current with
      enabled = true;
      status = Paused;
      paused_reason = Some (get_string args "reason" "manual_pause");
      updated_at = Time_compat.now ();
    }
  in
  save_state ctx.config state;
  append_event ctx.config "loop_paused"
    (`Assoc
      [
        ("agent_name", `String ctx.agent_name);
        ("reason", Option.fold ~none:`Null ~some:(fun value -> `String value) state.paused_reason);
      ]);
  (true, Yojson.Safe.pretty_to_string (state_status_json state))

let handle_resume (ctx : _ context) args =
  let current = load_state ctx.config in
  let state =
    {
      current with
      enabled = true;
      status = Running;
      dry_run = get_bool args "dry_run" current.dry_run;
      paused_reason = None;
      updated_at = Time_compat.now ();
    }
  in
  save_state ctx.config state;
  append_event ctx.config "loop_resumed"
    (`Assoc [ ("agent_name", `String ctx.agent_name); ("state", state_to_json state) ]);
  (true, Yojson.Safe.pretty_to_string (state_status_json state))

let maybe_tick_from_keepalive ~(config : Room.config) ~(agent_name : string)
    ~(keeper_name : string) ~(sw : Eio.Switch.t)
    ~(clock : _ Eio.Time.clock)
    ~(proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option) () =
  let state = load_state config in
  let now = Time_compat.now () in
  if state.enabled && state.status = Running
     && String.equal state.keeper_name keeper_name
     && tick_due state ~now
  then
    let ctx = { config; agent_name; sw = Some sw; clock = Some clock; proc_mgr; net } in
    let _ok, _body =
      tick_with_driver default_driver ctx
        (`Assoc [ ("execute", `Bool true) ])
    in
    ()
  else
    ()

let dispatch (ctx : _ context) ~name ~args : result option =
  match name with
  | "masc_improve_loop_start" -> Some (handle_start ctx args)
  | "masc_improve_loop_status" -> Some (handle_status ctx args)
  | "masc_improve_loop_pause" -> Some (handle_pause ctx args)
  | "masc_improve_loop_resume" -> Some (handle_resume ctx args)
  | "masc_improve_loop_tick" -> Some (tick_with_driver default_driver ctx args)
  | _ -> None
