(** Tool_task - Core task CRUD operations

    Handles: add_task, batch_add_tasks, cancel_task, claim, claim_next,
    done, release, task_history, tasks, transition, update_priority, archive_view
*)

open Yojson.Safe.Util

type result = bool * string

type context = {
  config: Room.config;
  agent_name: string;
}

open Tool_args

let result_to_response = function
  | Ok msg -> (true, msg)
  | Error e -> (false, Types.masc_error_to_string e)

(** Validate task_id is non-empty. Prevents phantom operations on empty IDs. *)
let validate_task_id task_id =
  if task_id = "" then Error (Types.TaskNotFound "")
  else Ok task_id

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
  let tasks = List.map (fun t ->
    let title = t |> member "title" |> to_string in
    let priority = t |> member "priority" |> to_int_option |> Option.value ~default:3 in
    let description = t |> member "description" |> to_string_option |> Option.value ~default:"" in
    (title, priority, description)
  ) tasks_json in
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
    | "" -> Agent_identity.Unassigned
    | s -> Agent_identity.role_of_string s
  in
  let result = Room.claim_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ~agent_role () in
  (* Notification harness: push claim event to all active sessions *)
  (match result with
   | Ok _ ->
       Subscriptions.push_event_to_sessions (`Assoc [
         ("type", `String "masc/task_claimed");
         ("task_id", `String task_id);
         ("agent_name", `String ctx.agent_name);
         ("timestamp", `Float (Time_compat.now ()));
       ]);
       (* Audit: log claim event *)
       Audit_log.log_claim_task ctx.config ~agent_id:ctx.agent_name
         ~room_id:(Filename.basename ctx.config.base_path)
         ~task_id ()
   | Error _ -> ());
  result_to_response result

let handle_claim_next ctx _args =
  if not (try Room.is_agent_joined ctx.config ~agent_name:ctx.agent_name with Sys_error _ | Not_found -> false) then
    (false, Printf.sprintf "Agent '%s' is not a member of this room" ctx.agent_name)
  else
  (true, Room.claim_next ctx.config ~agent_name:ctx.agent_name)

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
  let result = Room.complete_task_r ctx.config ~agent_name:ctx.agent_name ~task_id ~notes in
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
        with exn -> Log.Task.error "Metrics_store_eio.record(done) failed: %s" (Printexc.to_string exn));
       (* Feed success into Thompson Sampling quality signal *)
       Lodge_selection.record_vote ~agent_name:ctx.agent_name ~direction:`Up;
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
        with exn -> Log.Task.error "Metrics_store_eio.record(cancel) failed: %s" (Printexc.to_string exn));
       (* Feed failure into Thompson Sampling quality signal *)
       Lodge_selection.record_vote ~agent_name:ctx.agent_name ~direction:`Down;
       (* Prometheus: record task failure *)
       Prometheus.record_task_failed ();
       (* Notification harness: push cancel event to all active sessions *)
       Subscriptions.push_event_to_sessions (`Assoc [
         ("type", `String "masc/task_cancelled");
         ("task_id", `String task_id);
         ("agent_name", `String ctx.agent_name);
         ("reason", `String reason);
         ("timestamp", `Float (Time_compat.now ()));
       ]);
       (* Audit: log cancel event *)
       Audit_log.log_cancel_task ctx.config ~agent_id:ctx.agent_name
         ~room_id:(Filename.basename ctx.config.base_path)
         ~task_id ~reason ()
   | Error err ->
       Log.Task.error "metrics record failed: %s" (Types.masc_error_to_string err));
  result_to_response result

let handle_transition ctx args =
  let task_id = get_string args "task_id" "" in
  match validate_task_id task_id with
  | Error e -> result_to_response (Error e)
  | Ok task_id ->
  let action = get_string args "action" "" in
  let notes = get_string args "notes" "" in
  let reason = get_string args "reason" "" in
  let expected_version = get_int_opt args "expected_version" in
  let action_lc = String.lowercase_ascii action in
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
      Unix.sleepf cas_retry_delay_s;
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
       ]);
       (* Audit: log transition event by action type *)
       let room_id = Filename.basename ctx.config.base_path in
       (match action_lc with
        | "claim" ->
            Audit_log.log_claim_task ctx.config ~agent_id:ctx.agent_name ~room_id ~task_id ()
        | "done" ->
            Audit_log.log_done_task ctx.config ~agent_id:ctx.agent_name ~room_id ~task_id ()
        | "cancel" ->
            Audit_log.log_cancel_task ctx.config ~agent_id:ctx.agent_name ~room_id ~task_id
              ~reason:(if reason = "" then "cancelled" else reason) ()
        | _ -> ())
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
        with exn -> Log.Task.error "Metrics_store_eio.record(transition-done) failed: %s" (Printexc.to_string exn));
       Lodge_selection.record_vote ~agent_name:ctx.agent_name ~direction:`Up;
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
        with exn -> Log.Task.error "Metrics_store_eio.record(transition-cancel) failed: %s" (Printexc.to_string exn));
       Lodge_selection.record_vote ~agent_name:ctx.agent_name ~direction:`Down;
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
