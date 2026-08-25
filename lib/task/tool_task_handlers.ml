module Workspace = Workspace_core

(** Tool_task - Core task CRUD operations

    Handles: add_task, batch_add_tasks, cancel_task, claim, claim_next,
    done, release, task_history, tasks, transition, update_priority, archive_view
*)

(* Yojson.Safe.Util removed — use Json_util SSOT helpers instead *)

let push_event_to_sessions_fn
  : (Yojson.Safe.t -> unit) Atomic.t
  = Atomic.make (fun _ -> ())





type context = {
  config: Workspace.config;
  agent_name: string;
  sw: Eio.Switch.t option;
}

type task_owner_hooks =
  { is_keeper_agent_identity : Workspace.config -> agent_name:string -> bool
  ; sync_current_task_binding : Workspace.config -> agent_name:string -> unit
  }

let default_task_owner_hooks =
  { is_keeper_agent_identity = (fun _ ~agent_name:_ -> false)
  ; sync_current_task_binding = (fun _ ~agent_name:_ -> ())
  }
;;

let task_owner_hooks = Atomic.make default_task_owner_hooks
let set_task_owner_hooks hooks = Atomic.set task_owner_hooks hooks
let current_task_owner_hooks () = Atomic.get task_owner_hooks

open Tool_args

let task_log_warn ~task_id fmt =
  Stdlib.Format.ksprintf
    (fun message -> Log.Task.warn "task_id=%s %s" task_id message)
    fmt

let task_agent_log_warn ~agent_name fmt =
  Stdlib.Format.ksprintf
    (fun message -> Log.Task.warn "agent_name=%s %s" agent_name message)
    fmt

let task_agent_log_error ~agent_name fmt =
  Stdlib.Format.ksprintf
    (fun message -> Log.Task.error "agent_name=%s %s" agent_name message)
    fmt

(* RFC-0189: [Masc_domain] backend Error variants (Task_error /
   Agent_error / etc.) currently surface as caller-actionable
   workflow violations ("task not found", "invalid transition",
   "agent not in workspace") rather than transient/runtime failures.
   Tag [Workflow_rejection] uniformly at the helper boundary —
   when [Masc_domain] grows typed per-variant failure_class
   assignment, this tag becomes per-call-site. *)
let result_to_response ~tool_name ~start_time = function
  | Ok msg -> Tool_result.ok ~tool_name ~start_time msg
  | Error e ->
      Tool_result.error
        ~failure_class:Tool_result.Workflow_rejection
        ~tool_name ~start_time
        (Masc_domain.masc_error_to_string e)

let log_task_transition_failed ~agent_name err =
  let message = Masc_domain.masc_error_to_string err in
  match err with
  | Masc_domain.Task (Masc_domain.Task_error.InvalidState _) ->
      task_agent_log_warn ~agent_name "task transition failed: %s" message
  | _ -> task_agent_log_error ~agent_name "task transition failed: %s" message

include Tool_task_payloads

let sync_planning_current_task_with_owned_task (ctx : context) =
  if
    (current_task_owner_hooks ()).is_keeper_agent_identity
      ctx.config
      ~agent_name:ctx.agent_name
  then ()
  else
    let owned_task =
      Workspace.get_tasks_raw ctx.config
      |> List.find_map (fun (task : Masc_domain.task) ->
             match task.task_status with
             | Masc_domain.Claimed { assignee; _ }
             | Masc_domain.InProgress { assignee; _ } ->
                 if String.equal assignee ctx.agent_name then Some task.id else None
             | Masc_domain.Todo
             | Masc_domain.AwaitingVerification _
             | Masc_domain.Done _
             | Masc_domain.Cancelled _ -> None)
    in
    match owned_task with
    | Some task_id ->
        (match Planning_eio.set_current_task ctx.config ~task_id with
         | Ok () -> ()
         | Error msg ->
             task_log_warn ~task_id
               "failed to sync planning current_task to %s: %s"
               task_id msg)
    | None -> Planning_eio.clear_current_task ctx.config

let sync_owner_current_task_binding (ctx : context) =
  (current_task_owner_hooks ()).sync_current_task_binding
    ctx.config
    ~agent_name:ctx.agent_name

include Tool_task_completion_review

include Tool_task_args

include Tool_task_contract_gate

(* Handlers *)

