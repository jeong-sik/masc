(** Team_session_oas_bridge — Bridge between MASC team session and OAS Swarm.

    Phase C-1 of MASC->OAS migration.
    Lossy projections:
    - planned_worker (24 fields) -> agent_entry (4 fields)
    - session (47 fields) -> swarm_config (12 fields)

    @since 2.124.0 *)

let supported_local_worker_tool_names =
  Tool_catalog.tools_for_surface Tool_catalog.Local_worker

let observe_only_policy : Tool_access_policy.t =
  {
    allow = Surface Tool_catalog.Local_worker;
    deny = Names [
      "masc_add_task";
      "masc_claim_next";
      "masc_transition";
      "masc_board_post";
      "masc_board_comment";
      "masc_board_vote";
      "masc_worktree_create";
      "masc_worktree_remove";
      "masc_run_init";
      "masc_run_plan";
      "masc_run_log";
      "masc_run_deliverable";
      "masc_repair_loop_start";
      "masc_repair_loop_iterate";
      "masc_repair_loop_stop";
    ];
  }

let supported_local_worker_tool_names_for_scope execution_scope =
  match execution_scope with
  | Some Team_session_types.Observe_only ->
      Tool_access_policy.resolve observe_only_policy
  | Some Team_session_types.Limited_code_change
  | Some Team_session_types.Autonomous
  | None ->
      supported_local_worker_tool_names

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

