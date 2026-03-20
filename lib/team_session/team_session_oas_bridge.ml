(** Team_session_oas_bridge — Bridge between MASC team session and OAS Swarm.

    Phase C-1 of MASC->OAS migration.
    Lossy projections:
    - planned_worker (24 fields) -> agent_entry (4 fields)
    - session (47 fields) -> swarm_config (12 fields)

    @since 2.124.0 *)

module Swarm = Agent_sdk_swarm
module Oas = Agent_sdk

(* ── Role mapping ──────────────────────────────────────────────── *)

let role_of_worker_class : Team_session_types.worker_class option -> Swarm.Swarm_types.agent_role =
  function
  | Some Team_session_types.Worker_manager -> Custom_role "manager"
  | Some Team_session_types.Worker_executor -> Execute
  | Some Team_session_types.Worker_scout -> Discover
  | Some Team_session_types.Worker_librarian -> Summarize
  | Some Team_session_types.Worker_metacog -> Verify
  | None -> Execute

let role_of_spawn_role
    ~(worker_class : Team_session_types.worker_class option)
    (role_opt : string option) : Swarm.Swarm_types.agent_role =
  match role_opt with
  | Some r when String.lowercase_ascii r = "verify" -> Verify
  | Some r when String.lowercase_ascii r = "review" -> Verify
  | Some r when String.lowercase_ascii r = "discover" -> Discover
  | Some r when String.lowercase_ascii r = "plan" -> Discover
  | Some r when String.lowercase_ascii r = "summarize" -> Summarize
  | Some r when String.lowercase_ascii r = "summary" -> Summarize
  | Some r when String.lowercase_ascii r = "execute" -> Execute
  | Some r when r <> "" -> Custom_role r
  | Some _ | None -> role_of_worker_class worker_class

(* ── Orchestration mode ────────────────────────────────────────── *)

let mode_of_orchestration
    (m : Team_session_types.orchestration_mode) : Swarm.Swarm_types.orchestration_mode =
  match m with
  | Manual -> Supervisor
  | Assist -> Supervisor
  | Auto -> Decentralized

(* ── Cascade name resolution ───────────────────────────────────── *)

let cascade_of_worker
    ~(session_cascade : string list)
    (pw : Team_session_types.planned_worker) : string =
  match pw.spawn_model with
  | Some m when m <> "" -> m
  | _ ->
    match session_cascade with
    | first :: _ when first <> "" -> first
    | _ -> "keeper_turn"

(* ── planned_worker -> agent_entry ─────────────────────────────── *)

let planned_worker_to_entry
    ~(config : Room.config)
    ~(session_cascade : string list)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    (pw : Team_session_types.planned_worker)
  : Swarm.Swarm_types.agent_entry =
  let name = pw.spawn_agent in
  let role = role_of_spawn_role ~worker_class:pw.worker_class pw.spawn_role in
  let cascade_name = cascade_of_worker ~session_cascade pw in
  let max_turns = Option.value ~default:10 pw.max_turns in
  let system_prompt =
    Printf.sprintf "You are agent '%s' in a team session (room: %s). Your role: %s."
      name config.base_path
      (match pw.spawn_role with Some r -> r | None -> "execute")
  in
  let run ~sw:_ prompt =
    match
      Oas_worker.run_named_with_masc_tools
        ~cascade_name ~goal:prompt ~system_prompt
        ~masc_tools ~dispatch ~max_turns
        ~temperature:0.3 ~max_tokens:4096 ()
    with
    | Ok result -> Ok result.response
    | Error e ->
      Error (Oas.Error.Config
        (Oas.Error.InvalidConfig {
          field = "worker"; detail = Printf.sprintf "%s: %s" name e }))
  in
  { name; run; role; get_telemetry = None }

(* ── session -> swarm_config ───────────────────────────────────── *)

let session_to_swarm_config
    ~(config : Room.config)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    (session : Team_session_types.session)
  : Swarm.Swarm_types.swarm_config =
  let entries =
    List.map
      (planned_worker_to_entry ~config
         ~session_cascade:session.model_cascade ~masc_tools ~dispatch)
      session.planned_workers
  in
  let mode = mode_of_orchestration session.orchestration_mode in
  let collaboration =
    Team_context.collaboration_of_session ~base_path:config.base_path session
  in
  let timeout_sec =
    if session.duration_seconds > 0 then
      Some (float_of_int session.duration_seconds)
    else None
  in
  { entries; mode; convergence = None;
    max_parallel = max 1 (List.length entries);
    prompt = session.goal; timeout_sec;
    budget = Swarm.Swarm_types.no_budget;
    max_agent_retries = 1;
    collaboration = Some collaboration;
    resource_check = None;
    max_concurrent_agents = None }

(* ── Inverse: swarm result -> session update ───────────────────── *)

let apply_swarm_result
    (session : Team_session_types.session)
    (result : Swarm.Swarm_types.swarm_result)
  : Team_session_types.session =
  let final_status =
    if result.converged then Team_session_types.Completed
    else Team_session_types.Failed
  in
  let now = Time_compat.now () in
  { session with
    status = final_status;
    turn_count = session.turn_count +
      List.fold_left (fun acc (r : Swarm.Swarm_types.iteration_record) ->
        acc + List.length r.agent_results) 0 result.iterations;
    stopped_at = Some now;
    last_event_at = Some now;
    updated_at_iso = Types.now_iso ();
    stop_reason =
      Some (if result.converged then "swarm_converged"
            else "swarm_exhausted") }
