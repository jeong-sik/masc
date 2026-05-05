open Keeper_types
open Keeper_exec_shared

let keeper_task_result_json = function
  | Ok msg -> Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "result", `String msg ])
  | Error e ->
    Yojson.Safe.to_string
      (`Assoc [ "ok", `Bool false; "error", `String (Masc_domain.masc_error_to_string e) ])
;;

let keeper_tool_result_json ~(ok : bool) ~(message : string) =
  Yojson.Safe.to_string
    (`Assoc
       [
         "ok", `Bool ok;
         ((if ok then "result" else "error"), `String message);
       ])
;;

let validate_goal_id config goal_id =
  match Goal_store.get_goal config ~goal_id with
  | Some _ -> Ok goal_id
  | None -> Error (Printf.sprintf "unknown goal_id: %s" goal_id)
;;

let resolve_task_create_goal_id ~config ~(meta : keeper_meta) args =
  match Safe_ops.json_string_opt "goal_id" args with
  | Some s when String.trim s <> "" ->
      validate_goal_id config (String.trim s) |> Result.map Option.some
  | _ ->
      (match meta.active_goal_ids with
       | [] -> Ok None
       | [ goal_id ] ->
           validate_goal_id config goal_id |> Result.map Option.some
       | goal_ids ->
           Error
             (Printf.sprintf
                "goal_id is required when keeper has multiple active_goal_ids: [%s]"
                (String.concat ", " goal_ids)))
;;

let parse_task_contract_arg args =
  match Yojson.Safe.Util.member "contract" args with
  | `Null -> Ok None
  | (`Assoc _ as json) -> (
      match Masc_domain.task_contract_of_yojson json with
      | Ok contract -> Ok (Some contract)
      | Error message ->
          Error (Printf.sprintf "Invalid contract payload: %s" message))
  | _ -> Error "contract must be an object when provided"
;;

let active_goal_scope_json ~(meta : keeper_meta) ?matched_goal_id
    ?excluded_count ?effective_mode ?effective_goal_ids ?fallback_reason () =
  let scoped = meta.active_goal_ids <> [] in
  let mode =
    match effective_mode with
    | Some mode -> mode
    | None -> if scoped then "active_goal_ids" else "all_tasks"
  in
  let effective_goal_ids =
    match effective_goal_ids with
    | Some goal_ids -> goal_ids
    | None -> meta.active_goal_ids
  in
  let fields =
    [
      ("mode", `String mode);
      ("scoped", `Bool scoped);
      ( "active_goal_ids",
        `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids)
      );
      ( "effective_goal_ids",
        `List (List.map (fun goal_id -> `String goal_id) effective_goal_ids)
      );
      ("fallback_reason", Json_util.string_opt_to_json fallback_reason);
      ("matched_goal_id", Json_util.string_opt_to_json matched_goal_id);
    ]
  in
  let fields =
    match excluded_count with
    | Some count -> fields @ [ ("excluded_count", `Int count) ]
    | None -> fields
  in
  `Assoc fields
;;

let find_task_goal_id config task_id =
  Coord.get_tasks_raw config
  |> List.find_map (fun (task : Masc_domain.task) ->
         if String.equal task.id task_id then task.goal_id else None)
;;

let merge_current_task_id ~(latest : keeper_meta) ~(caller : keeper_meta) =
  {
    latest with
    current_task_id = caller.current_task_id;
    updated_at = caller.updated_at;
  }
;;

let sync_keeper_meta_current_task
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(task_id : string)
  =
  match Keeper_id.Task_id.of_string task_id with
  | Error msg ->
    Log.Keeper.warn
      "keeper:%s could not sync claimed task %s into current_task_id: %s"
      meta.name task_id msg
  | Ok current_task_id ->
    let updated_meta =
      { meta with current_task_id = Some current_task_id; updated_at = now_iso () }
    in
    Keeper_registry.update_meta ~base_path:config.base_path meta.name updated_meta;
    (match
       write_meta_with_merge ~merge:merge_current_task_id config updated_meta
     with
     | Ok () -> ()
     | Error msg ->
       Prometheus.inc_counter
         Prometheus.metric_keeper_write_meta_failures
         ~labels:[("keeper", meta.name); ("phase", "claim_task_id")]
         ();
       Log.Keeper.warn
         "keeper:%s failed to persist claimed current_task_id=%s: %s"
         meta.name task_id msg)
;;

let handle_keeper_task_tool
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match name with
  | "keeper_tasks_list" ->
    let status_filter = Safe_ops.json_string_opt "status" args in
    let include_done = Safe_ops.json_bool ~default:false "include_done" args in
    let limit = Safe_ops.json_int ~default:50 "limit" args |> max 1 |> min 100 in
    let result = Coord.list_tasks ?status:status_filter ~include_done config in
    (match Yojson.Safe.from_string result with
     | `List items ->
       Yojson.Safe.to_string (`List (List.filteri (fun i _ -> i < limit) items))
     | _ -> result
     | exception Yojson.Json_error _ ->
       let lines = String.split_on_char '\n' result in
       String.concat "\n" (List.filteri (fun i _ -> i < limit + 2) lines))
  | "keeper_tasks_audit" ->
    let limit = Safe_ops.json_int ~default:20 "limit" args |> max 1 |> min 50 in
    let orphans = Coord.audit_orphan_tasks config in
    let orphans = List.filteri (fun i _ -> i < limit) orphans in
    let items =
      List.map
        (fun (task, assignee) ->
           let task : Masc_domain.task = task in
           `Assoc
             [ "task_id", `String task.id
             ; "title", `String task.title
             ; "assignee", `String assignee
             ; "status", `String (Masc_domain.string_of_task_status task.task_status)
             ])
        orphans
    in
    let action_hint =
      if orphans = [] then
        "ACTION: STOP calling keeper_tasks_audit — no orphans found. Move on to other work or end your turn."
      else
        Printf.sprintf "ACTION: %d orphan(s) found. Use keeper_task_force_release or keeper_task_force_done to resolve, then STOP re-auditing."
          (List.length orphans)
    in
    Yojson.Safe.to_string
      (`Assoc [ "orphan_count", `Int (List.length orphans); "orphans", `List items;
                "action", `String action_hint ])
  | "keeper_task_force_release" ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let reason = Safe_ops.json_string ~default:"" "reason" args in
    if task_id = ""
    then error_json "task_id is required. Use the task_id from keeper_tasks_list or keeper_tasks_audit."
    else (
      let agent = keeper_agent_sender ~meta in
      let _ =
        Coord.broadcast
          config
          ~from_agent:agent
          ~content:
            (Printf.sprintf
               "Force-releasing task %s (reason: %s)"
               task_id
               (if reason = "" then "no reason given" else reason))
      in
      keeper_task_result_json
        (Coord.force_release_task_r config ~agent_name:agent ~task_id ()))
  | "keeper_task_force_done" ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let notes = Safe_ops.json_string ~default:"" "notes" args in
    if task_id = ""
    then error_json "task_id is required. Use the task_id from keeper_tasks_list or keeper_tasks_audit."
    else
      keeper_task_result_json
        (Coord.force_done_task_r
           config
           ~agent_name:(keeper_agent_sender ~meta)
           ~task_id
           ~notes
           ())
  | "keeper_broadcast" ->
    let message = Safe_ops.json_string ~default:"" "message" args |> String.trim in
    if message = ""
    then error_json "message is required. Good: message='Build complete, all tests pass.'."
    else (
      let _ =
        Coord.broadcast config ~from_agent:(keeper_agent_sender ~meta) ~content:message
      in
      Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "broadcast", `String message ]))
  | "keeper_task_create" ->
    let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
    let description = Safe_ops.json_string ~default:"" "description" args |> String.trim in
    let priority = Safe_ops.json_int ~default:3 "priority" args |> max 1 |> min 5 in
    if title = ""
    then error_json "title is required. Provide a clear, actionable task title."
    else if description = ""
    then error_json "description is required. Explain what needs to be done and why."
    else (
      match resolve_task_create_goal_id ~config ~meta args with
      | Error message -> error_json message
      | Ok goal_id ->
          (match parse_task_contract_arg args with
           | Error message -> error_json message
           | Ok contract ->
              let result =
                Coord_task.add_task ?contract ?goal_id config ~title ~priority
                  ~description
              in
              Yojson.Safe.to_string
                (`Assoc
                  [
                    "ok", `Bool true;
                    "result", `String result;
                    "goal_id", Json_util.string_opt_to_json goal_id;
                  ])))
  | "keeper_task_claim" ->
    let agent_tool_names = Keeper_tool_policy.keeper_allowed_tool_names meta in
    let claim_goal_scope =
      Keeper_runtime_contract.resolve_claim_goal_scope
        ~agent_tool_names
        ~config
        ~meta
    in
    let result =
      Coord.claim_next_r config ~agent_name:meta.agent_name ~agent_tool_names
        ~task_filter:claim_goal_scope.task_filter ()
    in
    let auto_started_ok = ref false in
    (match result with
     | Coord.Claim_next_claimed { task_id; _ } ->
       sync_keeper_meta_current_task ~config ~meta ~task_id;
       let ok, _msg =
         Tool_task.handle_transition
           { Tool_task.config; agent_name = keeper_agent_sender ~meta;
             sw = Eio_context.get_switch_opt () }
           (`Assoc ["task_id", `String task_id; "action", `String "start"])
       in
       auto_started_ok := ok
     | Coord.Claim_next_no_unclaimed
     | Coord.Claim_next_no_eligible _
     | Coord.Claim_next_error _ -> ());
    let accountability_warning =
      if
        Keeper_accountability.accountability_risk_is_high config
          ~keeper_name:meta.name ~agent_name:meta.agent_name
      then
        Some
          "Accountability risk is high for this keeper. Prefer manual review or lower-risk routing when equivalent."
      else
        None
    in
    let message =
      match result with
      | Coord.Claim_next_claimed { message; _ } ->
          if !auto_started_ok then message ^ " Task auto-started — begin work now."
          else message
      | Coord.Claim_next_no_unclaimed -> "No unclaimed tasks. ACTION: Stop task-checking — nothing to claim."
      | Coord.Claim_next_no_eligible { excluded_count; _ } ->
        let scope_suffix =
          match meta.active_goal_ids with
          | [] -> ""
          | goal_ids ->
              Printf.sprintf
                " within active_goal_ids=[%s]"
                (String.concat ", " goal_ids)
        in
        Printf.sprintf
          "No eligible tasks%s. ACTION: Stop task-checking — blocked/excluded=%d."
          scope_suffix excluded_count
      | Coord.Claim_next_error e -> Printf.sprintf "Error: %s" e
    in
    let claim_scope, claimed_task_fields =
      match result with
      | Coord.Claim_next_claimed { task_id; title; priority; released_task_id; _ } ->
          let matched_goal_id = find_task_goal_id config task_id in
          ( active_goal_scope_json ~meta ?matched_goal_id
              ~effective_mode:claim_goal_scope.mode
              ~effective_goal_ids:claim_goal_scope.effective_goal_ids
              ?fallback_reason:claim_goal_scope.fallback_reason ()
          , [
              ( "claim_observation",
                Tool_task.build_claim_observation_payload
                  ~now:(Time_compat.now ()) ~agent_name:meta.agent_name
                  ~task_id );
              ( "claimed_task",
                `Assoc
                  [
                    ("task_id", `String task_id);
                    ("title", `String title);
                    ("priority", `Int priority);
                    ( "goal_id",
                      Json_util.string_opt_to_json matched_goal_id );
                    ( "released_task_id",
                      Json_util.string_opt_to_json released_task_id );
                  ] );
            ] )
      | Coord.Claim_next_no_eligible { excluded_count } ->
          ( active_goal_scope_json ~meta ~excluded_count
              ~effective_mode:claim_goal_scope.mode
              ~effective_goal_ids:claim_goal_scope.effective_goal_ids
              ?fallback_reason:claim_goal_scope.fallback_reason ()
          , [] )
      | Coord.Claim_next_no_unclaimed | Coord.Claim_next_error _ ->
          ( active_goal_scope_json ~meta ~effective_mode:claim_goal_scope.mode
              ~effective_goal_ids:claim_goal_scope.effective_goal_ids
              ?fallback_reason:claim_goal_scope.fallback_reason ()
          , [] )
    in
    Yojson.Safe.to_string
      (`Assoc
         ([
            ("result", `String message);
            ("claim_scope", claim_scope);
            ("auto_started", `Bool !auto_started_ok);
          ]
         @ claimed_task_fields
         @
         match accountability_warning with
         | Some warning -> [ ("routing_warning", `String warning) ]
         | None -> []))
  | "keeper_task_done" ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let result_text = Safe_ops.json_string ~default:"" "result" args |> String.trim in
    if task_id = ""
    then error_json "task_id is required. Use the task_id you got from keeper_task_claim."
    else (
      let ok, message =
        Tool_task.handle_transition
          {
            Tool_task.config;
            agent_name = keeper_agent_sender ~meta;
            sw = Eio_context.get_switch_opt ();
          }
          (`Assoc
             [
               "task_id", `String task_id;
               "action", `String "done";
               "notes", `String result_text;
             ])
      in
      keeper_tool_result_json ~ok ~message)
  | "keeper_task_submit_for_verification" ->
    let task_id = Safe_ops.json_string ~default:"" "task_id" args |> String.trim in
    let notes = Safe_ops.json_string ~default:"" "notes" args |> String.trim in
    let pr_url = Safe_ops.json_string ~default:"" "pr_url" args |> String.trim in
    if task_id = ""
    then error_json "task_id is required. Use the task_id you got from keeper_task_claim."
    else if notes = ""
    then error_json "notes is required. Include verification evidence and test summary."
    else if pr_url = ""
    then error_json "pr_url is required. Include the PR opened for this task."
    else (
      let ok, message =
        Tool_task.handle_transition
          {
            Tool_task.config;
            agent_name = keeper_agent_sender ~meta;
            sw = Eio_context.get_switch_opt ();
          }
          (`Assoc
             [
               "task_id", `String task_id;
               "action", `String "submit_for_verification";
               "notes", `String (notes ^ "\nPR: " ^ pr_url);
             ])
      in
      keeper_tool_result_json ~ok ~message)
  | other -> error_json ~fields:[ "tool", `String other ] "unknown_task_tool"
;;
