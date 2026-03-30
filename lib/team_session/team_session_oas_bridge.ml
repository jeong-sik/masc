(** Team_session_oas_bridge — Bridge between MASC team session and OAS Swarm.

    Phase C-1 of MASC->OAS migration.
    Lossy projections:
    - planned_worker (24 fields) -> agent_entry (4 fields)
    - session (47 fields) -> swarm_config (12 fields)

    @since 2.124.0 *)

module Swarm = Agent_sdk_swarm
module Oas = Agent_sdk

let supported_local_worker_tool_names =
  [
    "masc_status";
    "masc_tasks";
    "masc_claim_next";
    "masc_transition";
    "masc_add_task";
    "masc_heartbeat";
    "masc_board_post";
    "masc_board_list";
    "masc_board_get";
    "masc_board_comment";
    "masc_board_vote";
    "masc_board_search";
    "masc_code_search";
    "masc_code_symbols";
    "masc_code_read";
    "masc_worktree_create";
    "masc_worktree_remove";
    "masc_worktree_list";
    "masc_run_init";
    "masc_run_plan";
    "masc_run_log";
    "masc_run_deliverable";
    "masc_run_get";
    "masc_run_list";
    "masc_repair_loop_start";
    "masc_repair_loop_status";
    "masc_repair_loop_iterate";
    "masc_repair_loop_stop";
  ]

let supported_local_worker_tools () =
  match
    Agent_tool_surfaces.local_worker_tool_schemas
      ~names:supported_local_worker_tool_names ()
  with
  | Ok schemas -> Ok schemas
  | Error msg ->
      Error
        (Printf.sprintf
           "team_session_oas_bridge: failed to resolve worker tool schemas: %s"
           msg)

