(** Tool_task - Core task CRUD operations

    Handles: add_task, batch_add_tasks, cancel_task, claim, claim_next,
    done, release, task_history, tasks, transition, update_priority, archive_view
*)

open Yojson.Safe.Util

type result = bool * string

type context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t option;
}

open Tool_args

let result_to_response = function
  | Ok msg -> (true, msg)
  | Error e -> (false, Types.masc_error_to_string e)

let verdict_to_string (result : Anti_rationalization.review_result) =
  match result.verdict with
  | Anti_rationalization.Approve -> "approve"
  | Anti_rationalization.Reject reason -> "reject:" ^ reason

(** Validate task_id is non-empty. Prevents phantom operations on empty IDs. *)
let validate_task_id task_id =
  if task_id = "" then Error (Types.TaskNotFound "")
  else Ok task_id

let review_completion_notes
    ~(completion_contract : string list option)
    ~(evaluator_cascade : string option)
    ~(ctx : context)
    ~(task_opt : Types.task option)
    ~(task_id : string)
    ~(notes : string) : string option =
  match task_opt with
  | None -> None
  | Some task ->
      let ar_req : Anti_rationalization.review_request = {
        task_title = task.title;
        task_description = task.description;
        completion_notes = notes;
        agent_name = ctx.agent_name;
      } in
      let on_verdict result =
        Eval_calibration.record_verdict
          ~task_id ~req:ar_req ~result ();
        (try
           Sse.broadcast
             (`Assoc
               [
                 ("type", `String "oas:masc:harness:verdict_recorded");
                 ( "payload",
                   `Assoc
                     [
                       ("timestamp", `Float (Time_compat.now ()));
                       ("task_id", `String task_id);
                       ("task_title", `String ar_req.task_title);
                       ("agent_name", `String ar_req.agent_name);
                       ("gate", `String result.gate);
                       ("verdict", `String (verdict_to_string result));
                       ( "evaluator_cascade",
                         `String result.evaluator_cascade );
                       ( "fallback_reason",
                         match result.fallback_reason with
                         | Some reason -> `String reason
                         | None -> `Null );
                     ] );
               ])
         with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Harness.warn
              "[anti-rationalization] verdict sse broadcast failed: %s"
              (Printexc.to_string exn))
      in
      let few_shot_block =
        Eval_calibration.format_few_shot_block
          (Eval_calibration.select_examples ~max_examples:3)
      in
      match (Anti_rationalization.review
         ?sw:ctx.sw
         ?evaluator_cascade
         ?completion_contract
         ~on_verdict ~few_shot_block ar_req).verdict with
      | Anti_rationalization.Reject reason -> Some reason
      | Anti_rationalization.Approve -> None

let can_review_completion ~(task_opt : Types.task option) ~(agent_name : string) =
  match task_opt with
  | Some task ->
      (match task.task_status with
       | Types.Claimed { assignee; _ }
       | Types.InProgress { assignee; _ } ->
           String.equal assignee agent_name
       | _ -> false)
  | None -> false

let completion_rejection_message ?(allow_force = false) reason =
  if allow_force then
    Printf.sprintf
      "Completion rejected by anti-rationalization gate: %s\n\
       Revise your completion notes to describe actual work, then retry.\n\
       Use force=true to override (operator only)." reason
  else
    Printf.sprintf
      "Completion rejected by anti-rationalization gate: %s\n\
       Revise your completion notes to describe actual work, then retry." reason

(* Handlers *)

let handle_add_task ctx args =
  let title = get_string args "title" "" in
  let priority = get_int args "priority" 3 in
  let description = get_string args "description" "" in
  (* BUG-009/010: Validate title and priority *)
  let trimmed_title = String.trim title in
  if trimmed_title = "" then
    (false, "Task title cannot be empty or whitespace-only")
  else if priority < 1 || priority > 5 then
    (false, Printf.sprintf "Priority must be between 1 and 5, got %d" priority)
  else
    (true, Room.add_task ctx.config ~title:trimmed_title ~priority ~description)