let parse_task_skills args =
  match Json_util.assoc_member_opt "skills" args with
  | None -> Ok []
  | Some (`List values) ->
    let rec collect acc index = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> collect (value :: acc) (index + 1) rest
      | value :: _ ->
        Error
          (Printf.sprintf
             "skills[%d] must be a string (received %s)"
             index
             (Json_util.kind_name value))
    in
    collect [] 0 values
  | Some value ->
    Error
      (Printf.sprintf
         "skills must be an array of strings (received %s)"
         (Json_util.kind_name value))
;;

let handle_add_task ?created_by ~tool_name ~start_time ctx args =
  let valid_keys =
    [ "title"
    ; "priority"
    ; "description"
    ; "goal_id"
    ; "contract"
    ; "predecessor_task_id"
    ; "skills"
    ]
  in
  let unknown = unknown_args ~valid_keys args in
  if Stdlib.List.length unknown > 0 then
    (* RFC-0189: schema rejection — operator passed unknown
       argument names. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      (Printf.sprintf
        "Unknown argument(s): %s. Valid: %s"
        (String.concat ", " unknown)
        (String.concat ", " valid_keys))
  else
  let title = get_string args "title" "" in
  let priority = get_int args "priority" 3 in
  let description = get_string args "description" "" in
  let goal_id =
    match Safe_ops.json_string_opt "goal_id" args with
    | Some s when not (String.equal (String.trim s) "") -> Some (String.trim s)
    | _ -> None
  in
  (* RFC-0323 W2: existence + terminal validation happens in
     [Workspace.add_task_with_result] inside the backlog lock (typed
     [Unknown_predecessor] / [Predecessor_not_terminal] errors). *)
  let predecessor_task_id =
    match Safe_ops.json_string_opt "predecessor_task_id" args with
    | Some s when not (String.equal (String.trim s) "") -> Some (String.trim s)
    | _ -> None
  in
  (* Skill directory names under <base-path>/.masc/skills/. The authoring
     contract below rejects blank or non-segment values; silently dropping one
     would make a malformed declaration look as if it had been accepted. *)
  let skills_result = parse_task_skills args in
  let contract_result = parse_task_contract args in
  (* BUG-009/010: Validate title and priority *)
  let trimmed_title = String.trim title in
  (* RFC-0189: title/priority/goal_id/contract validation — all
     caller-input violations. [Workflow_rejection]. *)
  if String.equal trimmed_title "" then
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      "Task title cannot be empty or whitespace-only"
  else if priority < 1 || priority > 5 then
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      (Printf.sprintf "Priority must be between 1 and 5, got %d" priority)
  else if Option.is_some goal_id
          && not
               (* DET-OK: [Option.value ~default:""] is guarded by
                  the [Option.is_some goal_id] guard above; the
                  empty default is unreachable.  Refactoring to a
                  match would split the boolean chain awkwardly. *)
               (Goal_store.list_goals ctx.config ()
                |> List.exists (fun (goal : Goal_store.goal) ->
                       String.equal goal.id (Option.value ~default:"" goal_id)))
  then
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      (* DET-OK: same guarded branch — goal_id is [Some _]. *)
      (Printf.sprintf "Unknown goal_id '%s'" (Option.value ~default:"" goal_id))
  else
    match contract_result, skills_result with
    | Error error, _ | _, Error error ->
        Tool_result.error
          ~failure_class:Tool_result.Workflow_rejection
          ~tool_name ~start_time error
    | Ok contract, Ok skills ->
        (match
           Task_skill_reference.validate_all
             ~base_path:ctx.config.base_path
             skills
         with
         | Error error ->
           Tool_result.error
             ~failure_class:Tool_result.Workflow_rejection
             ~tool_name
             ~start_time
             error
         | Ok () ->
        let add_result =
          let created_by =
            match created_by with
            | Some author -> author
            | None -> ctx.agent_name
          in
          Workspace.add_task_with_result ?contract
            ?goal_id
            ?predecessor_task_id
            ~skills
            ~created_by ctx.config ~title:trimmed_title
            ~priority ~description
        in
        (match add_result with
         | Ok created ->
           Tool_result.make_ok
             ~tool_name
             ~start_time
             ~data:
               (`Assoc
                  [ "ok", `Bool true
                  ; "task_id", `String created.task_id
                  ; "summary", `String created.summary
                  ; "title", `String trimmed_title
                  ; "priority", `Int priority
                  ; "description", `String description
                  ; "goal_id", Json_util.string_opt_to_json goal_id
                  ; ( "predecessor_task_id"
                    , Json_util.string_opt_to_json predecessor_task_id )
                  ])
             ()
         | Error err ->
           Tool_result.error
             ~failure_class:Tool_result.Workflow_rejection
             ~tool_name
             ~start_time
             (Workspace.add_task_error_to_string err)))

