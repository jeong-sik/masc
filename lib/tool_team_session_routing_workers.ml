include Tool_team_session_routing

open Tool_args

let parse_spawn_spec_from_object ?(default_timeout = 300)
    ?top_level_worker_policy batch_index json =
  match find_present_json_key legacy_spawn_fields json with
  | Some field -> Error (legacy_spawn_field_error ~batch_index field)
  | None ->
  let open Yojson.Safe.Util in
  let get_required_string key =
    match member key json with
    | `String s ->
        let trimmed = String.trim s in
        if trimmed = "" then
          Error
            (Printf.sprintf "spawn_batch[%d].%s is required" batch_index key)
        else
          Ok trimmed
    | _ ->
        Error
          (Printf.sprintf "spawn_batch[%d].%s is required" batch_index key)
  in
  let get_optional_string key =
    match member key json with
    | `String s ->
        let trimmed = String.trim s in
        if trimmed = "" then None else Some trimmed
    | _ -> None
  in
  let get_optional_string_list key =
    match member key json with
    | `List xs ->
        xs
        |> List.filter_map (function
               | `String s ->
                   let trimmed = String.trim s in
                   if trimmed = "" then None else Some trimmed
               | _ -> None)
        |> normalize_artifact_scope
    | _ -> []
  in
  let get_optional_worker_class key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.worker_class_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_execution_scope key =
    Option.map
      Team_session_types.execution_scope_of_string
      (get_optional_string key)
  in
  let get_optional_task_profile key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.task_profile_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_risk_level key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.risk_level_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_capsule_mode key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.capsule_mode_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_control_domain key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.control_domain_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_float key =
    match member key json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | `Intlit raw -> (try Some (float_of_string raw) with Failure _ -> None)
    | _ -> None
  in
  let get_timeout key =
    match member key json with
    | `Int n -> max 1 n
    | `Intlit s -> (try max 1 (int_of_string s) with Failure _ -> default_timeout)
    | _ -> default_timeout
  in
  let worker_policy =
    match member "worker_policy" json with
    | `Assoc _ as obj -> Some obj
    | _ -> None
  in
  let policy_json key =
    let lookup = function
      | Some obj -> (
          match member key obj with
          | `Null -> None
          | value -> Some value)
      | None -> None
    in
    match lookup worker_policy with
    | Some value -> Some value
    | None -> lookup top_level_worker_policy
  in
  let policy_bool key =
    match policy_json key with
    | Some value -> (
        match value with
        | `Bool value -> Some value
        | _ -> None)
    | None -> None
  in
  let policy_int key =
    match policy_json key with
    | Some value -> (
        match value with
        | `Int value -> Some (max 1 value)
        | `Intlit raw -> (try Some (max 1 (int_of_string raw)) with Failure _ -> None)
        | _ -> None)
    | None -> None
  in
  match get_required_string "spawn_prompt" with
  | Ok spawn_prompt ->
      Ok
        {
          spawn_agent = "default";
          spawn_prompt;
          runtime_binding_ref = get_optional_string "runtime_binding_ref";
          spawn_role = get_optional_string "spawn_role";
          execution_scope =
            (match get_optional_execution_scope "execution_scope" with
            | Some _ as explicit -> explicit
            | None ->
                Some
                  (Team_session_types.default_execution_scope_for_worker_class
                     (get_optional_worker_class "worker_class")));
          thinking_enabled = policy_bool "thinking";
          thinking_budget = policy_int "thinking_budget";
          max_turns = policy_int "max_turns";
          worker_class = get_optional_worker_class "worker_class";
          parent_actor = get_optional_string "parent_actor";
          capsule_mode = get_optional_capsule_mode "capsule_mode";
          runtime_pool = get_optional_string "runtime_pool";
          lane_id = get_optional_string "lane_id";
          control_domain = get_optional_control_domain "control_domain";
          supervisor_actor = get_optional_string "supervisor_actor";
          task_profile = get_optional_task_profile "task_profile";
          risk_level = get_optional_risk_level "risk_level";
          artifact_scope = get_optional_string_list "artifact_scope";
          routing_confidence = get_optional_float "routing_confidence";
          routing_reason = get_optional_string "routing_reason";
          spawn_selection_note = get_optional_string "spawn_selection_note";
          spawn_timeout_seconds =
            Option.value ~default:(get_timeout "spawn_timeout_seconds")
              (policy_int "timeout_seconds");
        }
  | Error e -> Error e

