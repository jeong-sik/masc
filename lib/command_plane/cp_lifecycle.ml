include Cp_lifecycle_intents
open Result_syntax

let snapshot_json config =
  let t0 = Unix.gettimeofday () in
  let timed label f =
    let t_start = Unix.gettimeofday () in
    let result = f () in
    let elapsed = Unix.gettimeofday () -. t_start in
    if elapsed > 0.5 then
      Log.Dashboard.info "[cp_snapshot] %s: %.0fms" label (elapsed *. 1000.0);
    result
  in
  let state = timed "build_state" (fun () -> build_snapshot_state config) in
  let topology = timed "topology" (fun () -> topology_json_from_state state) in
  let intents = timed "intents" (fun () -> intents_summary_json_from_state state) in
  let operations = timed "operations" (fun () -> list_operations_json_from_state state) in
  let detachments = timed "detachments" (fun () -> list_detachments_json_from_state state) in
  let alerts = timed "alerts" (fun () -> list_alerts_json_from_state config state) in
  let decisions = timed "decisions" (fun () -> list_policy_decisions_json_from_state state) in
  let capacity = timed "capacity" (fun () -> capacity_json_from_state state) in
  let traces = timed "traces" (fun () -> list_traces_json config ~limit:10 ()) in
  let dt_total = Unix.gettimeofday () -. t0 in
  if dt_total > 1.0 then
    Log.Dashboard.warn "[cp_snapshot] total: %.0fms" (dt_total *. 1000.0);
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("topology", topology);
      ("intents", intents);
      ("operations", operations);
      ("detachments", detachments);
      ("alerts", alerts);
      ("decisions", decisions);
      ("capacity", capacity);
      ("traces", traces);
    ]

let json_string_option = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null

let dashboard_search_json operations (operation : operation_record) =
  let readiness = operation_readiness operations operation in
  let selected_unit_id =
    match String.trim operation.assigned_unit_id with
    | "" -> None
    | value -> Some value
  in
  Cp_search_fabric.summary_json
    ~strategy:(operation_search_strategy operation)
    ~readiness
    ~candidates:[]
    ~selected_unit_id

let dashboard_operation_card_json units operations (operation : operation_record) =
  let unit_label =
    lookup_unit units operation.assigned_unit_id
    |> Option.map (fun (unit : unit_record) -> unit.label)
    |> Option.value ~default:operation.assigned_unit_id
  in
  `Assoc
    [
      ( "operation",
        `Assoc
          [
            ("operation_id", `String operation.operation_id);
            ("objective", `String operation.objective);
            ("status", `String (string_of_operation_status operation.status));
            ("stage", json_string_option operation.stage);
            ("assigned_unit_id", `String operation.assigned_unit_id);
            ("detachment_session_id", json_string_option operation.detachment_session_id);
            ("updated_at", `String operation.updated_at);
          ] );
      ("assigned_unit_label", `String unit_label);
      ("search", dashboard_search_json operations operation);
    ]

let dashboard_operations_json_from_state (state : snapshot_state) =
  let operations = state.operations in
  let managed_count =
    List.length
      (List.filter
         (fun (operation : operation_record) -> operation.source = "managed")
         operations)
  in
  let projected_count = List.length operations - managed_count in
  `Assoc
    [
      ("summary",
       `Assoc
         [
           ("total", `Int (List.length operations));
           ( "active",
             `Int
               (List.length
                  (List.filter
                     (fun (operation : operation_record) ->
                       operation.status = Active)
                     operations)) );
           ( "paused",
             `Int
               (List.length
                  (List.filter
                     (fun (operation : operation_record) ->
                       operation.status = Paused)
                     operations)) );
           ("managed", `Int managed_count);
           ("projected", `Int projected_count);
         ]);
      ( "operations",
        `List
          (List.map
             (dashboard_operation_card_json state.units state.operations)
             operations) );
    ]

