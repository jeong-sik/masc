open Types
open Tool_args

type context = {
  config : Room.config;
  agent_name : string;
  call_keeper_msg : (Yojson.Safe.t -> (bool * string)) option;
}

let split_csv raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let tool_result_json fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let error_result_json message =
  Yojson.Safe.to_string (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let schemas : tool_schema list =
  [
    {
      name = "masc_goal_upsert";
      description =
        "Create or update a goal (short/mid/long horizon). Supports partial updates when id exists.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("id", `Assoc [ ("type", `String "string") ]);
                  ( "horizon",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "short"; `String "mid"; `String "long" ]);
                      ] );
                  ("title", `Assoc [ ("type", `String "string") ]);
                  ("metric", `Assoc [ ("type", `String "string") ]);
                  ("target_value", `Assoc [ ("type", `String "string") ]);
                  ("due_date", `Assoc [ ("type", `String "string") ]);
                  ("priority", `Assoc [ ("type", `String "integer") ]);
                  ( "status",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "active";
                              `String "paused";
                              `String "done";
                              `String "dropped";
                            ] );
                      ] );
                  ("parent_goal_id", `Assoc [ ("type", `String "string") ]);
                ] );
          ];
    };
    {
      name = "masc_goal_list";
      description = "List goals with optional horizon/status filters.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "horizon",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "short"; `String "mid"; `String "long" ]);
                      ] );
                  ( "status",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "active";
                              `String "paused";
                              `String "done";
                              `String "dropped";
                            ] );
                      ] );
                ] );
          ];
    };
    {
      name = "masc_goal_snapshot";
      description = "Write a goal snapshot to .masc/goals_snapshots/*.json.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ("properties", `Assoc [ ("mode", `Assoc [ ("type", `String "string") ]) ]);
          ];
    };
    {
      name = "masc_goal_refresh";
      description =
        "Refresh priorities by cadence: daily(short), weekly(mid), monthly(long), or auto.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "mode",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "daily";
                              `String "weekly";
                              `String "monthly";
                              `String "auto";
                            ] );
                      ] );
                  ("force", `Assoc [ ("type", `String "boolean") ]);
                ] );
          ];
    };
    {
      name = "masc_goal_dispatch";
      description =
        "Build or execute hierarchical dispatch plan (child/grandchild). Task runtime creates backlog tasks only; callers must still claim one and call masc_plan_set_task. Uses approval gate when enabled.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("depth", `Assoc [ ("type", `String "integer") ]);
                  ("execute", `Assoc [ ("type", `String "boolean") ]);
                  ("approved", `Assoc [ ("type", `String "boolean") ]);
                  ( "runtime",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "task"; `String "keeper" ]);
                      ] );
                  ( "models",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("fallback_to_task", `Assoc [ ("type", `String "boolean") ]);
                  ("keeper_prefix", `Assoc [ ("type", `String "string") ]);
                  ("goal_ids", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
                ] );
          ];
    };
    {
      name = "masc_goal_review";
      description = "Review one goal and apply outcome (done/progress/blocked/dropped).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("goal_id", `Assoc [ ("type", `String "string") ]);
                  ( "outcome",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "done";
                              `String "progress";
                              `String "blocked";
                              `String "dropped";
                            ] );
                      ] );
                  ( "new_horizon",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "short"; `String "mid"; `String "long" ]);
                      ] );
                  ("note", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "goal_id"; `String "outcome" ]);
          ];
    };
  ]

