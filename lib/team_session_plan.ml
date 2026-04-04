(** Team_session_plan — bridge from team session state to OAS Plan.t.

    Computes an OAS Plan.t on-demand from session state, mapping
    planned workers to plan steps with appropriate statuses.

    @since Phase 3 — OAS feature adoption *)

let worker_step_id (w : Team_session_types.planned_worker) : string =
  match w.runtime_actor with
  | Some actor when String.trim actor <> "" -> actor
  | _ ->
    Printf.sprintf "%s/%s"
      w.spawn_agent
      (Option.value ~default:"worker" w.spawn_role)

let worker_description (w : Team_session_types.planned_worker) : string =
  let model_part = match w.spawn_model with
    | Some m -> Printf.sprintf " [%s]" m
    | None -> ""
  in
  let role_part = match w.spawn_role with
    | Some r -> Printf.sprintf " (%s)" r
    | None -> ""
  in
  Printf.sprintf "%s%s%s" w.spawn_agent role_part model_part

let step_status_of_worker
    (active_agents : string list)
    (session_status : Team_session_types.session_status)
    (w : Team_session_types.planned_worker) : Oas.Plan.step_status =
  let id = worker_step_id w in
  let is_active = List.exists (fun a -> String.equal a id) active_agents in
  match session_status with
  | Completed -> Done
  | Failed | Cancelled | Interrupted ->
    if is_active then Failed "session terminated"
    else Skipped
  | Running | Paused ->
    if is_active then Running
    else Pending

let of_session (session : Team_session_types.session) : Oas.Plan.t =
  let plan = Oas.Plan.create
    ~goal:session.goal
    ~planner:session.created_by
    ()
  in
  let plan = List.fold_left (fun plan w ->
    Oas.Plan.add_step plan
      ~id:(worker_step_id w)
      ~description:(worker_description w)
      ()
  ) plan session.planned_workers in
  let plan = Oas.Plan.start plan in
  let plan = List.fold_left (fun plan w ->
    let id = worker_step_id w in
    match step_status_of_worker session.agent_names session.status w with
    | Running -> Oas.Plan.start_step plan id
    | Done -> Oas.Plan.complete_step plan id
        ~result:(`Assoc [("status", `String "completed")])
    | Failed reason -> Oas.Plan.fail_step plan id ~reason
    | Skipped -> Oas.Plan.skip_step plan id
    | Pending -> plan
  ) plan session.planned_workers in
  match session.status with
  | Completed -> Oas.Plan.finish plan
  | Cancelled -> Oas.Plan.abandon plan ~reason:"cancelled"
  | Failed -> Oas.Plan.abandon plan ~reason:"failed"
  | Interrupted -> Oas.Plan.abandon plan ~reason:"interrupted"
  | Running | Paused -> plan

let progress (session : Team_session_types.session) : float =
  let plan = of_session session in
  Oas.Plan.progress plan

let to_json (session : Team_session_types.session) : Yojson.Safe.t =
  let plan = of_session session in
  Oas.Plan.to_json plan
