(** Cp_lifecycle_swarm_live core — resolution types, JSON helpers. *)

include Cp_snapshot

let option_to_json f = function
  | Some value -> f value
  | None -> `Null

let swarm_run_resolution_status_of_json json =
  match U.member "status" json with
  | `String ("continued" | "rerun" | "abandoned" as status) -> Some status
  | _ -> None

let read_swarm_run_resolution_json config run_id =
  find_swarm_live_artifact_json config run_id "resolution.json"

let swarm_run_resolution_entry_json ~status ~actor ~reason ?operation_id
    ?detachment_id ?note () =
  `Assoc
    [
      ("status", `String status);
      ("decided_by", `String actor);
      ("decided_at", `String (Types.now_iso ()));
      ("reason", `String reason);
      ("operation_id", option_to_json (fun value -> `String value) operation_id);
      ("detachment_id", option_to_json (fun value -> `String value) detachment_id);
      ("note", option_to_json (fun value -> `String value) note);
    ]

let record_swarm_run_resolution_json config ~run_id ~status ~actor ~reason
    ?operation_id ?detachment_id ?note () =
  let existing =
    match read_swarm_run_resolution_json config run_id with
    | Some (`Assoc _ as json) -> json
    | _ -> `Assoc []
  in
  let entry =
    swarm_run_resolution_entry_json ~status ~actor ~reason ?operation_id
      ?detachment_id ?note ()
  in
  let history =
    match U.member "history" existing with
    | `List rows -> rows @ [ entry ]
    | _ -> [ entry ]
  in
  let payload =
    `Assoc
      [
        ("run_id", `String run_id);
        ("status", `String status);
        ("decided_by", `String actor);
        ("decided_at", `String (Types.now_iso ()));
        ("reason", `String reason);
        ("operation_id", option_to_json (fun value -> `String value) operation_id);
        ("detachment_id", option_to_json (fun value -> `String value) detachment_id);
        ("note", option_to_json (fun value -> `String value) note);
        ("history", `List history);
      ]
  in
  let run_dir = Cp_paths.primary_swarm_live_run_dir config run_id in
  Room_utils.mkdir_p run_dir;
  Room_utils.write_json_local (Cp_paths.swarm_live_resolution_path config run_id)
    payload;
  payload

let task_assignee (task : Types.task) =
  match task.task_status with
  | Types.Claimed { assignee; _ }
  | Types.InProgress { assignee; _ }
  | Types.Done { assignee; _ } -> Some assignee
  | Types.Todo | Types.Cancelled _ -> None

let task_done (task : Types.task) =
  match task.task_status with
  | Types.Done _ -> true
  | _ -> false

type worker_row_ctx = {
  find_agent : string -> Types.agent option;
  task_by_id : (string * Types.task) list;
  effective_run_id : string;
  scoped_tasks : Types.task list;
  recent_messages : Types.message list;
  matching_messages : Types.message list;
  all_tasks : Types.task list;
  matched_squad : unit_record option;
  matched_detachment : detachment_record option;
  find_task_title : string -> string option;
  find_task_status : string -> string option;
}

let build_worker_row (ctx : worker_row_ctx)
    (plan : Agent_swarm_live_harness.worker_plan) =
  let message_contains ~from_agent needle =
    List.exists
      (fun (message : Types.message) ->
        String.equal message.from_agent from_agent
        && string_contains ~needle message.content)
      ctx.matching_messages
  in
  let message_starts_with ~from_agent prefix =
    let prefix_len = String.length prefix in
    List.exists
      (fun (message : Types.message) ->
        String.equal message.from_agent from_agent
        && String.length message.content >= prefix_len
        && String.sub message.content 0 prefix_len = prefix)
      ctx.matching_messages
  in
  let agent = ctx.find_agent plan.name in
  let current_task = Option.bind agent (fun (value : Types.agent) -> value.current_task) in
  let heartbeat_age_sec =
    Option.bind agent (fun (value : Types.agent) -> float_age_seconds value.last_seen)
  in
  let task_matches_run =
    match current_task with
    | Some task_id -> (
        match List.assoc_opt task_id ctx.task_by_id with
        | Some task ->
            value_matches_tokens (run_tokens ctx.effective_run_id) task.title
            || value_matches_tokens [ plan.name ] task.title
        | None -> false)
    | None -> false
  in
  let assigned_task =
    ctx.scoped_tasks
    |> List.find_opt (fun (task : Types.task) ->
           match task_assignee task with
           | Some assignee when String.equal assignee plan.name ->
               value_matches_tokens (run_tokens ctx.effective_run_id) task.title
               || value_matches_tokens [ plan.name ] task.title
           | _ -> false)
  in
  let last_message =
    ctx.recent_messages
    |> List.find_opt (fun (message : Types.message) ->
           String.equal message.from_agent plan.name)
  in
  let claim_marker_seen =
    message_contains ~from_agent:plan.name plan.claim_marker
  in
  let done_marker_seen =
    message_contains ~from_agent:plan.name plan.done_marker
  in
  let final_marker_seen =
    message_starts_with ~from_agent:plan.name plan.final_marker
  in
  let runtime_assisted_final_marker_seen =
    List.exists
      (fun (message : Types.message) ->
        String.equal message.from_agent plan.name
        && string_contains
             ~needle:
               (Printf.sprintf
                  "RUNTIME_ASSISTED_FINAL_MARKER expected=%s"
                  plan.final_marker)
             message.content)
      ctx.matching_messages
  in
  let completed_task =
    if done_marker_seen || final_marker_seen
       || runtime_assisted_final_marker_seen
    then
      ctx.all_tasks
      |> List.find_opt (fun (task : Types.task) ->
             match task_assignee task with
             | Some assignee when String.equal assignee plan.name ->
                 value_matches_tokens (run_tokens ctx.effective_run_id) task.title
             | _ -> false)
    else
      None
  in
  let agent_is_active = match agent with Some a -> a.status = Types.Active | None -> false in
  let joined =
    agent_is_active
    || Option.is_some assigned_task
    || Option.is_some completed_task
    || Option.is_some last_message
    || claim_marker_seen
    || done_marker_seen
    || final_marker_seen
    || runtime_assisted_final_marker_seen
  in
  let task_bound =
    task_matches_run || Option.is_some assigned_task
    || Option.is_some completed_task
  in
  let bound_task_id =
    option_first_some (if task_matches_run then current_task else None)
      (option_first_some
         (Option.map (fun (task : Types.task) -> task.id) assigned_task)
         (Option.map (fun (task : Types.task) -> task.id) completed_task))
  in
  let bound_task_title =
    match bound_task_id with
    | Some value -> ctx.find_task_title value
    | None ->
        option_first_some
          (Option.map (fun (task : Types.task) -> task.title) assigned_task)
          (Option.map (fun (task : Types.task) -> task.title) completed_task)
  in
  let bound_task_status =
    match bound_task_id with
    | Some value -> ctx.find_task_status value
    | None ->
        option_first_some
          (assigned_task
           |> Option.map (fun (task : Types.task) ->
                  Types.string_of_task_status task.task_status))
          (completed_task
           |> Option.map (fun (task : Types.task) ->
                  Types.string_of_task_status task.task_status))
  in
  let completed =
    match option_first_some assigned_task completed_task with
    | Some task -> task_done task
    | None ->
        done_marker_seen
        && (final_marker_seen || runtime_assisted_final_marker_seen)
  in
  let heartbeat_fresh =
    match heartbeat_age_sec with
    | Some age -> age <= Room.heartbeat_timeout_seconds
    | None -> completed
  in
  `Assoc
    [
      ("name", `String plan.name);
      ("role", `String (Agent_swarm_live_harness.string_of_worker_role plan.role));
      ("lane", `String (Agent_swarm_live_harness.string_of_fixture_lane plan.lane));
      ("joined", `Bool joined);
      ("live_presence", `Bool (match agent with Some a -> a.status = Types.Active | None -> false));
      ("completed", `Bool completed);
      ( "status",
        match agent with
        | Some value -> `String (Types.string_of_agent_status value.status)
        | None -> `String "offline" );
      ("current_task", match current_task with Some value -> `String value | None -> `Null);
      ("bound_task_id", match bound_task_id with Some value -> `String value | None -> `Null);
      ("bound_task_title", match bound_task_title with Some value -> `String value | None -> `Null);
      ("bound_task_status", match bound_task_status with Some value -> `String value | None -> `Null);
      ("current_task_matches_run", `Bool task_bound);
      ("squad_member", `Bool (option_exists (fun (unit : unit_record) -> List.mem plan.name unit.roster) ctx.matched_squad));
      ("detachment_member", `Bool (option_exists (fun (detachment : detachment_record) -> List.mem plan.name detachment.roster) ctx.matched_detachment));
      ( "last_seen",
        match agent with
        | Some value -> `String value.last_seen
        | None -> `Null );
      ("heartbeat_age_sec", match heartbeat_age_sec with Some value -> `Float value | None -> `Null);
      ("heartbeat_fresh", `Bool heartbeat_fresh);
      ("claim_marker_seen", `Bool claim_marker_seen);
      ("done_marker_seen", `Bool done_marker_seen);
      ("final_marker_seen", `Bool final_marker_seen);
      ("runtime_assisted_final_marker_seen", `Bool runtime_assisted_final_marker_seen);
      ("claim_marker", `String plan.claim_marker);
      ("done_marker", `String plan.done_marker);
      ("final_marker", `String plan.final_marker);
      ( "last_message",
        match last_message with
        | Some message ->
            `Assoc
              [
                ("seq", `Int message.seq);
                ("content", `String message.content);
                ("timestamp", `String message.timestamp);
              ]
        | None -> `Null );
    ]