let handle_batch_add_tasks ctx args =
  let tasks_json = match args |> member "tasks" with
    | `List l -> l
    | _ -> []
  in
  if tasks_json = [] then
    (false, "tasks array is empty or missing")
  else
  let validated = List.mapi (fun idx t ->
    let title = String.trim (t |> member "title" |> to_string) in
    let priority = t |> member "priority" |> to_int_option |> Option.value ~default:3 in
    let description = t |> member "description" |> to_string_option |> Option.value ~default:"" in
    if title = "" then
      Error (Printf.sprintf "item[%d]: title cannot be empty" idx)
    else if priority < 1 || priority > 5 then
      Error (Printf.sprintf "item[%d]: priority must be 1-5, got %d" idx priority)
    else
      Ok (title, priority, description)
  ) tasks_json in
  let errors = List.filter_map (function Error e -> Some e | Ok _ -> None) validated in
  if errors <> [] then
    (false, Printf.sprintf "Validation failed:\n%s" (String.concat "\n" errors))
  else
    let tasks = List.filter_map (function Ok t -> Some t | Error _ -> None) validated in
    (true, Room.batch_add_tasks ctx.config tasks)

let handle_claim ctx args =
  if not (try Room.is_agent_joined ctx.config ~agent_name:ctx.agent_name with Sys_error _ | Not_found -> false) then
    result_to_response (Error (Types.AgentNotJoined ctx.agent_name))
  else
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response (Error e)
  | Ok task_id ->
  let agent_role = match get_string args "agent_role" "" with
    | "" -> Types_core.Unassigned
    | s -> Types_core.role_of_string s
  in
  let result = Room.claim_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ~agent_role () in
  (* Notification harness: push claim event to all active sessions *)
  (match result with
   | Ok _ ->
       (* Auto-set current_task so planning tools pick it up immediately *)
       Planning_eio.set_current_task ctx.config ~task_id;
       Subscriptions.push_event_to_sessions (`Assoc [
         ("type", `String "masc/task_claimed");
         ("task_id", `String task_id);
         ("agent_name", `String ctx.agent_name);
         ("timestamp", `Float (Time_compat.now ()));
       ])
   | Error e -> Log.Task.debug "task claim failed for %s: %s" task_id (Types.masc_error_to_string e));
  result_to_response result

let handle_claim_next ctx _args =
  if not (try Room.is_agent_joined ctx.config ~agent_name:ctx.agent_name with Sys_error _ | Not_found -> false) then
    (false, Printf.sprintf "Agent '%s' is not a member of this room" ctx.agent_name)
  else
  let result = Room.claim_next_r ctx.config ~agent_name:ctx.agent_name () in
  let message = match result with
    | Room.Claim_next_claimed { task_id; message; _ } ->
        (* Auto-set current_task so planning tools pick it up immediately *)
        Planning_eio.set_current_task ctx.config ~task_id;
        message
    | Room.Claim_next_no_unclaimed -> "📋 No unclaimed tasks available"
    | Room.Claim_next_no_eligible _ -> "📋 No unclaimed tasks available"
    | Room.Claim_next_error e -> Printf.sprintf "❌ Error: %s" e
  in
  (true, message)

let handle_release ctx args =
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response (Error e)
  | Ok task_id ->
  let expected_version = get_int_opt args "expected_version" in
  result_to_response
    (Room.release_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ?expected_version ())