(* RFC-0267 Phase 2: assign an existing goalless task to a goal. Thin adapter
   over [Task_goal_assignment.set_task_goal] — the single validated backend
   shared with the dashboard HTTP route, so neither surface re-implements the
   precondition checks. All caller-input violations are [Workflow_rejection]. *)
let handle_set_goal ~tool_name ~start_time ctx args =
  let valid_keys = [ "task_id"; "goal_id" ] in
  let unknown = unknown_args ~valid_keys args in
  if Stdlib.List.length unknown > 0 then
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      (Printf.sprintf "Unknown argument(s): %s. Valid: %s"
        (String.concat ", " unknown)
        (String.concat ", " valid_keys))
  else
    let task_id = String.trim (get_string args "task_id" "") in
    let goal_id = String.trim (get_string args "goal_id" "") in
    if String.equal task_id "" then
      Tool_result.error
        ~failure_class:Tool_result.Workflow_rejection
        ~tool_name ~start_time
        "task_id is required and cannot be empty"
    else if String.equal goal_id "" then
      Tool_result.error
        ~failure_class:Tool_result.Workflow_rejection
        ~tool_name ~start_time
        "goal_id is required and cannot be empty"
    else (
      match Task_goal_assignment.set_task_goal ctx.config ~task_id ~goal_id with
      | Ok () ->
        Tool_result.make_ok
          ~tool_name
          ~start_time
          ~data:
            (`Assoc
               [ ("ok", `Bool true)
               ; ("task_id", `String task_id)
               ; ("goal_id", `String goal_id)
               ])
          ()
      | Error err ->
        Tool_result.error
          ~failure_class:Tool_result.Workflow_rejection
          ~tool_name ~start_time
          (Task_goal_assignment.set_task_goal_error_to_string err))