let supported_local_worker_tools_for_scope execution_scope =
  match
    Agent_tool_surfaces.local_worker_tool_schemas
      ~names:(supported_local_worker_tool_names_for_scope execution_scope)
      ()
  with
  | Ok schemas -> Ok schemas
  | Error msg ->
      Error
        (Printf.sprintf
           "team_session_oas_bridge: failed to resolve scoped worker tool schemas: %s"
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
  (* Mint token at team-session I/O boundary (Parse, Don't Validate). *)
  match Tool_dispatch.mint_token ~name with
  | Error reason ->
    (false, Printf.sprintf "team-session: unknown tool '%s' (%s)" name reason)
  | Ok _token ->
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

let int_member_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Int value -> Some value
  | `Intlit raw -> int_of_string_opt raw
  | _ -> None

let repair_loop_status_of_body body =
  match parse_tool_json body with
  | Some json -> Tool_repair_loop_types.status_of_json json
  | None -> None

let repair_loop_iteration_budget body =
  match parse_tool_json body with
  | Some json ->
      let attempt_count =
        Option.value ~default:0 (int_member_opt "attempt_count" json)
      in
      let max_attempts =
        Option.value ~default:(max 1 (attempt_count + 1))
          (int_member_opt "max_attempts" json)
      in
      max 1 (min 64 (max_attempts - attempt_count + 1))
  | None -> 16

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
          let rec loop remaining last_ok last_body =
            match repair_loop_status_of_body last_body with
            | Some status when Tool_repair_loop_types.is_terminal_status status ->
                (last_ok, last_body)
            | Some _ when remaining <= 0 ->
                ( false,
                  Printf.sprintf
                    "repair loop iteration guard exceeded for %s" loop_id )
            | Some _ ->
                let iterate_ok, iterate_body =
                  dispatch_tool ~name:"masc_repair_loop_iterate"
                    ~args:(`Assoc [ ("loop_id", `String loop_id) ])
                in
                if not iterate_ok then
                  (iterate_ok, iterate_body)
                else
                  loop (remaining - 1) iterate_ok iterate_body
            | None -> (last_ok, last_body)
          in
          loop (repair_loop_iteration_budget started_body) started_ok started_body
      | _ -> (started_ok, started_body))

let run_repair_loop_until_terminal ~sw ~(clock : _ Eio.Time.clock)
    ~(config : Room.config) args =
  run_repair_loop_until_terminal_with
    ~dispatch_tool:(fun ~name ~args ->
      dispatch_supported_tool ~sw ~clock ~config ~name ~args)
    args

let slot_aware_concurrency_cap ~entry_count ~selection_count ~all_discovered
    ~endpoints_found ~total =
  if entry_count <= 1 || selection_count <= 0 then
    entry_count
  (* Multiple worker selections can legitimately collapse onto one discovered
     local endpoint, so endpoint coverage is not a 1:1 proxy for slot count. *)
  else if all_discovered && endpoints_found > 0 && total > 0 then
    total
  else
    entry_count

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

let proof_result_status_to_string =
  Oas_worker_exec.proof_result_status_to_string

let worker_name_of_planned_worker ~(fallback : string)
    (pw : Team_session_types.planned_worker) =
  match pw.runtime_actor with
  | Some actor when String.trim actor <> "" -> String.trim actor
  | _ -> fallback

let sanitize_worker_run_component value =
  let buf = Buffer.create (String.length value) in
  String.iter
    (function
      | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-') as ch ->
          Buffer.add_char buf ch
      | _ -> ())
    value;
  let sanitized = Buffer.contents buf in
  if sanitized = "" then "worker"
  else if String.length sanitized <= 48 then sanitized
  else String.sub sanitized 0 48

let is_safe_worker_run_id value =
  let len = String.length value in
  len > 0
  && len <= 128
  && value <> "." && value <> ".."
  && String.for_all
       (function
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       value

let fallback_worker_run_id ~(fallback_name : string) =
  Printf.sprintf "swarm-%s-%Ld"
    (sanitize_worker_run_component fallback_name)
    (Int64.of_float (Time_compat.now () *. 1000.0))

let valid_worker_run_id_opt ~(label : string) value_opt =
  match value_opt with
  | Some value when is_safe_worker_run_id value -> Some value
  | Some value ->
      Log.Session.warn
        "team_session_oas_bridge: ignoring unsafe %s %S" label value;
      None
  | None -> None

let worker_run_id_of_artifacts ~(fallback_name : string)
    ~(trace_ref : Oas.Raw_trace.run_ref option)
    (proof_opt : Oas.Cdal_proof.t option) =
  let trace_worker_run_id =
    valid_worker_run_id_opt ~label:"trace_ref.worker_run_id"
      (Option.map
         (fun (trace : Oas.Raw_trace.run_ref) -> trace.worker_run_id)
         trace_ref)
  in
  let proof_run_id =
    valid_worker_run_id_opt ~label:"proof.run_id"
      (Option.map (fun (proof : Oas.Cdal_proof.t) -> proof.run_id) proof_opt)
  in
  match trace_worker_run_id, proof_run_id with
  | Some trace_worker_run_id, Some proof_run_id
    when not (String.equal trace_worker_run_id proof_run_id) ->
      Log.Session.warn
        "team_session_oas_bridge: worker_run_id mismatch trace=%s proof=%s; using trace worker_run_id"
        trace_worker_run_id proof_run_id;
      trace_worker_run_id
  | Some worker_run_id, _ -> worker_run_id
  | None, Some worker_run_id -> worker_run_id
  | None, None -> fallback_worker_run_id ~fallback_name

let persist_worker_run_artifacts ~(config : Room.config)
    ~(session_id : string)
    ~(fallback_name : string)
    ~(planned_worker : Team_session_types.planned_worker)
    ~(resolved_model : string option)
    ~(trace_ref : Oas.Raw_trace.run_ref option)
    ~(success : bool)
    ~(output_preview : string option)
    ~(error : string option)
    (proof_opt : Oas.Cdal_proof.t option) =
  let worker_run_id =
    worker_run_id_of_artifacts ~fallback_name ~trace_ref proof_opt
  in
  let effective_execution_scope =
    Team_session_types.effective_execution_scope_of_planned_worker
      planned_worker
  in
  let tool_surface_masc_names =
    supported_local_worker_tool_names_for_scope
      (Some effective_execution_scope)
    |> Team_session_types.dedup_strings |> List.sort String.compare
  in
  let proof_tool_names =
    match proof_opt with
    | Some proof -> proof.capability_snapshot.tools
    | None -> []
  in
  let tool_surface_names =
    Team_session_types.dedup_strings
      (proof_tool_names @ tool_surface_masc_names)
    |> List.sort String.compare
  in
  let tool_surface_status =
    if tool_surface_names <> [] then `String "available" else `String "missing"
  in
  let tool_surface_source =
    if tool_surface_names <> [] then `String "swarm_masc_tools" else `Null
  in
  let worker_name =
    worker_name_of_planned_worker ~fallback:fallback_name planned_worker
  in
  let proof_fields =
    let null_fields =
      [
        ("cdal_run_id", `Null);
        ("contract_id", `Null);
        ("requested_execution_mode", `Null);
        ("effective_execution_mode", `Null);
        ("risk_class", `Null);
        ("result_status", `Null);
        ("tool_trace_refs", `List []);
        ("raw_evidence_refs", `List []);
        ("checkpoint_ref", `Null);
        ("proof_path", `Null);
        ("proof_present", `Bool false);
        ("proof_run_id", `Null);
        ("proof_status", `Null);
        ("proof_risk_class", `Null);
        ("proof_execution_mode", `Null);
        ("proof_evidence_count", `Null);
      ]
    in
    match proof_opt with
    | Some proof when is_safe_worker_run_id proof.run_id ->
        let proof_path =
          Team_session_store.worker_run_proof_path config session_id worker_run_id
        in
        Team_session_store.save_worker_run_proof_json config session_id
          worker_run_id (Oas.Cdal_proof.to_json proof);
        [
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
          ("proof_run_id", `String proof.run_id);
          ("proof_status", `String (proof_result_status_to_string proof.result_status));
          ("proof_risk_class", `String (Oas.Risk_class.to_string proof.risk_class));
          ( "proof_execution_mode",
            `String
              (Oas.Execution_mode.to_string proof.effective_execution_mode)
          );
          ("proof_evidence_count", `Int (List.length proof.raw_evidence_refs));
        ]
    | Some proof ->
        Log.Session.warn
          "team_session_oas_bridge: skipping proof persistence for unsafe worker run id %S"
          proof.run_id;
        null_fields
    | None -> null_fields
  in
  Team_session_store.save_worker_run_meta_json config session_id
    worker_run_id
    (`Assoc
      ([
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
        ("tool_surface_status", tool_surface_status);
        ("tool_surface_source", tool_surface_source);
        ( "tool_surface_names",
          `List
            (List.map (fun value -> `String value) tool_surface_names)
        );
        ( "tool_surface_masc_names",
          `List
            (List.map
               (fun value -> `String value)
               tool_surface_masc_names) );
        ("tool_surface_shell_names", `List []);
        ( "requested_worker_class",
          Option.fold ~none:`Null
            ~some:(fun kind ->
              `String
                (Team_session_types.worker_class_to_string kind))
            planned_worker.worker_class );
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
      ] @ proof_fields))

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
    ~(team_ctx : Team_context.team_context)
    ?(delivery_contract : Team_session_types.delivery_contract option)
    (pw : Team_session_types.planned_worker)
  : Swarm.Swarm_types.agent_entry =
  let name = pw.spawn_agent in
  let role = role_of_spawn_role ~worker_class:pw.worker_class pw.spawn_role in
  let cascade_name = cascade_of_worker ~session_cascade pw in
  let max_turns = Option.value ~default:10 pw.max_turns in
  let telemetry_ref = ref Swarm.Swarm_types.empty_telemetry in
  let effective_execution_scope =
    Team_session_types.effective_execution_scope_of_planned_worker pw
  in
  let scoped_tool_names =
    supported_local_worker_tool_names_for_scope
      (Some effective_execution_scope)
  in
  let scoped_masc_tools =
    List.filter
      (fun (tool : Types.tool_schema) ->
        List.mem tool.name scoped_tool_names)
      masc_tools
  in
  let system_prompt =
    Prompt_composer.compose [
      Prompt_composer.Identity {
        name;
        role = (match pw.spawn_role with Some r -> r | None -> "execute");
        model = cascade_name;
      };
      Prompt_composer.TeamContext team_ctx;
      Prompt_composer.FreeText
        (Printf.sprintf "Room: %s | Session: %s" config.base_path session_id);
    ]
  in
  (* BM25 progressive tool disclosure: build once, reuse across turns.
     Synonym-enriched descriptions bridge user vocabulary to tool names.
     Benchmark: BM25+synonym recall@5 = 100% (vs 42.9% without filtering). *)
  let tool_index =
    let entries = List.map (fun (t : Types.tool_schema) ->
      let syn = Tool_prefilter.synonym_text t.name in
      let description =
        if syn = "" then t.description
        else t.description ^ " " ^ syn
      in
      (* synonyms remain in description; aliases migration is keeper-specific *)
      Oas.Tool_index.{ name = t.name; description; group = None; aliases = [] }
    ) scoped_masc_tools in
    Oas.Tool_index.build entries
  in
  let all_tool_names =
    List.map (fun (t : Types.tool_schema) -> t.name) scoped_masc_tools
  in
  let progressive_hooks =
    let disclosure = Oas.Progressive_tools.Retrieval_based {
      index = tool_index;
      confidence_threshold = 0.5;
      fallback_tools = all_tool_names;
      always_include = [ "masc_status"; "masc_broadcast" ];
    } in
    { Oas.Hooks.empty with
      before_turn_params = Some (Oas.Progressive_tools.as_hook disclosure) }
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
      let tool_names =
        List.map (fun (t : Types.tool_schema) -> t.name) scoped_masc_tools
      in
      Contract_composer.compose ~delivery_contract:dc
        ~execution_scope:pw.execution_scope ~tool_names
    ) delivery_contract in
    match
      Masc_oas_bridge.run_safe ~timeout_s:180.0 (fun () ->
        Oas_worker.run_named_with_masc_tools
          ~cascade_name ~goal:prompt ~system_prompt
          ~masc_tools:scoped_masc_tools ~dispatch:dispatch_with_defaults
          ~max_turns
          ~hooks:progressive_hooks
          ~temperature:(Cascade_inference.resolve_temperature
            ~cascade_name ~fallback:(fun () -> 0.3))
          ~max_tokens:(Cascade_inference.resolve_max_tokens
            ~cascade_name ~fallback:(fun () -> 4096))
          ?raw_trace ~proof_ref ?contract ~sw
          ()
      )
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
        persist_worker_run_artifacts ~config ~session_id
          ~fallback_name:name ~planned_worker:pw
          ~resolved_model:(Some result.response.model)
          ~trace_ref:result.trace_ref ~success:true ~output_preview
          ~error:None proof_opt;
        Ok result.response
    | Error err ->
        let e_str = Oas.Error.to_string err in
        Hashtbl.replace success_by_agent name false;
        telemetry_ref := Swarm.Swarm_types.empty_telemetry;
        persist_worker_run_artifacts ~config ~session_id
          ~fallback_name:name ~planned_worker:pw ~resolved_model:None
          ~trace_ref:None ~success:false
          ~output_preview:(preview_text_opt e_str) ~error:(Some e_str) !proof_ref;
        Error err
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
  let team_ctx =
    try Team_context.build ~base_path:config.base_path ~team_session_id:session_id
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> Team_context.empty
  in
  planned_worker_to_entry_with_state ~config ~session_id ~session_cascade ~masc_tools
    ~dispatch ~success_by_agent ~team_ctx ?delivery_contract:None pw

(* ── session -> swarm_config ───────────────────────────────────── *)

let session_to_swarm_config
    ~(sw : Eio.Switch.t)
    ~(net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
    ~(config : Room.config)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    (session : Team_session_types.session)
  : Swarm.Swarm_types.swarm_config =
  let success_by_agent = Hashtbl.create 8 in
  let team_ctx =
    try Team_context.build ~base_path:config.base_path
          ~team_session_id:session.session_id
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> Team_context.empty
  in
  let entries =
    List.map
      (planned_worker_to_entry_with_state ~config ~session_id:session.session_id
         ~session_cascade:session.model_cascade ~masc_tools ~dispatch
         ~success_by_agent ~team_ctx ?delivery_contract:session.delivery_contract)
      session.planned_workers
  in
  List.iter
    (fun (entry : Swarm.Swarm_types.agent_entry) ->
      Hashtbl.replace success_by_agent entry.name false)
    entries;
  let mode = mode_of_orchestration session.orchestration_mode in
  let entry_count = List.length entries in
  let timeout_sec =
    if session.duration_seconds > 0 then
      Some (float_of_int session.duration_seconds)
    else None
  in
  (* Slot-aware max_concurrent_agents for local-only sessions *)
  let slot_aware_cap =
    if entry_count <= 1 then
      entry_count
    else
      let all_selections =
        session.planned_workers
        |> List.map (fun pw ->
             cascade_of_worker ~session_cascade:session.model_cascade pw)
        |> List.sort_uniq String.compare
      in
      match all_selections with
      | [] -> entry_count
      | _ ->
          (try
            let capacity =
              Llm_provider.Cascade_config.local_capacity_for_selections ~sw ~net
                all_selections
            in
            slot_aware_concurrency_cap ~entry_count
              ~selection_count:(List.length all_selections)
              ~all_discovered:capacity.all_discovered
              ~endpoints_found:capacity.endpoints_found ~total:capacity.total
          with
          | Eio.Cancel.Cancelled _ as ex -> raise ex
          | ex ->
            Eio.traceln "[swarm] capacity probe failed, using entry_count: %s"
              (Printexc.to_string ex);
            entry_count)
  in
  let collaboration_context = Some (Team_context.to_json team_ctx) in
  { entries; mode;
    convergence = make_convergence_metric ~entry_count success_by_agent;
    max_parallel = max 1 entry_count;
    prompt = session.goal; timeout_sec;
    budget = budget_of_session_timeout timeout_sec;
    max_agent_retries = 1;
    collaboration_context;
    resource_check = Some (session_runtime_health_check ~config ~session);
    max_concurrent_agents = Some (max 1 (min entry_count slot_aware_cap));
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
  let iteration_turns = List.length result.iterations in
  { session with
    status = final_status;
    turn_count = session.turn_count + iteration_turns;
    stopped_at = Some now;
    last_event_at = Some now;
    updated_at_iso = Types.now_iso ();
    stop_reason = Some stop_reason }