let handle_done ctx args =
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response (Error e)
  | Ok task_id ->
  let notes = get_string args "notes" "" in
  (* Get task info BEFORE completion to extract actual start time *)
  let tasks = Room.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Types.task) -> t.id = task_id) tasks in
  let default_time = Time_compat.now () -. 60.0 in
  let (started_at_actual, collaborators_from_task) = match task_opt with
    | Some t -> (match t.task_status with
        | Types.InProgress { started_at; assignee } ->
            let ts = Types.parse_iso8601 ~default_time started_at in
            let collabs = if assignee <> "" && assignee <> ctx.agent_name then [assignee] else [] in
            (ts, collabs)
        | Types.Claimed { claimed_at; assignee } ->
            let ts = Types.parse_iso8601 ~default_time claimed_at in
            let collabs = if assignee <> "" && assignee <> ctx.agent_name then [assignee] else [] in
            (ts, collabs)
        | _ -> (default_time, []))
    | None -> (default_time, [])
  in
  let result =
    if not (can_review_completion ~task_opt ~agent_name:ctx.agent_name) then
      Room.complete_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ~notes
    else
      let gate_rejection =
        review_completion_notes
          ~completion_contract:None
          ~evaluator_cascade:None
          ~ctx
          ~task_opt
          ~task_id
          ~notes
      in
      match gate_rejection with
      | Some reason ->
          Error (Types.TaskInvalidState (completion_rejection_message reason))
      | None ->
          Room.complete_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ~notes
  in
  (* Notify A2A subscribers on successful completion *)
  (match result with
   | Ok _ ->
       A2a_tools.notify_event
         ~event_type:A2a_tools.TaskUpdate
         ~agent:ctx.agent_name
         ~data:(`Assoc [
           ("task_id", `String task_id);
           ("action", `String "done");
           ("notes", `String notes);
         ]);
       (* Notification harness: push done event to all active sessions *)
       Subscriptions.push_event_to_sessions (`Assoc [
         ("type", `String "masc/task_done");
         ("task_id", `String task_id);
         ("agent_name", `String ctx.agent_name);
         ("timestamp", `Float (Time_compat.now ()));
       ])
   | Error err ->
       Log.Task.error "done transition failed: %s" (Types.masc_error_to_string err));
  (* Record metrics on successful completion *)
  (match result with
   | Ok _ ->
       let metric : Metrics_store_eio.task_metric = {
         id = Printf.sprintf "metric-%s-%d" task_id (int_of_float (Time_compat.now () *. 1000.));
         agent_id = ctx.agent_name;
         task_id;
         started_at = started_at_actual;
         completed_at = Some (Time_compat.now ());
         success = true;
         error_message = None;
         collaborators = collaborators_from_task;
         handoff_from = None;
         handoff_to = None;
       } in
       (try ignore (Metrics_store_eio.record ctx.config metric)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Task.error "Metrics_store_eio.record(done) failed: %s" (Printexc.to_string exn));
       (* Feed success into Thompson Sampling quality signal *)
       Thompson_sampling.record_vote ~agent_name:ctx.agent_name ~direction:`Up;
       (* Prometheus: record task completion *)
       Prometheus.record_task_completed ();
       (* Audit: log done event *)
       Audit_log.log_done_task ctx.config ~agent_id:ctx.agent_name
         ~room_id:(Filename.basename ctx.config.base_path)
         ~task_id ()
   | Error err ->
       Log.Task.error "metrics record failed: %s" (Types.masc_error_to_string err));
  result_to_response result