let handle_batch_add_tasks ?created_by ~tool_name ~start_time ctx args =
  let valid_item_keys = [ "title"; "priority"; "description"; "goal_id"; "contract" ] in
  let tasks_json = match Json_util.assoc_member_opt "tasks" args with
    | Some (`List l) -> l
    | _ -> []
  in
  if Stdlib.List.length tasks_json = 0 then
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      "tasks array is empty or missing"
  else
  let validated = List.mapi (fun idx t ->
    let title = String.trim (Json_util.get_string t "title" |> Option.value ~default:"") in
    let priority = Json_util.get_int t "priority" |> Option.value ~default:3 in
    let description = Json_util.get_string t "description" |> Option.value ~default:"" in
    let goal_id =
      match Json_util.get_string t "goal_id" with
      | Some s when not (String.equal (String.trim s) "") -> Some (String.trim s)
      | _ -> None
    in
    let contract =
      match Json_util.assoc_member_opt "contract" t with
      | None | Some `Null -> Ok None
      | Some json ->
        parse_task_contract_object json
        |> Result.map Option.some
        |> Result.map_error (fun error ->
          Printf.sprintf "item[%d]: invalid contract payload: %s" idx error)
    in
    if String.equal title "" then
      Error (Printf.sprintf "item[%d]: title cannot be empty" idx)
    else if priority < 1 || priority > 5 then
      Error (Printf.sprintf "item[%d]: priority must be 1-5, got %d" idx priority)
    else
      match contract with
      | Ok contract ->
          let has_removed_field name =
            match Json_util.assoc_member_opt name t with
            | None | Some `Null -> false
            | Some _ -> true
          in
          let unknown = unknown_args ~valid_keys:valid_item_keys t in
          if has_removed_field "required_role" then
            Error (Printf.sprintf "item[%d]: required_role is no longer supported" idx)
          else if has_removed_field "required_verifier_role" then
            Error
              (Printf.sprintf "item[%d]: required_verifier_role is no longer supported" idx)
          else if Stdlib.List.length unknown > 0 then
            Error
              (Printf.sprintf "item[%d]: Unknown argument(s): %s. Valid: %s" idx
                 (String.concat ", " unknown)
                 (String.concat ", " valid_item_keys))
          else
            Ok (title, priority, description, contract, goal_id)
      | Error error -> Error error
  ) tasks_json in
  let errors = List.filter_map (function Error e -> Some e | Ok _ -> None) validated in
  if Stdlib.List.length errors > 0 then
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      (Printf.sprintf "Validation failed:\n%s" (String.concat "\n" errors))
  else
    let tasks =
      List.filter_map (function Ok t -> Some t | Error _ -> None) validated
    in
    let batch_result =
      let created_by =
        match created_by with
        | Some author -> author
        | None -> ctx.agent_name
      in
      Workspace.batch_add_tasks_with_contracts_result
        ~created_by ctx.config tasks
    in
    (match batch_result with
     | Ok created ->
       Tool_result.make_ok
         ~tool_name
         ~start_time
         ~data:
           (`Assoc
              [ "ok", `Bool true
              ; "task_ids", `List (List.map (fun task_id -> `String task_id) created.task_ids)
              ; "summary", `String created.summary
              ; "count", `Int created.count
              ])
         ()
     | Error err ->
       Tool_result.error
         ~failure_class:Tool_result.Workflow_rejection
         ~tool_name
         ~start_time
         (Workspace.batch_add_tasks_error_to_string err))

let handle_claim ~tool_name ~start_time ctx args =
  (* #18965 — removed [is_agent_session_bound] hard gate.  Agent-internal tag
     dispatch path bypasses MCP entry session binding, so this gate produced
     false-negative rejects for every agent turn (fleet evidence:
     <base-path>/.masc/agents/ empty while agents run normally; only
     masc_claim/keeper_task_claim failed).  Workspace.claim_task_r works on
     agent_name alone; gate added no real authorization. *)
  if Option.is_some (Json_util.assoc_member_opt "agent_role" args) then
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      "agent_role is no longer supported"
  else
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response ~tool_name ~start_time (Error e)
  | Ok task_id ->
  let result =
    Workspace.claim_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ()
  in
  (match result with
   | Ok _ ->
       sync_owner_current_task_binding ctx;
       sync_planning_current_task_with_owned_task ctx;
        (Atomic.get push_event_to_sessions_fn) (`Assoc [
          ("type", `String "masc/task_claimed");
          ("task_id", `String task_id);
          ("agent_name", `String ctx.agent_name);
          ("timestamp", `Float (Time_compat.now ()));
        ])
   | Error e -> task_log_warn ~task_id "task claim failed for %s: %s" task_id (Masc_domain.masc_error_to_string e));
  result_to_response ~tool_name ~start_time result

let no_eligible_diagnostics_json =
  Tool_task_no_eligible.no_eligible_diagnostics_json
let no_eligible_exclusion_summary =
  Tool_task_no_eligible.no_eligible_exclusion_summary

let format_no_eligible ctx ~excluded_count ~scope_excluded_count =
  ignore ctx;
  Printf.sprintf
    "No eligible tasks available (blocked/excluded: %d). %s"
    excluded_count
    (no_eligible_exclusion_summary ~scope_excluded_count)

let handle_claim_next ~tool_name ~start_time ctx _args =
  (* #18965 — removed [is_agent_session_bound] hard gate (same rationale as
     [handle_claim] above).  Workspace.claim_next_r operates on
     [~agent_name] alone; backlog read does not require an entry under
     agents_dir. *)
  let result = Workspace.claim_next_r ctx.config ~agent_name:ctx.agent_name () in
  match result with
  | Workspace.Claim_next_claimed { message; task_id; scope_widened; _ } ->
    sync_owner_current_task_binding ctx;
    sync_planning_current_task_with_owned_task ctx;
    append_claim_observation message ~now:(Time_compat.now ())
      ~agent_name:ctx.agent_name ~task_id ~scope_widened
    |> Tool_result.ok ~tool_name ~start_time
  | Workspace.Claim_next_no_unclaimed ->
    Tool_result.ok ~tool_name ~start_time "No unclaimed tasks available"
  | Workspace.Claim_next_no_eligible
      { excluded_count
      ; scope_excluded_count
      ; explicit_excluded_count
      ; claim_pool_candidate_count
      } ->
    let message =
      format_no_eligible
        ctx
        ~excluded_count
        ~scope_excluded_count
    in
    let diagnostics =
      no_eligible_diagnostics_json
        ~excluded_count
        ~scope_excluded_count
        ~explicit_excluded_count
        ~claim_pool_candidate_count
    in
    (* Build the structured payload directly so message and diagnostics
       remain first-class typed fields. *)
    let data =
      `Assoc [ "message", `String message; "diagnostics", diagnostics ]
    in
    Tool_result.make_ok ~tool_name ~start_time ~data ()
  | Workspace.Claim_next_error e ->
    (* RFC-0189: Claim_next_error wraps workspace-side reasons like
       "no claimable task", "agent not allowed", "permission denied"
       — all caller-actionable. [Workflow_rejection]. *)
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name ~start_time
      (Printf.sprintf "Error: %s" e)