let add_string_field_if_missing key value fields =
  if String.trim value = "" || List.mem_assoc key fields then fields
  else (key, `String value) :: fields

let normalize_tool_args ~tool_name ~(agent_name : string) (args : Yojson.Safe.t)
    : Yojson.Safe.t =
  match args with
  | `Assoc fields ->
      let fields = add_string_field_if_missing "agent_name" agent_name fields in
      let fields =
        match tool_name with
        | "masc_board_post" | "masc_board_comment" ->
            add_string_field_if_missing "author" agent_name fields
        | "masc_board_vote" ->
            add_string_field_if_missing "voter" agent_name fields
        | _ -> fields
      in
      `Assoc fields
  | _ -> args

let string_field key (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> None)
  | _ -> None

let result_of_option ~tool_name = function
  | Some result -> result
  | None ->
      ( false,
        Printf.sprintf "team-session OAS runtime does not support tool '%s'"
          tool_name )

let tool_requires_presence = function
  | "masc_claim_next"
  | "masc_transition"
  | "masc_heartbeat"
  | "masc_worktree_create"
  | "masc_worktree_remove" ->
      true
  | _ -> false

let ensure_agent_joined ~(config : Room.config) ~(agent_name : string) =
  try
    if not (Room.is_initialized config) then (
      let (_init_msg : string) = Room.init config ~agent_name:None in ());
    let joined =
      try Room.is_agent_joined config ~agent_name
      with Sys_error _ | Not_found | Yojson.Json_error _ -> false
    in
    if not joined then ignore (Room.join config ~agent_name ~capabilities:[] ());
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printexc.to_string exn)

let dispatch_supported_tool ~sw ~(clock : _ Eio.Time.clock) ~(config : Room.config)
    ~(name : string) ~(args : Yojson.Safe.t) : bool * string =
  let agent_name =
    match string_field "agent_name" args with
    | Some agent_name -> agent_name
    | None ->
        (match string_field "author" args with
         | Some author -> author
         | None -> "team-session-worker")
  in
  let dispatch_impl () =
    match name with
    | "masc_status" ->
        result_of_option ~tool_name:name
          (Tool_room.dispatch { Tool_room.config = config; agent_name } ~name
             ~args)
    | "masc_tasks" | "masc_claim_next" | "masc_transition" | "masc_add_task"
      ->
        result_of_option ~tool_name:name
          (Tool_task.dispatch
             { Tool_task.config = config; agent_name; sw = Some sw }
             ~name ~args)
    | "masc_code_search" | "masc_code_symbols" | "masc_code_read" ->
        result_of_option ~tool_name:name
          (Tool_code.dispatch { Tool_code.config = config; agent_name } ~name
             ~args)
    | "masc_worktree_create" | "masc_worktree_remove" | "masc_worktree_list"
      ->
        result_of_option ~tool_name:name
          (Tool_worktree.dispatch
             { Tool_worktree.config = config; agent_name }
             ~name
             ~args)
    | "masc_run_init" | "masc_run_plan" | "masc_run_log"
    | "masc_run_deliverable" | "masc_run_get" | "masc_run_list" ->
        result_of_option ~tool_name:name
          (Tool_run.dispatch { Tool_run.config = config } ~name ~args)
    | "masc_repair_loop_start" | "masc_repair_loop_status"
    | "masc_repair_loop_iterate" | "masc_repair_loop_stop" ->
        let repair_ctx : _ Tool_repair_loop_types.context =
          { config; agent_name; sw = Some sw; clock = Some clock; proc_mgr = None }
        in
        result_of_option ~tool_name:name
          (Tool_repair_loop.dispatch repair_ctx ~name ~args)
    | "masc_heartbeat" ->
        result_of_option ~tool_name:name
          (Tool_heartbeat.dispatch
             { Tool_heartbeat.config = config; agent_name; sw; clock }
             ~name ~args)
    | "masc_board_post" | "masc_board_list" | "masc_board_get"
    | "masc_board_comment" | "masc_board_vote" | "masc_board_search" ->
        Tool_board.handle_tool name args
    | _ ->
        ( false,
          Printf.sprintf "team-session OAS runtime does not support tool '%s'"
            name )
  in
  if tool_requires_presence name then
    match ensure_agent_joined ~config ~agent_name with
    | Ok () -> dispatch_impl ()
    | Error msg ->
        ( false,
          Printf.sprintf "failed to prepare room presence for %s: %s" agent_name
            msg )
  else
    dispatch_impl ()

let parse_tool_json body =
  try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None

let repair_loop_status_of_body body =
  match parse_tool_json body with
  | Some json -> Tool_repair_loop_types.status_of_json json
  | None -> None

let run_repair_loop_until_terminal_with
    ~(dispatch_tool : name:string -> args:Yojson.Safe.t -> bool * string)
    (start_args : Yojson.Safe.t) : bool * string =
  let started_ok, started_body =
    dispatch_tool ~name:"masc_repair_loop_start" ~args:start_args
  in
  match parse_tool_json started_body with
  | None -> (started_ok, started_body)
  | Some started_json -> (
      match Yojson.Safe.Util.member "loop_id" started_json with
      | `String loop_id ->
          let rec loop last_ok last_body =
            match repair_loop_status_of_body last_body with
            | Some status when Tool_repair_loop_types.is_terminal_status status ->
                (last_ok, last_body)
            | Some _ ->
                let iterate_ok, iterate_body =
                  dispatch_tool ~name:"masc_repair_loop_iterate"
                    ~args:(`Assoc [ ("loop_id", `String loop_id) ])
                in
                if not iterate_ok && Option.is_none (parse_tool_json iterate_body) then
                  (iterate_ok, iterate_body)
                else
                  loop iterate_ok iterate_body
            | None -> (last_ok, last_body)
          in
          loop started_ok started_body
      | _ -> (started_ok, started_body))

let run_repair_loop_until_terminal ~sw ~(clock : _ Eio.Time.clock)
    ~(config : Room.config) args =
  run_repair_loop_until_terminal_with
    ~dispatch_tool:(fun ~name ~args ->
      dispatch_supported_tool ~sw ~clock ~config ~name ~args)
    args

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

let telemetry_of_run_result (result : Oas_worker.run_result) :
    Swarm.Swarm_types.agent_telemetry =
  {
    Swarm.Swarm_types.trace_ref = result.trace_ref;
    usage = Option.map (Oas.Types.add_usage Oas.Types.empty_usage) result.response.usage;
    turn_count = max 1 result.turns;
  }

let create_team_session_raw_trace ~(config : Room.config) ~(session_id : string)
    ~(agent_name : string) : Oas.Raw_trace.t option =
  match
    Oas.Raw_trace.create_for_session
      ~session_root:(Worker_container.oas_trace_session_root ~base_path:config.base_path)
      ~session_id ~agent_name ()
  with
  | Ok raw_trace -> Some raw_trace
  | Error err ->
      Log.Session.warn "team_session_oas_bridge: raw trace disabled for %s: %s"
        agent_name (Oas.Error.to_string err);
      None

let trace_ref_to_json (trace_ref : Oas.Raw_trace.run_ref) =
  `Assoc
    [
      ("worker_run_id", `String trace_ref.worker_run_id);
      ("path", `String trace_ref.path);
      ("start_seq", `Int trace_ref.start_seq);
      ("end_seq", `Int trace_ref.end_seq);
      ("agent_name", `String trace_ref.agent_name);
      ( "session_id",
        match trace_ref.session_id with
        | Some session_id -> `String session_id
        | None -> `Null );
    ]