let handle_cancel_task ctx args =
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response (Error e)
  | Ok task_id ->
  let reason = get_string args "reason" "" in
  let tasks = Room.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Types.task) -> t.id = task_id) tasks in
  let started_at_actual = match task_opt with
    | Some t -> (match t.task_status with
        | Types.InProgress { started_at; _ } ->
            Types.parse_iso8601 ~default_time:(Time_compat.now () -. 60.0) started_at
        | Types.Claimed { claimed_at; _ } ->
            Types.parse_iso8601 ~default_time:(Time_compat.now () -. 60.0) claimed_at
        | _ -> Time_compat.now () -. 60.0)
    | None -> Time_compat.now () -. 60.0
  in
  let result = Room.cancel_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ~reason in
  (* Record failed metric on cancellation *)
  (match result with
   | Ok _ ->
       let metric : Metrics_store_eio.task_metric = {
         id = Printf.sprintf "metric-%s-%d" task_id (int_of_float (Time_compat.now () *. 1000.));
         agent_id = ctx.agent_name;
         task_id;
         started_at = started_at_actual;
         completed_at = Some (Time_compat.now ());
         success = false;
         error_message = Some (if reason = "" then "Cancelled" else reason);
         collaborators = [];
         handoff_from = None;
         handoff_to = None;
       } in
       (try ignore (Metrics_store_eio.record ctx.config metric)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Task.error "Metrics_store_eio.record(cancel) failed: %s" (Printexc.to_string exn));
       (* Feed failure into Thompson Sampling quality signal *)
       Thompson_sampling.record_vote ~agent_name:ctx.agent_name ~direction:`Down;
       (* Prometheus: record task failure *)
       Prometheus.record_task_failed ();
       (* Notification harness: push cancel event to all active sessions *)
       Subscriptions.push_event_to_sessions (`Assoc [
         ("type", `String "masc/task_cancelled");
         ("task_id", `String task_id);
         ("agent_name", `String ctx.agent_name);
         ("reason", `String reason);
         ("timestamp", `Float (Time_compat.now ()));
       ])
   | Error err ->
       Log.Task.error "metrics record failed: %s" (Types.masc_error_to_string err));
  result_to_response result

let transition_known_args =
  [
    "task_id";
    "action";
    "notes";
    "reason";
    "expected_version";
    "agent_name";
    "force";
    "completion_contract";
    "evaluator_cascade";
  ]

let handle_transition ctx args =
  let unknown = match args with
    | `Assoc kvs ->
      List.filter (fun (k, _) -> not (List.mem k transition_known_args)) kvs
    | _ -> []
  in
  if unknown <> [] then
    let names = String.concat ", " (List.map fst unknown) in
    (false, Printf.sprintf "Unknown argument(s): %s. Valid: %s"
      names (String.concat ", " transition_known_args))
  else
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response (Error e)
  | Ok task_id ->
  let action = get_string args "action" "" in
  if action = "" then
    (false, Printf.sprintf "action is required (%s)" (String.concat ", " Types_core.valid_task_actions))
  else
  let notes = get_string args "notes" "" in
  let reason = get_string args "reason" "" in
  let completion_contract =
    match get_string_list args "completion_contract" with
    | [] -> None
    | items -> Some items
  in
  let evaluator_cascade = get_string_opt args "evaluator_cascade" in
  let expected_version = get_int_opt args "expected_version" in
  let action_lc = String.lowercase_ascii action in
  let force_raw = get_bool args "force" false in
  (* force=true requires admin privilege: initial_admin or Admin role *)
  let force =
    if force_raw then
      match Auth.read_initial_admin ctx.config.base_path with
      | Some admin when String.equal ctx.agent_name admin -> true
      | _ ->
        Log.Task.warn "[anti-rationalization] force=true rejected: agent=%s lacks admin privilege"
          ctx.agent_name;
        false
    else false
  in
  let tasks = Room.get_tasks_raw ctx.config in
  let task_opt = List.find_opt (fun (t : Types.task) -> t.id = task_id) tasks in
  (* Anti-rationalization gate: verify completion notes before allowing "done" *)
  let gate_rejection =
    if action_lc = "done" && not force && can_review_completion ~task_opt ~agent_name:ctx.agent_name then
      review_completion_notes
        ~completion_contract
        ~evaluator_cascade
        ~ctx
        ~task_opt
        ~task_id
        ~notes
    else None
  in
  match gate_rejection with
  | Some reason ->
    (false, completion_rejection_message ~allow_force:true reason)
  | None ->
  let default_time = Time_compat.now () -. 60.0 in
  let (started_at_actual, collaborators_from_task) = match task_opt with
    | Some t -> (match t.task_status with
        | Types.InProgress { started_at; assignee } ->
            let ts = Types.parse_iso8601 ~default_time started_at in
            let collabs = if assignee <> "" && assignee <> ctx.agent_name then [assignee] else [] in
            (ts, collabs)
        | Types.Claimed { claimed_at; assignee } ->
            let ts = Types.parse_iso8601 ~default_time claimed_at in
            let collabs = if assignee <> "" && assignee <> ctx.agent_name then [assignee] else [] in
            (ts, collabs)
        | _ -> (default_time, []))
    | None -> (default_time, [])
  in
  let max_cas_retries = 3 in
  let cas_retry_delay_s = 0.05 in
  let is_version_mismatch = function
    | Error (Types.TaskInvalidState msg) ->
        let prefix = "Version mismatch" in
        String.length msg >= String.length prefix
        && String.sub msg 0 (String.length prefix) = prefix
    | _ -> false
  in
  let rec try_transition attempt =
    let ev = if attempt = 0 then expected_version else None in
    let r = Room.transition_task_r ctx.config ~agent_name:ctx.agent_name
              ~task_id ~action ?expected_version:ev ~notes ~reason () in
    if is_version_mismatch r && attempt < max_cas_retries then begin
      Log.Task.info "CAS version mismatch on %s (attempt %d/%d), retrying in %.0fms"
        task_id (attempt + 1) max_cas_retries (cas_retry_delay_s *. 1000.0);
      Time_compat.sleep cas_retry_delay_s;
      try_transition (attempt + 1)
    end else
      r
  in
  let result = try_transition 0 in
  (* Notify A2A subscribers on successful transition *)
  (match result with
   | Ok _ ->
       A2a_tools.notify_event
         ~event_type:A2a_tools.TaskUpdate
         ~agent:ctx.agent_name
         ~data:(`Assoc [
           ("task_id", `String task_id);
           ("action", `String action);
           ("notes", `String notes);
         ]);
       (* Notification harness: push task transition to all active sessions *)
       Subscriptions.push_event_to_sessions (`Assoc [
         ("type", `String "masc/task_transition");
         ("task_id", `String task_id);
         ("action", `String action);
         ("agent_name", `String ctx.agent_name);
         ("timestamp", `Float (Time_compat.now ()));
       ])
   | Error err ->
       Log.Task.error "task transition failed: %s" (Types.masc_error_to_string err));
  (* Record metrics *)
  (match result, action_lc with
   | Ok _, "done" ->
       let metric : Metrics_store_eio.task_metric = {
         id = Printf.sprintf "metric-%s-%d" task_id (int_of_float (Time_compat.now () *. 1000.));
         agent_id = ctx.agent_name;
         task_id;
         started_at = started_at_actual;
         completed_at = Some (Time_compat.now ());
         success = true;
         error_message = None;
         collaborators = collaborators_from_task;
         handoff_from = None;
         handoff_to = None;
       } in
       (try ignore (Metrics_store_eio.record ctx.config metric)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Task.error "Metrics_store_eio.record(transition-done) failed: %s" (Printexc.to_string exn));
       Thompson_sampling.record_vote ~agent_name:ctx.agent_name ~direction:`Up;
       Prometheus.record_task_completed ()
   | Ok _, "cancel" ->
       let metric : Metrics_store_eio.task_metric = {
         id = Printf.sprintf "metric-%s-%d" task_id (int_of_float (Time_compat.now () *. 1000.));
         agent_id = ctx.agent_name;
         task_id;
         started_at = started_at_actual;
         completed_at = Some (Time_compat.now ());
         success = false;
         error_message = Some (if reason = "" then "Cancelled" else reason);
         collaborators = collaborators_from_task;
         handoff_from = None;
         handoff_to = None;
       } in
       (try ignore (Metrics_store_eio.record ctx.config metric)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Task.error "Metrics_store_eio.record(transition-cancel) failed: %s" (Printexc.to_string exn));
       Thompson_sampling.record_vote ~agent_name:ctx.agent_name ~direction:`Down;
       Prometheus.record_task_failed ()
   | _ -> ());
  result_to_response result