let parse_step_spawn_specs args =
  match find_present_json_key legacy_spawn_fields args with
  | Some field -> Error (legacy_spawn_field_error field)
  | None ->
  let singular_prompt = get_string_opt args "spawn_prompt" in
  let singular_present = Option.is_some singular_prompt in
  let default_batch_timeout =
    match Yojson.Safe.Util.member "spawn_timeout_seconds" args with
    | `Int value -> max 1 value
    | `Intlit raw -> (try max 1 (int_of_string raw) with Failure _ -> 300)
    | _ -> max 1 (get_int args "spawn_timeout_seconds" 300)
  in
  let batch_specs_result =
    let top_level_worker_policy =
      match Yojson.Safe.Util.member "worker_policy" args with
      | `Assoc _ as obj -> Some obj
      | _ -> None
    in
    match Yojson.Safe.Util.member "spawn_batch" args with
    | `Null -> Ok []
    | `List xs ->
        let rec loop idx acc = function
          | [] -> Ok (List.rev acc)
          | json :: rest -> (
              match
                parse_spawn_spec_from_object ~default_timeout:default_batch_timeout
                  ?top_level_worker_policy
                  idx json
              with
              | Ok spec -> loop (idx + 1) (spec :: acc) rest
              | Error e -> Error e)
        in
        loop 0 [] xs
    | _ -> Error "spawn_batch must be an array"
  in
  match batch_specs_result with
  | Error e -> Error e
  | Ok batch_specs ->
      let route_specs specs = Ok (List.map resolve_routing_for_spec specs) in
      if singular_present && batch_specs <> [] then
        Error "spawn_batch cannot be combined with top-level spawn_prompt"
      else if batch_specs <> [] then
        route_specs batch_specs
      else
        match singular_prompt with
        | None -> Ok []
        | Some spawn_prompt ->
            let worker_policy =
              match Yojson.Safe.Util.member "worker_policy" args with
              | `Assoc _ as obj -> Some obj
              | _ -> None
            in
            let policy_bool key =
              match worker_policy with
              | Some obj -> (
                  match Yojson.Safe.Util.member key obj with
                  | `Bool value -> Some value
                  | _ -> None)
              | None -> None
            in
            let policy_int key =
              match worker_policy with
              | Some obj -> (
                  match Yojson.Safe.Util.member key obj with
                  | `Int value -> Some (max 1 value)
                  | `Intlit raw -> (try Some (max 1 (int_of_string raw)) with Failure _ -> None)
                  | _ -> None)
              | None -> None
            in
            route_specs
              [
                {
                  spawn_agent = "default";
                  spawn_prompt;
                  runtime_binding_ref = get_string_opt args "runtime_binding_ref";
                  spawn_role = get_string_opt args "spawn_role";
                  execution_scope =
                    (match
                       Option.map
                         Team_session_types.execution_scope_of_string
                         (get_string_opt args "execution_scope")
                     with
                    | Some _ as explicit -> explicit
                    | None -> Some Team_session_types.Limited_code_change);
                  thinking_enabled = policy_bool "thinking";
                  thinking_budget = policy_int "thinking_budget";
                  max_turns = policy_int "max_turns";
                  worker_class =
                    Option.bind
                      (get_string_opt args "worker_class")
                      (fun raw ->
                        Team_session_types.worker_class_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  parent_actor = get_string_opt args "parent_actor";
                  capsule_mode =
                    Option.bind
                      (get_string_opt args "capsule_mode")
                      (fun raw ->
                        Team_session_types.capsule_mode_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  runtime_pool = get_string_opt args "runtime_pool";
                  lane_id = get_string_opt args "lane_id";
                  control_domain =
                    Option.bind
                      (get_string_opt args "control_domain")
                      (fun raw ->
                        Team_session_types.control_domain_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  supervisor_actor = get_string_opt args "supervisor_actor";
                  task_profile =
                    Option.bind
                      (get_string_opt args "task_profile")
                      (fun raw ->
                        Team_session_types.task_profile_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  risk_level =
                    Option.bind
                      (get_string_opt args "risk_level")
                      (fun raw ->
                        Team_session_types.risk_level_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  artifact_scope =
                    normalize_artifact_scope
                      (get_string_list args "artifact_scope");
                  routing_confidence = get_float_opt args "routing_confidence";
                  routing_reason = get_string_opt args "routing_reason";
                  spawn_selection_note = get_string_opt args "spawn_selection_note";
                  spawn_timeout_seconds =
                    Option.value ~default:(get_int args "spawn_timeout_seconds" 300)
                      (policy_int "timeout_seconds");
                };
              ]

let planned_worker_of_spec ?runtime_actor ?runtime_binding_ref (spec : spawn_spec) :
    Team_session_types.planned_worker =
  {
    spawn_agent = spec.spawn_agent;
    runtime_actor;
    spawn_role = spec.spawn_role;
    runtime_binding_ref =
      (match runtime_binding_ref with
      | Some _ as value -> value
      | None -> spec.runtime_binding_ref);
    spawn_model = None;
    execution_scope = effective_execution_scope_of_spec spec;
    thinking_enabled = spec.thinking_enabled;
    thinking_budget = spec.thinking_budget;
    max_turns = spec.max_turns;
    timeout_seconds = Some spec.spawn_timeout_seconds;
    worker_class = spec.worker_class;
    parent_actor = spec.parent_actor;
    capsule_mode = spec.capsule_mode;
    runtime_pool = spec.runtime_pool;
    lane_id = spec.lane_id;
    controller_level = inferred_controller_level_of_spec spec;
    control_domain = spec.control_domain;
    supervisor_actor = spec.supervisor_actor;
    task_profile = spec.task_profile;
    risk_level = spec.risk_level;
    artifact_scope = normalize_artifact_scope spec.artifact_scope;
    routing_confidence = spec.routing_confidence;
    routing_reason = spec.routing_reason;
    routing_escalated =
      (match spec.routing_reason with
      | Some reason ->
          contains_ci reason "fallback:"
          || contains_ci reason "escalate"
          || contains_ci reason "uncertain->35b"
      | None -> false);
  }

let resolve_target_worker_name config (session : Team_session_types.session)
    target_agent =
  let trimmed = String.trim target_agent in
  let fallback_worker_container_exists () =
    let worker_dir =
      Team_session_store.worker_container_dir config session.session_id
        trimmed
    in
    Room_utils.path_exists config
      (Team_session_store.worker_container_meta_path config session.session_id
         trimmed)
    || Room_utils.path_exists config
         (Team_session_store.worker_container_checkpoint_path config
            session.session_id trimmed)
    || Team_session_store.immediate_dir_entries config worker_dir <> []
  in
  let matches_runtime_actor worker =
    match worker.Team_session_types.runtime_actor with
    | Some actor -> String.equal (String.trim actor) trimmed
    | None -> false
  in
  let matches_role worker =
    match worker.Team_session_types.spawn_role with
    | Some role -> String.equal (String.trim role) trimmed
    | None -> false
  in
  match List.find_opt matches_runtime_actor session.planned_workers with
  | Some worker -> worker.Team_session_types.runtime_actor
  | None -> (
      match
        session.planned_workers |> List.filter matches_role
      with
      | [ worker ] -> worker.Team_session_types.runtime_actor
      | _ -> if fallback_worker_container_exists () then Some trimmed else None)

let register_planned_workers config session_id workers =
  let describe_worker (worker : Team_session_types.planned_worker) =
    match worker.runtime_actor with
    | Some actor when String.trim actor <> "" -> String.trim actor
    | _ -> (
        match worker.spawn_role with
        | Some role when String.trim role <> "" -> String.trim role
        | _ -> worker.spawn_agent)
  in
  let write_capable worker =
    match Team_session_types.effective_execution_scope_of_planned_worker worker with
    | Team_session_types.Observe_only -> false
    | Team_session_types.Limited_code_change
    | Team_session_types.Autonomous -> true
  in
  let has_overlap left right =
    List.exists
      (fun lhs ->
        List.exists
          (fun rhs ->
            String.equal lhs rhs
            || String.starts_with ~prefix:(lhs ^ "/") rhs
            || String.starts_with ~prefix:(rhs ^ "/") lhs)
          right)
      left
  in
  let normalized_workers =
    List.map
      (fun worker ->
        {
          worker with
          Team_session_types.artifact_scope =
            normalize_artifact_scope worker.Team_session_types.artifact_scope;
        })
      workers
  in
  let conflict_in workers_a workers_b =
    List.find_map
      (fun left ->
        let left_scope = left.Team_session_types.artifact_scope in
        if left_scope = [] || not (write_capable left) then None
        else
          workers_b
          |> List.find_opt (fun right ->
                 left != right
                 && write_capable right
                 && right.Team_session_types.artifact_scope <> []
                 && has_overlap left_scope right.Team_session_types.artifact_scope)
          |> Option.map (fun right -> (left, right)))
      workers_a
  in
  let missing_scope =
    normalized_workers
    |> List.find_opt (fun worker ->
           write_capable worker
           && worker.Team_session_types.artifact_scope = [])
  in
  match Team_session_store.load_session config session_id with
  | None -> Error "team session not found"
  | Some session -> (
      match missing_scope with
      | Some worker ->
          Error
            (Printf.sprintf
               "artifact_scope is required for write-capable worker %s"
               (describe_worker worker))
      | None -> (
      match
        ( conflict_in normalized_workers normalized_workers,
          conflict_in normalized_workers session.Team_session_types.planned_workers )
      with
      | Some (left, right), _
      | None, Some (left, right) ->
          Error
            (Printf.sprintf
               "artifact_scope overlaps between planned workers %s and %s"
               (describe_worker left) (describe_worker right))
      | None, None ->
          match Team_session_store.update_session config session_id (fun session ->
                    {
                      session with
                      planned_workers =
                        Team_session_types.dedup_planned_workers
                          (session.planned_workers @ normalized_workers);
                      updated_at_iso = Types.now_iso ();
                    })
          with
          | Ok updated ->
              Team_session_store.append_event config session_id
                ~event_type:"session_planned_workers_updated"
                ~detail:
                  (`Assoc
                    [
                      ("planned_worker_count", `Int (List.length updated.planned_workers));
                      ( "worker_class_counts",
                        Team_session_types.worker_class_counts updated.planned_workers
                        |> Team_session_types.counts_to_json );
                      ( "runtime_pool_counts",
                        Team_session_types.runtime_pool_counts updated.planned_workers
                        |> Team_session_types.counts_to_json );
                      ( "lane_counts",
                        Team_session_types.lane_counts updated.planned_workers
                        |> Team_session_types.counts_to_json );
                      ( "controller_counts",
                        Team_session_types.controller_level_counts updated.planned_workers
                        |> Team_session_types.counts_to_json );
                      ( "control_domain_counts",
                        Team_session_types.control_domain_counts updated.planned_workers
                        |> Team_session_types.counts_to_json );
                      ( "task_profile_counts",
                        Team_session_types.task_profile_counts updated.planned_workers
                        |> Team_session_types.counts_to_json );
                      ( "escalation_count",
                        `Int
                          (Team_session_types.escalation_count updated.planned_workers)
                      );
                      ( "runtime_actors",
                        `List
                          (normalized_workers
                          |> List.filter_map (fun worker ->
                                 worker.Team_session_types.runtime_actor)
                          |> List.map (fun actor -> `String actor)) );
                      ( "runtime_binding_refs",
                        `List
                          (normalized_workers
                          |> List.filter_map (fun worker ->
                                 worker.Team_session_types.runtime_binding_ref)
                          |> List.map (fun value -> `String value)) );
                      ( "artifact_scope",
                        `List
                          (normalized_workers
                          |> List.concat_map (fun worker ->
                                 worker.Team_session_types.artifact_scope)
                          |> Team_session_types.dedup_strings
                          |> List.map (fun value -> `String value)) );
                      ("ts_iso", `String (Types.now_iso ()));
                    ]);
              Ok ()
          | Error e -> Error e))

let ensure_session_actor config session_id actor_name =
  match Team_session_store.update_session config session_id (fun session ->
            let agent_names =
              Team_session_types.dedup_strings (session.agent_names @ [ actor_name ])
            in
            { session with agent_names; updated_at_iso = Types.now_iso () })
  with
  | Ok updated ->
      Team_session_store.append_event config session_id
        ~event_type:"session_agent_attached"
        ~detail:
          (`Assoc
            [
              ("actor", `String actor_name);
              ("agent_count", `Int (List.length updated.agent_names));
              ("ts_iso", `String (Types.now_iso ()));
            ]);
      Ok ()
  | Error e -> Error e

let detach_session_actor config session_id actor_name ~reason =
  match Team_session_store.update_session config session_id (fun session ->
            let agent_names =
              List.filter
                (fun existing -> not (String.equal existing actor_name))
                session.agent_names
            in
            { session with agent_names; updated_at_iso = Types.now_iso () })
  with
  | Ok updated ->
      Team_session_store.append_event config session_id
        ~event_type:"session_agent_detached"
        ~detail:
          (`Assoc
            [
              ("actor", `String actor_name);
              ("reason", `String reason);
              ("agent_count", `Int (List.length updated.agent_names));
              ("ts_iso", `String (Types.now_iso ()));
            ]);
      Ok ()
  | Error e -> Error e

let session_has_turn_for_actor config session_id actor_name =
  Team_session_store.read_events config session_id
  |> List.exists (fun json ->
         match
           ( Yojson.Safe.Util.member "event_type" json,
             Yojson.Safe.Util.member "detail" json
             |> Yojson.Safe.Util.member "actor" )
         with
         | `String "team_turn", `String recorded_actor ->
             String.equal (String.trim recorded_actor) actor_name
         | _ -> false)

let auto_note_message_of_spawn_output output =
  let trimmed = String.trim output in
  if trimmed = "" then
    None
  else
    Some ("[auto-note] " ^ truncate_for_event ~max_len:480 trimmed)

let reconcile_failed_spawn_actor config session_id actor_name =
  if session_has_turn_for_actor config session_id actor_name then
    Ok `Retained
  else
    detach_session_actor config session_id actor_name
      ~reason:"spawn_failed_without_turn"
    |> Result.map (fun () -> `Detached)

let extract_vote_id (text : string) =
  let re = Re.Pcre.re "vote-[0-9-]+-[0-9]+" |> Re.compile in
  match Re.exec_opt re text with
  | Some g -> Some (Re.Group.get g 0)
  | None -> None

let status_of_engine_status_json (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "session" json |> Yojson.Safe.Util.member "status" with
  | `String s -> s
  | _ -> "unknown"