let preview_text text =
  String.sub text 0 (min 200 (String.length text))

let preview_text_opt text =
  let trimmed = String.trim text in
  if trimmed = "" then None else Some (preview_text trimmed)

let proof_result_status_to_string = function
  | Oas.Cdal_proof.Completed -> "completed"
  | Oas.Cdal_proof.Errored -> "errored"
  | Oas.Cdal_proof.Timed_out -> "timed_out"
  | Oas.Cdal_proof.Cancelled -> "cancelled"

let worker_name_of_planned_worker ~(fallback : string)
    (pw : Team_session_types.planned_worker) =
  match pw.runtime_actor with
  | Some actor when String.trim actor <> "" -> String.trim actor
  | _ -> fallback

let is_safe_worker_run_id value =
  let len = String.length value in
  len > 0
  && len <= 128
  && String.for_all
       (function
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       value

let persist_worker_run_proof_if_present ~(config : Room.config)
    ~(session_id : string)
    ~(fallback_name : string)
    ~(planned_worker : Team_session_types.planned_worker)
    ~(resolved_model : string option)
    ~(trace_ref : Oas.Raw_trace.run_ref option)
    ~(success : bool)
    ~(output_preview : string option)
    ~(error : string option)
    (proof_opt : Oas.Cdal_proof.t option) =
  match proof_opt with
  | None -> ()
  | Some proof ->
      if not (is_safe_worker_run_id proof.run_id) then
        Log.Session.warn
          "team_session_oas_bridge: skipping proof persistence for unsafe worker run id %S"
          proof.run_id
      else
        let worker_run_id = proof.run_id in
        let worker_name =
          worker_name_of_planned_worker ~fallback:fallback_name planned_worker
        in
        let proof_path =
          Team_session_store.worker_run_proof_path config session_id worker_run_id
        in
        Team_session_store.save_worker_run_proof_json config session_id
          worker_run_id (Oas.Cdal_proof.to_json proof);
        Team_session_store.save_worker_run_meta_json config session_id
          worker_run_id
          (`Assoc
            [
              ("worker_run_id", `String worker_run_id);
              ("worker_name", `String worker_name);
              ("mode", `String "swarm");
              ("status", `String (if success then "completed" else "failed"));
              ("wait_mode", `String "background");
              ( "trace_capability",
                `String
                  (if Option.is_some trace_ref then "raw" else "summary_only")
              );
              ("success", `Bool success);
              ( "execution_scope",
                Option.fold ~none:`Null
                  ~some:(fun scope ->
                    `String
                      (Team_session_types.execution_scope_to_string scope))
                  planned_worker.execution_scope );
              ( "requested_worker_class",
                Option.fold ~none:`Null
                  ~some:(fun kind ->
                    `String
                      (Team_session_types.worker_class_to_string kind))
                  planned_worker.worker_class );
              ("requested_worker_size", `Null);
              ("resolved_runtime", `String "oas_swarm");
              ( "resolved_model",
                Option.fold ~none:`Null ~some:(fun value -> `String value)
                  resolved_model );
              ( "routing_reason",
                Option.fold ~none:`Null ~some:(fun value -> `String value)
                  planned_worker.routing_reason );
              ( "output_preview",
                Option.fold ~none:`Null ~some:(fun value -> `String value)
                  output_preview );
              ("error", Option.fold ~none:`Null ~some:(fun value -> `String value) error);
              ( "trace_ref",
                Option.fold ~none:`Null ~some:trace_ref_to_json trace_ref );
              ("trace_summary", `Null);
              ("trace_validation", `Null);
              ("evidence_session_id", `Null);
              ("oas_worker_run", `Null);
              ("session_conformance", `Null);
              ("validated", `Null);
              ("final_text", Option.fold ~none:`Null ~some:(fun value -> `String value) output_preview);
              ("stop_reason", `Null);
              ("failure_reason", Option.fold ~none:`Null ~some:(fun value -> `String value) error);
              ("ts_iso", `String (Types.now_iso ()));
              ("cdal_run_id", `String proof.run_id);
              ("contract_id", `String proof.contract_id);
              ( "requested_execution_mode",
                `String
                  (Oas.Execution_mode.to_string proof.requested_execution_mode)
              );
              ( "effective_execution_mode",
                `String
                  (Oas.Execution_mode.to_string proof.effective_execution_mode)
              );
              ("risk_class", `String (Oas.Risk_class.to_string proof.risk_class));
              ("result_status", `String (proof_result_status_to_string proof.result_status));
              ( "tool_trace_refs",
                `List
                  (List.map (fun ref_ -> `String ref_) proof.tool_trace_refs)
              );
              ( "raw_evidence_refs",
                `List
                  (List.map (fun ref_ -> `String ref_) proof.raw_evidence_refs)
              );
              ( "checkpoint_ref",
                Option.fold ~none:`Null ~some:(fun ref_ -> `String ref_)
                  proof.checkpoint_ref );
              ("proof_path", `String proof_path);
              ("proof_present", `Bool true);
            ])

let make_convergence_metric ~(entry_count : int)
    (success_by_agent : (string, bool) Hashtbl.t) :
    Swarm.Swarm_types.convergence_config option =
  if entry_count <= 0 then None
  else
    Some
      {
        Swarm.Swarm_types.metric =
          Callback
            (fun () ->
              let successes =
                Hashtbl.fold
                  (fun _ succeeded acc -> if succeeded then acc + 1 else acc)
                  success_by_agent 0
              in
              float_of_int successes /. float_of_int entry_count);
        target = 1.0;
        max_iterations = 1;
        patience = 1;
        aggregate = Best_score;
      }

let budget_of_session_timeout timeout_sec =
  match timeout_sec with
  | Some seconds ->
      {
        Swarm.Swarm_types.no_budget with
        max_total_time_sec = Some seconds;
      }
  | None -> Swarm.Swarm_types.no_budget

let session_runtime_health_check ~(config : Room.config)
    ~(session : Team_session_types.session) () =
  let base_path_ok =
    String.trim config.base_path <> "" && Sys.file_exists config.base_path
  in
  let room_ready = Room.is_initialized config in
  let session_ready =
    match Team_session_store.load_session config session.session_id with
    | Some current ->
        current.status = Team_session_types.Running
        && String.equal current.session_id session.session_id
        && String.equal current.room_id session.room_id
    | None -> false
  in
  base_path_ok && room_ready && session_ready

(* ── planned_worker -> agent_entry ─────────────────────────────── *)

let planned_worker_to_entry_with_state
    ~(config : Room.config)
    ~(session_id : string)
    ~(session_cascade : string list)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ~(success_by_agent : (string, bool) Hashtbl.t)
    ?(delivery_contract : Team_session_types.delivery_contract option)
    (pw : Team_session_types.planned_worker)
  : Swarm.Swarm_types.agent_entry =
  let name = pw.spawn_agent in
  let role = role_of_spawn_role ~worker_class:pw.worker_class pw.spawn_role in
  let cascade_name = cascade_of_worker ~session_cascade pw in
  let max_turns = Option.value ~default:10 pw.max_turns in
  let telemetry_ref = ref Swarm.Swarm_types.empty_telemetry in
  let system_prompt =
    Printf.sprintf "You are agent '%s' in a team session (room: %s). Your role: %s."
      name config.base_path
      (match pw.spawn_role with Some r -> r | None -> "execute")
  in
  let run ~sw prompt =
    let raw_trace =
      create_team_session_raw_trace ~config ~session_id ~agent_name:name
    in
    let proof_ref = ref None in
    let dispatch_with_defaults ~name:(tool_name : string) ~(args : Yojson.Safe.t)
      =
      dispatch ~name:tool_name
        ~args:(normalize_tool_args ~tool_name ~agent_name:name args)
    in
    let contract = Option.map (fun dc ->
      let tool_names = List.map (fun (t : Types.tool_schema) -> t.name) masc_tools in
      Contract_composer.compose ~delivery_contract:dc ~tool_names
    ) delivery_contract in
    match
      Oas_worker.run_named_with_masc_tools
        ~cascade_name ~goal:prompt ~system_prompt
        ~masc_tools ~dispatch:dispatch_with_defaults ~max_turns
        ~temperature:(Cascade_inference.resolve_temperature
          ~cascade_name ~fallback:(fun () -> 0.3))
        ~max_tokens:(Cascade_inference.resolve_max_tokens
          ~cascade_name ~fallback:(fun () -> 4096))
        ?raw_trace ~proof_ref ?contract ~sw
        ~priority:Llm_provider.Request_priority.Proactive ()
    with
    | Ok result ->
        Hashtbl.replace success_by_agent name true;
        telemetry_ref := telemetry_of_run_result result;
        let output_preview =
          Oas.Types.text_of_content result.response.content |> preview_text_opt
        in
        let proof_opt =
          match result.proof with Some _ as proof -> proof | None -> !proof_ref
        in
        persist_worker_run_proof_if_present ~config ~session_id
          ~fallback_name:name ~planned_worker:pw
          ~resolved_model:(Some result.response.model)
          ~trace_ref:result.trace_ref ~success:true ~output_preview
          ~error:None proof_opt;
        Ok result.response
    | Error e ->
        Hashtbl.replace success_by_agent name false;
        telemetry_ref := Swarm.Swarm_types.empty_telemetry;
        persist_worker_run_proof_if_present ~config ~session_id
          ~fallback_name:name ~planned_worker:pw ~resolved_model:None
          ~trace_ref:None ~success:false
          ~output_preview:(preview_text_opt e) ~error:(Some e) !proof_ref;
        Error
          (Oas.Error.Config
             (Oas.Error.InvalidConfig
                { field = "worker"; detail = Printf.sprintf "%s: %s" name e }))
  in
  { name; run; role; get_telemetry = Some (fun () -> !telemetry_ref); extensions = [] }

let planned_worker_to_entry
    ~(config : Room.config)
    ~(session_id : string)
    ~(session_cascade : string list)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    (pw : Team_session_types.planned_worker)
  : Swarm.Swarm_types.agent_entry =
  let success_by_agent = Hashtbl.create 1 in
  planned_worker_to_entry_with_state ~config ~session_id ~session_cascade ~masc_tools
    ~dispatch ~success_by_agent ?delivery_contract:None pw

(* ── session -> swarm_config ───────────────────────────────────── *)

let session_to_swarm_config
    ~(config : Room.config)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    (session : Team_session_types.session)
  : Swarm.Swarm_types.swarm_config =
  let success_by_agent = Hashtbl.create 8 in
  let entries =
    List.map
      (planned_worker_to_entry_with_state ~config ~session_id:session.session_id
         ~session_cascade:session.model_cascade ~masc_tools ~dispatch
         ~success_by_agent ?delivery_contract:session.delivery_contract)
      session.planned_workers
  in
  List.iter
    (fun (entry : Swarm.Swarm_types.agent_entry) ->
      Hashtbl.replace success_by_agent entry.name false)
    entries;
  let mode = mode_of_orchestration session.orchestration_mode in
  let collaboration =
    Team_context.collaboration_of_session ~base_path:config.base_path session
  in
  let entry_count = List.length entries in
  let timeout_sec =
    if session.duration_seconds > 0 then
      Some (float_of_int session.duration_seconds)
    else None
  in
  { entries; mode;
    convergence = make_convergence_metric ~entry_count success_by_agent;
    max_parallel = max 1 (List.length entries);
    prompt = session.goal; timeout_sec;
    budget = budget_of_session_timeout timeout_sec;
    max_agent_retries = 1;
    collaboration = Some collaboration;
    resource_check = Some (session_runtime_health_check ~config ~session);
    max_concurrent_agents = Some (max 1 (List.length entries));
    enable_streaming = false }

(* ── Inverse: swarm result -> session update ───────────────────── *)

let final_outcome_of_swarm_result
    (result : Swarm.Swarm_types.swarm_result)
  : Team_session_types.session_status * string =
  if result.converged then
    (Team_session_types.Completed, "swarm_converged")
  else
    let last_agent_results =
      match List.rev result.iterations with
      | [] -> []
      | last :: _ -> last.agent_results
    in
    let success_count, error_count =
      List.fold_left
        (fun (successes, errors) (_, status) ->
          match status with
          | Swarm.Swarm_types.Done_ok _ -> (successes + 1, errors)
          | Swarm.Swarm_types.Done_error _ -> (successes, errors + 1)
          | Swarm.Swarm_types.Idle | Swarm.Swarm_types.Working ->
              (successes, errors))
        (0, 0) last_agent_results
    in
    if success_count > 0 then
      (Team_session_types.Interrupted, "swarm_partial_completion")
    else if error_count > 0 then
      (Team_session_types.Failed, "swarm_all_agents_failed")
    else
      (Team_session_types.Failed, "swarm_exhausted")

let apply_swarm_result
    (session : Team_session_types.session)
    (result : Swarm.Swarm_types.swarm_result)
  : Team_session_types.session =
  let final_status, stop_reason = final_outcome_of_swarm_result result in
  let now = Time_compat.now () in
  { session with
    status = final_status;
    turn_count = session.turn_count +
      List.fold_left (fun acc (r : Swarm.Swarm_types.iteration_record) ->
        acc + List.length r.agent_results) 0 result.iterations;
    stopped_at = Some now;
    last_event_at = Some now;
    updated_at_iso = Types.now_iso ();
    stop_reason = Some stop_reason }