let handle_update_priority ctx args =
  let task_id = get_string args "task_id" "" in
  let priority = get_int args "priority" 3 in
  (true, Room.update_priority ctx.config ~task_id ~priority)

let handle_tasks ctx args =
  let include_done = get_bool args "include_done" false in
  let include_cancelled = get_bool args "include_cancelled" false in
  let status =
    match args |> member "status" with
    | `String s when s <> "" -> Some s
    | _ -> None
  in
  (true, Room.list_tasks ctx.config ~include_done ~include_cancelled ?status)

let handle_task_history ctx args =
  let task_id = get_string args "task_id" "" in
  let limit = get_int args "limit" 50 in
  let scan_limit = min 500 (limit * 5) in
  let lines = Mcp_server.read_event_lines ctx.config ~limit:scan_limit in
  let parsed =
    List.filter_map (fun line ->
      try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None
    ) lines
  in
  let matches_task json =
    let task = json |> member "task" |> to_string_option in
    let task_id_field = json |> member "task_id" |> to_string_option in
    match task, task_id_field with
    | Some t, _ when t = task_id -> true
    | _, Some t when t = task_id -> true
    | _ -> false
  in
  let rec take n xs =
    match xs with
    | [] -> []
    | _ when n <= 0 -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  let events = parsed |> List.filter matches_task |> take limit in
  (true, Yojson.Safe.pretty_to_string (`List events))