let dashboard_detachments_json_from_state (state : snapshot_state) =
  let detachments = state.detachments in
  let projected_count =
    List.length
      (List.filter
         (fun (detachment : detachment_record) -> detachment.source <> "managed")
         detachments)
  in
  `Assoc
    [
      ("summary",
       `Assoc
         [
           ("total", `Int (List.length detachments));
           ( "active",
             `Int
               (List.length
                  (List.filter
                     (fun (detachment : detachment_record) ->
                       String.equal detachment.status "active")
                     detachments)) );
           ( "awaiting_approval",
             `Int
               (List.length
                  (List.filter
                     (fun (detachment : detachment_record) ->
                       String.equal detachment.status "awaiting_approval")
                     detachments)) );
           ( "stalled",
             `Int
               (List.length
                  (List.filter
                     (fun (detachment : detachment_record) ->
                       String.equal detachment.status "stalled")
                     detachments)) );
           ("projected", `Int projected_count);
         ]);
      ( "detachments",
        `List
          (List.map
             (fun (detachment : detachment_record) ->
               `Assoc
                 [
                   ( "detachment",
                     `Assoc
                       [
                         ("detachment_id", `String detachment.detachment_id);
                         ("operation_id", `String detachment.operation_id);
                         ("session_id", json_string_option detachment.session_id);
                         ("status", `String detachment.status);
                       ] );
                 ])
             detachments) );
    ]

let dashboard_decisions_json_from_state (state : snapshot_state) =
  let count_status status =
    List.length
      (List.filter
         (fun (decision : policy_decision_record) ->
           String.equal decision.status status)
         state.decisions)
  in
  `Assoc
    [
      ("summary",
       `Assoc
         [
           ("total", `Int (List.length state.decisions));
           ("pending", `Int (count_status "pending"));
           ("approved", `Int (count_status "approved"));
           ("denied", `Int (count_status "denied"));
         ]);
    ]

let dashboard_projection_json config =
  let state = build_snapshot_state config in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("operations", dashboard_operations_json_from_state state);
      ("detachments", dashboard_detachments_json_from_state state);
      ("decisions", dashboard_decisions_json_from_state state);
    ]

let operation_status_json config ?operation_id () =
  list_operations_json ?operation_id config

let legacy_chain_run_id json =
  match U.member "chain" json with
  | `Assoc _ as chain_json -> get_string_opt chain_json "run_id"
  | _ -> None

let company_scope_id_for units source_unit_id target_unit_id =
  option_first_some
    (Option.bind target_unit_id (fun unit_id -> company_ancestor_id units unit_id))
    (Option.bind source_unit_id (fun unit_id -> company_ancestor_id units unit_id))
  |> Option.value ~default:"company-runtime"

let find_pending_decision config ~requested_action ?operation_id ?target_unit_id () =
  all_policy_decisions config
  |> List.find_opt (fun (decision : policy_decision_record) ->
         String.equal decision.status "pending"
         && String.equal decision.requested_action requested_action
         &&
         match operation_id, decision.operation_id with
         | None, _ -> true
         | Some expected, Some actual -> String.equal expected actual
         | Some _, None -> false
         &&
         match target_unit_id, decision.target_unit_id with
         | None, _ -> true
         | Some expected, Some actual -> String.equal expected actual
         | Some _, None -> false)

let create_policy_decision config ~(actor : string) ~requested_action ~scope_type
    ~scope_id ?operation_id ?target_unit_id ~reason ?(source = "managed") detail =
  let decision =
    {
      decision_id = next_event_id "dec";
      trace_id = next_trace_id ();
      requested_action;
      scope_type;
      scope_id;
      operation_id;
      target_unit_id;
      requested_by = actor;
      status = "pending";
      reason;
      source;
      detail;
      created_at = Types.now_iso ();
      decided_at = None;
      expires_at =
        (let ttl = Env_config.Decision.ttl_seconds in
         let t = Unix.gettimeofday () +. ttl in
         let tm = Unix.gmtime t in
         Some (Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
           (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
           tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec));
    }
  in
  let decisions = read_policy_decisions config in
  write_policy_decisions config (decision :: decisions);
  append_cp_event config ~trace_id:decision.trace_id ~event_type:"policy_decision_requested"
    ?operation_id ?unit_id:target_unit_id ~actor
    (`Assoc
      [
        ("decision_id", `String decision.decision_id);
        ("requested_action", `String requested_action);
        ("scope_type", `String scope_type);
        ("scope_id", `String scope_id);
      ]);
  decision

(** Expire pending decisions that have passed their TTL.
    Returns count of expired decisions. *)
let check_expired_decisions config =
  let now = Types.now_iso () in
  let decisions = read_policy_decisions config in
  let expired_count = ref 0 in
  let updated = List.map (fun (d : policy_decision_record) ->
    match d.status, d.expires_at with
    | "pending", Some exp when exp < now ->
        incr expired_count;
        { d with status = "expired"; decided_at = Some now }
    | _ -> d
  ) decisions in
  if !expired_count > 0 then
    write_policy_decisions config updated;
  !expired_count

(** BUG-019: Auto-fail blocked intents past timeout (default 3600s).
    Returns count of failed intents. *)
let check_blocked_intents config =
  let timeout_sec = Env_config.Decision.ttl_seconds in
  let now = Types.now_iso () in
  let now_unix = Unix.gettimeofday () in
  let intents = read_intents config in
  let failed_count = ref 0 in
  let updated = List.map (fun (intent : intent_record) ->
    match intent.state with
    | Blocked_intent ->
        let created_unix = Types.parse_iso8601 intent.created_at in
        if now_unix -. created_unix > timeout_sec then begin
          incr failed_count;
          { intent with state = Dropped_intent; updated_at = now }
        end else
          intent
    | _ -> intent
  ) intents in
  if !failed_count > 0 then
    write_intents config updated;
  !failed_count

let apply_operation_assignment config ~(actor : string) (operation : operation_record)
    ~target_unit_id ~note ~event_type =
  match
    operation_assignment_guard_json config target_unit_id
      ~workload_profile:(operation_workload_profile operation)
      ~stage:operation.stage
  with
  | Error message -> Error message
  | Ok _ ->
      let updated =
        {
          operation with
          assigned_unit_id = target_unit_id;
          note =
            (match note, operation.note with
            | Some value, _ -> Some value
            | None, existing -> existing);
          updated_at = Types.now_iso ();
        }
      in
      let operations = read_operations config in
      write_operations config (replace_operation operations updated);
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      touch_intent_from_operation config ~actor updated ~state:Active_intent;
      append_cp_event config ~trace_id:updated.trace_id ~event_type
        ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id ~actor
        (`Assoc
          [
            ("from_unit_id", `String operation.assigned_unit_id);
            ("to_unit_id", `String target_unit_id);
          ]);
      Ok updated

let update_operation_status config ~(actor : string) ~operation_id ~status ~note ~event_type =
  with_operation config operation_id (fun operations current ->
      let updated =
        {
          current with
          status;
          note =
            (match note, current.note with
            | Some value, _ -> Some value
            | None, existing -> existing);
          updated_at = Types.now_iso ();
        }
      in
      write_operations config (replace_operation operations updated);
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      let intent_state =
        match status with
        | Planned | Active -> Active_intent
        | Paused -> Suspended_intent
        | Completed -> Completed_intent
        | Cancelled -> Dropped_intent
        | Failed -> Blocked_intent
      in
      touch_intent_from_operation config ~actor updated ~state:intent_state;
      append_cp_event config ~trace_id:updated.trace_id ~event_type
        ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id ~actor
        (`Assoc [ ("status", `String (string_of_operation_status status)) ]);
      Ok updated)

let update_operation config ~(actor : string) ~operation_id ?event_type ?detail f =
  with_operation config operation_id (fun operations current ->
      let updated : operation_record =
        f current |> fun (operation : operation_record) -> { operation with updated_at = Types.now_iso () }
      in
      write_operations config (replace_operation operations updated);
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      (match event_type with
      | Some current_event_type ->
          append_cp_event config ~trace_id:updated.trace_id ~event_type:current_event_type
            ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id
            ~actor
            (Option.value ~default:(`Assoc []) detail)
      | None -> ());
      Ok updated)

let update_unit config ~(actor : string) ~unit_id f ~event_type detail =
  let units = read_units config in
  match lookup_unit units unit_id with
  | None -> Error (Printf.sprintf "unit not found: %s" unit_id)
  | Some current ->
      let updated : unit_record = f current in
      let validation_pool =
        List.filter
          (fun (unit : unit_record) -> not (String.equal unit.unit_id updated.unit_id))
          (effective_units_for_validation config units)
      in
      (match validate_unit_shape validation_pool updated with
      | Error message -> Error message
      | Ok () ->
          write_units config (updated :: validation_pool);
          append_cp_event config ~trace_id:(next_trace_id ()) ~event_type
            ~unit_id:updated.unit_id ~actor detail;
          Ok updated)

let start_operation config ~(actor : string) json =
  let validate_coding_dependency_requirement ~stage ~depends_on_operation_ids =
    let expected_stage =
      match stage with
      | "verify" -> Some "implement"
      | "review" -> Some "verify"
      | _ -> None
    in
    match expected_stage with
    | None -> Ok ()
    | Some expected_stage ->
        if depends_on_operation_ids = [] then
          Error
            (Printf.sprintf
               "coding_task %s stage requires at least one %s dependency"
               stage expected_stage)
        else
          let operations = read_operations config in
          if
            List.exists
              (fun dep_id ->
                match operation_by_id operations dep_id with
                | Some dependency ->
                    String.equal (operation_workload_profile dependency) "coding_task"
                    && normalize_stage dependency.stage = Some expected_stage
                | None -> false)
              depends_on_operation_ids
          then
            Ok ()
          else
            Error
              (Printf.sprintf
                 "coding_task %s stage requires a coding_task %s dependency"
                 stage expected_stage)
  in
  let assigned_unit_id =
    match get_string_opt json "assigned_unit_id" with
    | Some value -> value
    | None -> invalid_arg "assigned_unit_id is required. Call masc_unit_define first to create a unit."
  in
  let objective =
    match get_string_opt json "objective" with
    | Some value -> value
    | None -> invalid_arg "objective is required"
  in
  let workload_template =
    match get_string_opt json "workload_template" with
    | Some value ->
        let* validated = validate_workload_template value in
        Ok (Some validated)
    | None -> Ok None
  in
  let* workload_template = workload_template in
  let inferred_workload_profile, inferred_stage =
    match workload_template with
    | Some template -> (
        match workload_template_defaults template with
        | Some defaults -> defaults
        | None -> ("coding_task", None))
    | None -> ("coding_task", None)
  in
  let explicit_workload_profile = get_string_opt json "workload_profile" in
  let* () =
    match workload_template, explicit_workload_profile with
    | Some template, Some explicit_profile -> (
        let expected_profile, _ =
          match workload_template_defaults template with
          | Some defaults -> defaults
          | None -> ("coding_task", None)
        in
        let* normalized_explicit = validate_workload_profile explicit_profile in
        if String.equal normalized_explicit expected_profile then
          Ok ()
        else
          Error
            (Printf.sprintf
               "workload_template %s requires workload_profile=%s"
               template expected_profile))
    | _ -> Ok ()
  in
  let workload_profile_raw =
    match explicit_workload_profile with
    | Some value -> value
    | None -> inferred_workload_profile
  in
  let requested_stage =
    match get_string_opt json "stage" with
    | Some value -> Some value
    | None -> inferred_stage
  in
  let search_strategy_raw =
    get_string_default json "search_strategy" (room_search_strategy_default config)
  in
  let depends_on_operation_ids = get_string_list json "depends_on_operation_ids" in
  let requested_intent_id = get_string_opt json "intent_id" in
  let raw_artifact_scope = get_string_list json "artifact_scope" in
  let* workload_profile = validate_workload_profile workload_profile_raw in
  let* stage =
    validate_stage_for_workload ~workload_profile requested_stage
  in
  let* () =
    operation_assignment_guard_json config assigned_unit_id ~workload_profile
      ~stage
    |> Result.map ignore
  in
  let* search_strategy = validate_search_strategy search_strategy_raw in
  let* intent_binding =
    match requested_intent_id with
    | None -> Ok None
    | Some intent_id ->
        with_intent config intent_id (fun _ intent ->
            if not (String.equal intent.workload_profile workload_profile) then
              Error
                (Printf.sprintf
                   "intent workload_profile mismatch: intent=%s operation=%s"
                   intent.workload_profile workload_profile)
            else
              Ok (Some intent))
  in
  let artifact_scope =
    match intent_binding with
    | Some intent when raw_artifact_scope = [] -> intent.artifact_priors
    | _ -> raw_artifact_scope
  in
  let* () =
    match workload_profile, stage with
    | "coding_task", Some ("verify" | "review" as stage_name) ->
        validate_coding_dependency_requirement ~stage:stage_name
          ~depends_on_operation_ids
    | _ -> Ok ()
  in
  let checkpoint_ref =
    option_first_some (get_string_opt json "checkpoint_ref")
      (legacy_chain_run_id json)
  in
  let operation =
    {
      operation_id = next_operation_id ();
      objective;
      intent_id = Option.map (fun (intent : intent_record) -> intent.intent_id) intent_binding;
      assigned_unit_id;
      policy_class = get_string_default json "policy_class" "strict";
      budget_class = get_string_default json "budget_class" "standard";
      workload_template;
      workload_profile;
      stage;
      artifact_scope;
      depends_on_operation_ids;
      search_strategy;
      detachment_session_id = get_string_opt json "detachment_session_id";
      trace_id = next_trace_id ();
      checkpoint_ref;
      active_goal_ids = get_string_list json "active_goal_ids";
      note = get_string_opt json "note";
      created_by = actor;
      source = "managed";
      status =
        (match
           (match get_string_opt json "status" with
           | Some value -> operation_status_of_string value
           | None -> None)
         with
        | Some value -> value
        | None -> Active);
      created_at = Types.now_iso ();
      updated_at = Types.now_iso ();
    }
  in
  let operations = read_operations config in
  write_operations config (operation :: operations);
  let _, _, units, _ = topology_units config in
  let _ =
    match operation_search_strategy operation with
    | Cp_search_fabric.Legacy -> sync_managed_detachments config units operation
    | Cp_search_fabric.Best_first_v1 -> []
  in
  touch_intent_from_operation config ~actor operation ~state:Active_intent;
  append_cp_event config ~trace_id:operation.trace_id ~event_type:"operation_started"
    ~operation_id:operation.operation_id ~unit_id:operation.assigned_unit_id ~actor
    (`Assoc
      [
        ("objective", `String operation.objective);
            ("intent_id", Json_util.string_opt_to_json operation.intent_id);
            ("policy_class", `String operation.policy_class);
            ("workload_template", Json_util.string_opt_to_json operation.workload_template);
            ("workload_profile", `String (operation_workload_profile operation));
            ("stage", Json_util.string_opt_to_json operation.stage);
            ("artifact_scope", json_list_of_strings operation.artifact_scope);
            ("search_strategy", `String operation.search_strategy);
          ]);
      Ok operation

let checkpoint_operation config ~(actor : string) json =
  let operation_id =
    match get_string_opt json "operation_id" with
    | Some value -> value
    | None -> invalid_arg "operation_id is required. Call masc_operation_start first."
  in
  let checkpoint_ref =
    match get_string_opt json "checkpoint_ref" with
    | Some value -> value
    | None -> invalid_arg "checkpoint_ref is required"
  in
  let operations = read_operations config in
  match
    List.find_opt
      (fun (operation : operation_record) ->
        String.equal operation.operation_id operation_id)
      operations
  with
  | None -> Error (Printf.sprintf "operation not found: %s" operation_id)
  | Some current ->
      let updated =
        {
          current with
          checkpoint_ref = Some checkpoint_ref;
          note =
            (match get_string_opt json "note", current.note with
            | Some note, _ -> Some note
            | None, existing -> existing);
          updated_at = Types.now_iso ();
        }
      in
      let next_operations =
        replace_operation operations updated
      in
      write_operations config next_operations;
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      touch_intent_from_operation config ~actor updated
        ~state:(intent_state_hint_of_operation_status updated);
      if operation_search_strategy updated = Cp_search_fabric.Best_first_v1 then
        update_search_stats_for_operation config updated ~outcome:`Success;
      append_cp_event config ~trace_id:updated.trace_id ~event_type:"operation_checkpointed"
        ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id ~actor
        (`Assoc [ ("checkpoint_ref", `String checkpoint_ref) ]);
      Ok updated

let pause_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required. Call masc_operation_start first."
  | Some operation_id ->
      Result.map operation_to_json
        (update_operation_status config ~actor ~operation_id ~status:Paused
           ~note:(get_string_opt json "note") ~event_type:"operation_paused")

let resume_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required. Call masc_operation_start first."
  | Some operation_id ->
      Result.map operation_to_json
        (update_operation_status config ~actor ~operation_id ~status:Active
           ~note:(get_string_opt json "note") ~event_type:"operation_resumed")

let stop_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required. Call masc_operation_start first."
  | Some operation_id ->
      Result.map operation_to_json
        (update_operation_status config ~actor ~operation_id ~status:Cancelled
           ~note:(get_string_opt json "note") ~event_type:"operation_stopped")

let finalize_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required. Call masc_operation_start first."
  | Some operation_id ->
      Result.map
        (fun operation ->
          if operation_search_strategy operation = Cp_search_fabric.Best_first_v1 then
            update_search_stats_for_operation config operation ~outcome:`Success;
          operation_to_json operation)
        (update_operation_status config ~actor ~operation_id ~status:Completed
           ~note:(get_string_opt json "note") ~event_type:"operation_finalized")

let dispatch_plan_json config json =
  let _, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let operation_id = get_string_opt json "operation_id" in
  let operation =
    match operation_id with
    | Some value -> operation_by_id operations value
    | None -> None
  in
  let current_unit_id = Option.map (fun (op : operation_record) -> op.assigned_unit_id) operation in
  let strategy =
    match operation with
    | Some op -> operation_search_strategy op
    | None -> Cp_search_fabric.Legacy
  in
  let readiness =
    match operation with
    | Some op -> operation_readiness operations op
    | None -> Cp_search_fabric.Ready
  in
  let scored_candidates =
    match operation with
    | Some op when strategy = Cp_search_fabric.Best_first_v1 ->
        operation_search_candidates config units operations op
    | Some op ->
        let preview_op = { op with search_strategy = "best_first_v1" } in
        operation_search_candidates config units operations preview_op
    | None -> []
  in
  let recommended_units =
    if scored_candidates <> [] then
      scored_candidates
      |> List.map (fun (candidate : Cp_search_fabric.scored_candidate) ->
             `Assoc
               [
                 ( "unit",
                   match lookup_unit units candidate.unit_id with
                   | Some unit -> unit_to_json unit
                   | None ->
                       `Assoc
                         [
                           ("unit_id", `String candidate.unit_id);
                           ("label", `String candidate.label);
                         ] );
                 ("score", `Float candidate.breakdown.total);
                 ( "score_breakdown",
                   Cp_search_fabric.breakdown_to_json candidate.breakdown );
                 ("routing_reason", `String candidate.routing_reason);
               ])
    else
      let workload_profile =
        match operation with
        | Some op -> operation_workload_profile op
        | None -> "coding_task"
      in
      let stage =
        match operation with
        | Some op -> op.stage
        | None -> None
      in
      let candidate_pool =
        match operation with
        | Some op ->
            let target_unit_ids =
              detachment_targets_for_operation units op
              |> List.map (fun (unit : unit_record) -> unit.unit_id)
            in
            candidate_units_for_operation units operations current_unit_id
            |> List.filter (fun (unit : unit_record) ->
                   List.mem unit.unit_id target_unit_ids
                   &&
                   not
                     (decision_requires_approval units current_unit_id unit.unit_id))
        | None -> candidate_units_for_operation units operations current_unit_id
      in
      candidate_pool
      |> List.filter_map (fun (unit : unit_record) ->
             match
               operation_assignment_guard_json config unit.unit_id
                 ~workload_profile ~stage
             with
             | Ok guard ->
                 Some
                   (`Assoc
                     [
                       ("unit", unit_to_json unit);
                       ("guard", guard);
                       ("score", `Null);
                       ("score_breakdown", `Null);
                       ("routing_reason", `String "legacy candidate ordering");
                     ])
             | Error _ -> None)
  in
  `Assoc
    [
      ("status", `String "ok");
      ("strategy", `String (Cp_search_fabric.strategy_to_string strategy));
      ( "readiness",
        match readiness with
        | Cp_search_fabric.Ready -> `String "ready"
        | Cp_search_fabric.Blocked _ -> `String "blocked" );
      ( "dependency_blockers",
        match readiness with
        | Cp_search_fabric.Ready -> `List []
        | Cp_search_fabric.Blocked blockers ->
            `List (List.map Cp_search_fabric.blocker_to_json blockers) );
      ("recommended_units", `List recommended_units);
      ("current_unit_id", Json_util.string_opt_to_json current_unit_id);
    ]