let handle_goal_upsert ctx args =
  let id = get_string_opt args "id" in
  let horizon = get_string_opt args "horizon" in
  let title = get_string_opt args "title" in
  let metric = get_string_opt args "metric" in
  let target_value = get_string_opt args "target_value" in
  let due_date = get_string_opt args "due_date" in
  let priority = get_int_opt args "priority" in
  let status = get_string_opt args "status" in
  let parent_goal_id = get_string_opt args "parent_goal_id" in
  match
    Goal_store.upsert_goal ctx.config ?id ?horizon ?title ?metric ?target_value
      ?due_date ?priority ?status ?parent_goal_id ()
  with
  | Ok (goal, kind) ->
      let kind_str = match kind with `created -> "created" | `updated -> "updated" in
      ( true,
        tool_result_json
          [
            ("result", `String kind_str);
            ("goal", Goal_store.goal_to_yojson goal);
          ] )
  | Error msg -> (false, error_result_json msg)

let validate_horizon_filter args =
  let raw = get_string_opt args "horizon" in
  match raw with
  | None -> Ok None
  | Some _ -> (
      match Goal_store.normalize_horizon raw with
      | Some v -> Ok (Some v)
      | None -> Error "invalid horizon filter")

let validate_status_filter args =
  let raw = get_string_opt args "status" in
  match raw with
  | None -> Ok None
  | Some _ -> (
      match Goal_store.normalize_status raw with
      | Some v -> Ok (Some v)
      | None -> Error "invalid status filter")

let handle_goal_list ctx args =
  match validate_horizon_filter args, validate_status_filter args with
  | Error e, _ | _, Error e -> (false, error_result_json e)
  | Ok horizon, Ok status ->
      let goals = Goal_store.list_goals ctx.config ?horizon ?status () in
      let rollup = Goal_store.compute_rollup goals in
      ( true,
        tool_result_json
          [
            ("count", `Int (List.length goals));
            ("goals", `List (List.map Goal_store.goal_to_yojson goals));
            ("rollup", Goal_store.rollup_to_yojson rollup);
          ] )

let handle_goal_snapshot ctx args =
  let mode = get_string args "mode" "manual" in
  let snap = Goal_store.snapshot ctx.config ~mode in
  ( true,
    tool_result_json
      [
        ("snapshot", Goal_store.snapshot_to_yojson snap);
      ] )

let refresh_one_mode ctx ~mode ~now =
  match Goal_store.refresh ctx.config ~mode with
  | Error e -> Error e
  | Ok result ->
      Goal_scheduler.commit_run ctx.config ~mode ~now;
      Ok result

let handle_goal_refresh ctx args =
  let mode = get_string args "mode" "daily" |> String.lowercase_ascii in
  let force = get_bool args "force" false in
  let now = Time_compat.now () in
  let valid_mode = mode = "auto" || List.mem mode [ "daily"; "weekly"; "monthly" ] in
  if not valid_mode then
    (false, error_result_json "mode must be daily|weekly|monthly|auto")
  else
  let selected_modes =
    if mode = "auto" then
      if force then [ "daily"; "weekly"; "monthly" ]
      else Goal_scheduler.due_modes ctx.config ~now
    else
      if force then [ mode ]
      else
        let due = Goal_scheduler.due_modes ctx.config ~now in
        if List.mem mode due then [ mode ] else []
  in
  if selected_modes = [] then
    ( true,
      tool_result_json
        [
          ("mode", `String mode);
          ("skipped", `Bool true);
          ("message", `String "no cadence window due");
        ] )
  else
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | m :: rest -> (
          match refresh_one_mode ctx ~mode:m ~now with
          | Ok r -> collect (r :: acc) rest
          | Error e -> Error (Printf.sprintf "[%s] %s" m e))
    in
    match collect [] selected_modes with
    | Error e -> (false, error_result_json e)
    | Ok results ->
        ( true,
          tool_result_json
            [
              ("mode", `String mode);
              ("skipped", `Bool false);
              ( "results",
                `List
                  (List.map Goal_store.refresh_result_to_yojson results) );
            ] )

let filter_goal_ids goals ids =
  if ids = [] then goals
  else List.filter (fun g -> List.mem g.Goal_store.id ids) goals

let unknown_goal_ids goals ids =
  if ids = [] then []
  else
    let known_ids = List.map (fun g -> g.Goal_store.id) goals in
    List.filter (fun goal_id -> not (List.mem goal_id known_ids)) ids

type keeper_call_outcome = {
  node_id : string;
  keeper_name : string;
  depth : int;
  ok : bool;
  reply_preview : string option;
  error : string option;
  fallback_task : string option;
}
[@@deriving yojson]

type keeper_execution = {
  executed : bool;
  call_count : int;
  success_count : int;
  failure_count : int;
  fallback_task_count : int;
  calls : keeper_call_outcome list;
}
[@@deriving yojson]

let normalize_runtime value =
  match String.lowercase_ascii (String.trim value) with
  | "task" -> Some "task"
  | "keeper" -> Some "keeper"
  | _ -> None

let env_keeper_models () =
  match Env_config.Model_defaults.goal_models_opt () with
  | None -> []
  | Some raw -> split_csv raw

let default_keeper_models () =
  let from_env = env_keeper_models () in
  if from_env <> [] then from_env
  else Provider_adapter.preferred_execution_model_labels ()

let sanitize_keeper_name s =
  let buf = Buffer.create (String.length s) in
  let push_dash () =
    if Buffer.length buf = 0 then ()
    else if Buffer.nth buf (Buffer.length buf - 1) <> '-' then Buffer.add_char buf '-'
  in
  String.iter
    (fun c ->
      let lc = Char.lowercase_ascii c in
      if (lc >= 'a' && lc <= 'z') || (lc >= '0' && lc <= '9') then
        Buffer.add_char buf lc
      else push_dash ())
    s;
  let raw = Buffer.contents buf in
  let trimmed = String.trim raw in
  let base = if trimmed = "" then "goal-keeper" else trimmed in
  if String.length base > 48 then String.sub base 0 48 else base

let reply_preview body =
  try
    let json = Yojson.Safe.from_string body in
    match Yojson.Safe.Util.member "reply" json with
    | `String s ->
        if String.length s > 160 then Some (String.sub s 0 160 ^ "...")
        else Some s
    | _ -> None
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

let add_fallback_task ctx node err =
  let goal_prefix =
    Printf.sprintf "[goal:%s][fallback]" node.Goal_orchestrator.goal_id
  in
  (* Idempotency: skip if a fallback task for this goal already exists *)
  let backlog = Room.read_backlog ctx.config in
  let already_exists =
    List.exists
      (fun (task : Types.task) ->
        match task.task_status with
        | Types.Done _ | Types.Cancelled _ -> false
        | _ -> String.length task.title >= String.length goal_prefix
               && String.sub task.title 0 (String.length goal_prefix) = goal_prefix)
      backlog.tasks
  in
  if already_exists then (
    Log.Misc.info "add_fallback_task skipped (duplicate): goal=%s node=%s"
      node.Goal_orchestrator.goal_id node.Goal_orchestrator.node_id;
    None)
  else
    let title =
      Printf.sprintf "%s %s" goal_prefix node.Goal_orchestrator.title
    in
    let desc =
      Printf.sprintf "keeper dispatch failed at node=%s depth=%d error=%s"
        node.Goal_orchestrator.node_id node.Goal_orchestrator.depth err
    in
    try Some (Room.add_task ctx.config ~title ~priority:2 ~description:desc)
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Misc.error "add_fallback_task failed: %s" (Printexc.to_string exn);
      None

let run_keeper_call ctx ~models:_models_ignored ~keeper_prefix ?(fallback_to_task = true) node =
  let keeper_name =
    sanitize_keeper_name
      (Printf.sprintf "%s-%s-%s" keeper_prefix node.Goal_orchestrator.goal_id
         node.Goal_orchestrator.node_id)
  in
  let horizon =
    if node.Goal_orchestrator.depth <= 1 then "short" else "mid"
  in
  let message =
    if node.Goal_orchestrator.depth <= 1 then
      Printf.sprintf
        "Goal '%s' child executor. Return: 1) concrete next action 2) 3-step checklist."
        node.Goal_orchestrator.title
    else
      Printf.sprintf
        "Goal '%s' grandchild substep. Return one executable micro-task and acceptance criteria."
        node.Goal_orchestrator.title
  in
  match ctx.call_keeper_msg with
  | None ->
      let fallback =
        if fallback_to_task then
          add_fallback_task ctx node "keeper runtime unavailable"
        else None
      in
      {
        node_id = node.node_id;
        keeper_name;
        depth = node.depth;
        ok = false;
        reply_preview = None;
        error = Some "keeper runtime unavailable";
        fallback_task = fallback;
      }
  | Some call_keeper_msg ->
      let args =
        `Assoc
          [
            ("name", `String keeper_name);
            ("message", `String message);
            ("priority_hint", `Int node.priority);
            ("dispatch_horizon", `String horizon);
          ]
      in
      let ok, body = call_keeper_msg args in
      if ok then
        {
          node_id = node.node_id;
          keeper_name;
          depth = node.depth;
          ok = true;
          reply_preview = reply_preview body;
          error = None;
          fallback_task = None;
        }
      else
        let fallback =
          if fallback_to_task then add_fallback_task ctx node body else None
        in
        {
          node_id = node.node_id;
          keeper_name;
          depth = node.depth;
          ok = false;
          reply_preview = None;
          error = Some body;
          fallback_task = fallback;
        }

let run_keeper_dispatch ctx ~plan ~models ~fallback_to_task ~keeper_prefix =
  let run_node node =
    let parent_result =
      run_keeper_call ctx ~models ~keeper_prefix ~fallback_to_task node
    in
    let child_results =
      List.map
        (fun gc -> run_keeper_call ctx ~models ~keeper_prefix ~fallback_to_task gc)
        node.Goal_orchestrator.children
    in
    parent_result :: child_results
  in
  let calls = List.concat (List.map run_node plan.Goal_orchestrator.nodes) in
  let success_count = List.length (List.filter (fun c -> c.ok) calls) in
  let fallback_task_count =
    List.length
      (List.filter (fun c -> match c.fallback_task with Some _ -> true | None -> false) calls)
  in
  {
    executed = true;
    call_count = List.length calls;
    success_count;
    failure_count = List.length calls - success_count;
    fallback_task_count;
    calls;
  }

let handle_goal_dispatch ctx args =
  let budget = Goal_guard.load_budget () in
  let requested_depth = get_int args "depth" 2 in
  let effective_depth = Goal_guard.clamp_depth budget requested_depth in
  let execute = get_bool args "execute" true in
  let approved = get_bool args "approved" false in
  let runtime_raw =
    match get_string_opt args "runtime" with
    | Some v -> v
    | None -> (
        Env_config.Model_defaults.goal_dispatch_runtime ())
  in
  let runtime_opt = normalize_runtime runtime_raw in
  let goal_ids = get_string_list args "goal_ids" in
  (* Legacy model field: cascade_name is the authority.
     Callers still accept "models" in args but the value is ignored. *)
  let _models_ignored = get_string_list args "models" in
  let fallback_to_task = get_bool args "fallback_to_task" true in
  let keeper_prefix = get_string args "keeper_prefix" "goal" in
  let active_goals = Goal_store.active_goals ctx.config in
  let missing_goal_ids = unknown_goal_ids active_goals goal_ids in
  match runtime_opt with
  | None -> (false, error_result_json "runtime must be task|keeper")
  | Some _ when missing_goal_ids <> [] ->
      ( false,
        error_result_json
          (Printf.sprintf "unknown goal_ids: %s"
             (String.concat ", " missing_goal_ids)) )
  | Some runtime ->
  let goals = filter_goal_ids active_goals goal_ids in
  let plan =
    Goal_orchestrator.build_plan ~goals
      {
        Goal_orchestrator.requested_depth;
        effective_depth;
        child_limit = budget.parallel_children;
        grandchild_limit = budget.parallel_grandchildren;
        fanout_short = budget.fanout_short;
        fanout_mid = budget.fanout_mid;
        fanout_long = budget.fanout_long;
      }
  in
  let needs_approval = Goal_guard.approval_required budget ~execute ~approved in
  if needs_approval then
    ( true,
      tool_result_json
        [
          ("runtime", `String runtime);
          ("approval_required", `Bool true);
          ("executed", `Bool false);
          ("plan", Goal_orchestrator.dispatch_plan_to_yojson plan);
          ("message", `String "dispatch approved=false; execution skipped");
        ] )
  else if not execute then
    ( true,
      tool_result_json
        [
          ("runtime", `String runtime);
          ("approval_required", `Bool false);
          ("executed", `Bool false);
          ("plan", Goal_orchestrator.dispatch_plan_to_yojson plan);
        ] )
  else if runtime = "task" then
    let summary =
      Goal_orchestrator.execute_plan ctx.config ~agent_name:ctx.agent_name plan
    in
    ( true,
      tool_result_json
        [
          ("runtime", `String runtime);
          ("approval_required", `Bool false);
          ("current_task_bound", `Bool false);
          ( "message",
            `String
              "dispatch created backlog tasks only; claim one and call masc_plan_set_task to bind current_task" );
          ("plan", Goal_orchestrator.dispatch_plan_to_yojson plan);
          ("execution", Goal_orchestrator.execution_summary_to_yojson summary);
        ] )
  else
    let keeper_exec =
      run_keeper_dispatch ctx ~plan ~models:[] ~fallback_to_task ~keeper_prefix
    in
    ( true,
      tool_result_json
        [
          ("runtime", `String runtime);
          ("approval_required", `Bool false);
          ("plan", Goal_orchestrator.dispatch_plan_to_yojson plan);
          ("keeper_execution", keeper_execution_to_yojson keeper_exec);
        ] )

let handle_goal_review ctx args =
  let goal_id = get_string args "goal_id" "" in
  let outcome = get_string args "outcome" "" in
  let new_horizon = get_string_opt args "new_horizon" in
  let note = get_string_opt args "note" in
  if goal_id = "" || outcome = "" then
    (false, error_result_json "goal_id and outcome are required")
  else
    match Goal_store.review_goal ctx.config ~goal_id ~outcome ?new_horizon ?note () with
    | Ok goal ->
        ( true,
          tool_result_json
            [
              ("goal", Goal_store.goal_to_yojson goal);
            ] )
    | Error msg -> (false, error_result_json msg)

let dispatch ctx ~name ~args =
  match name with
  | "masc_goal_upsert" -> Some (handle_goal_upsert ctx args)
  | "masc_goal_list" -> Some (handle_goal_list ctx args)
  | "masc_goal_snapshot" -> Some (handle_goal_snapshot ctx args)
  | "masc_goal_refresh" -> Some (handle_goal_refresh ctx args)
  | "masc_goal_dispatch" -> Some (handle_goal_dispatch ctx args)
  | "masc_goal_review" -> Some (handle_goal_review ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_goals
           ~input_schema:s.input_schema
           ()))
    schemas