let handle_archive_view ctx args =
  let limit = get_int args "limit" 20 in
  let archive_path = Room_utils.archive_path ctx.config in
  if not (Room_utils.path_exists ctx.config archive_path) then
    (true, Yojson.Safe.pretty_to_string (`Assoc [("count", `Int 0); ("tasks", `List [])]))
  else
    let json = Room_utils.read_json ctx.config archive_path in
    let tasks =
      match json with
      | `List items -> items
      | `Assoc _ ->
          (match json |> member "tasks" with
           | `List items -> items
           | _ -> [])
      | _ -> []
    in
    let total = List.length tasks in
    let tasks =
      if total <= limit then tasks
      else
        let rec drop n xs =
          match xs with
          | [] -> []
          | _ when n <= 0 -> xs
          | _ :: rest -> drop (n - 1) rest
        in
        drop (total - limit) tasks
    in
    let response = `Assoc [
      ("count", `Int (List.length tasks));
      ("total", `Int total);
      ("tasks", `List tasks);
    ] in
    (true, Yojson.Safe.pretty_to_string response)

let schemas : Types.tool_schema list = [
  {
    name = "masc_add_task";
    description = "Add a new task to the backlog for agents to claim. \
Tasks have status flow: todo → claimed → done/cancelled. \
Priority 1=urgent, 5=low (default 3). \
Returns task-XXX ID for tracking. \
Example: masc_add_task({title: 'Fix login bug', priority: 1, description: 'Users cannot login with SSO'})";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Task title");
        ]);
        ("priority", `Assoc [
          ("type", `String "integer");
          ("description", `String "Priority 1-5 (1=highest)");
          ("default", `Int 3);
        ]);
        ("description", `Assoc [
          ("type", `String "string");
          ("description", `String "Task description");
        ]);
      ]);
      ("required", `List [`String "title"]);
    ];
  };
  {
    name = "masc_batch_add_tasks";
    description = "Add multiple tasks in one call (more efficient than repeated masc_add_task). \
Use when: loading sprint backlog, importing from JIRA, creating related tasks. \
Each task gets unique ID (task-XXX). Atomic: all succeed or all fail. \
Example: masc_batch_add_tasks({tasks: [{title: 'Task A', priority: 2}, {title: 'Task B'}]})";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tasks", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "object");
            ("properties", `Assoc [
              ("title", `Assoc [
                ("type", `String "string");
                ("description", `String "Task title");
              ]);
              ("priority", `Assoc [
                ("type", `String "integer");
                ("description", `String "Priority 1-5 (1=highest)");
                ("default", `Int 3);
              ]);
              ("description", `Assoc [
                ("type", `String "string");
                ("description", `String "Task description");
              ]);
            ]);
            ("required", `List [`String "title"]);
          ]);
          ("description", `String "List of tasks to add");
        ]);
      ]);
      ("required", `List [`String "tasks"]);
    ];
  };
  {
    name = "masc_task_history";
    description = "Fetch recent task transition history from event logs. Useful for audits or debugging transitions.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to filter (e.g., 'task-001')");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max events to return (default: 50)");
          ("default", `Int 50);
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    name = "masc_tasks";
    description = "List tasks in backlog with their status and assignee. \
Defaults to active tasks (todo/claimed/in_progress). \
Use include_done/include_cancelled or status to filter. \
Output includes task ID, title, priority, assignee, timestamps. \
Tip: Look for status='todo' tasks to claim.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional status filter: todo|claimed|in_progress|done|cancelled");
        ]);
        ("include_done", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include done tasks (default: false)");
          ("default", `Bool false);
        ]);
        ("include_cancelled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include cancelled tasks (default: false)");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };
  {
    name = "masc_archive_view";
    description = "View archived tasks from tasks-archive.json. Shows tasks that were completed and cleaned up by gc.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max number of archived tasks to show (default: 20)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_claim_next";
    description = "Automatically claim the highest priority unclaimed task. Use this when you want to pick up the most important available work without manually checking the task board. Returns the claimed task details including priority level.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_update_priority";
    description = "Change the priority of a task. Priority 1 is highest (most urgent), 5 is lowest. Use this to reprioritize work based on new information or urgency changes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to update");
        ]);
        ("priority", `Assoc [
          ("type", `String "integer");
          ("description", `String "New priority (1=highest, 5=lowest)");
          ("minimum", `Int 1);
          ("maximum", `Int 5);
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "priority"]);
    ];
  };

  (* masc_transition *)
  {
    name = "masc_transition";
    description = "Move a task through its lifecycle: claim, start, done, cancel, or release. \
Call when you pick up, finish, or abandon a task. Supports CAS via expected_version. \
After masc_add_task or masc_claim_next; pair with masc_deliver before action='done'.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID (e.g., 'task-001')");
        ]);
        ("action", `Assoc [
          ("type", `String "string");
          ("description", `String "Transition action: claim | start | done | cancel | release");
        ]);
        ("expected_version", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional CAS guard (current backlog.version). Transition fails if mismatched");
        ]);
        ("notes", `Assoc [
          ("type", `String "string");
          ("description", `String "Completion notes (used with action='done')");
        ]);
        ("completion_contract", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [ ("type", `String "string") ]);
          ("description", `String "Optional acceptance checklist that completion notes must satisfy before action='done' is accepted");
        ]);
        ("evaluator_cascade", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional evaluator cascade override for anti-rationalization review. Default: cross_verifier");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Cancellation reason (used with action='cancel')");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "action"]);
    ];
  };

]

(* Dispatch function *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_add_task" -> Some (handle_add_task ctx args)
  | "masc_batch_add_tasks" -> Some (handle_batch_add_tasks ctx args)
  | "masc_claim_next" -> Some (handle_claim_next ctx args)
  | "masc_transition" -> Some (handle_transition ctx args)
  | "masc_update_priority" -> Some (handle_update_priority ctx args)
  | "masc_tasks" -> Some (handle_tasks ctx args)
  | "masc_task_history" -> Some (handle_task_history ctx args)
  | "masc_archive_view" -> Some (handle_archive_view ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only = [ "masc_task_history"; "masc_tasks" ]
let _tool_spec_requires_join = [ "masc_add_task"; "masc_claim_next"; "masc_transition" ]

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_task
           ~input_schema:s.input_schema
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ()))
    schemas
