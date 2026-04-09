include Cp_lifecycle_search
open Result_syntax

let update_search_stats_for_operation config operation ~outcome =
  let stage = operation_stage_key operation in
  let workload_profile = operation_workload_profile operation in
  let current = read_search_stats config in
  let updated =
    match outcome with
    | `Success ->
        Cp_search_fabric.record_success current
          ~unit_id:operation.assigned_unit_id ~workload_profile ~stage
    | `Failure ->
        Cp_search_fabric.record_failure current
          ~unit_id:operation.assigned_unit_id ~workload_profile ~stage
  in
  write_search_stats config updated

let operation_card_json ~search_store ~intents ~agents config units operations
    (operation : operation_record) =
  let unit_label =
    lookup_unit units operation.assigned_unit_id
    |> Option.map (fun (unit : unit_record) -> unit.label)
    |> Option.value ~default:operation.assigned_unit_id
  in
  let intent_json =
    match operation.intent_id with
    | Some intent_id -> (
        match lookup_intent intents intent_id with
        | Some intent -> intent_to_json intent
        | None ->
            `Assoc
              [
                ("status", `String "error");
                ("message", `String (Printf.sprintf "intent not found: %s" intent_id));
              ])
    | None -> `Null
  in
  `Assoc
    [
      ("operation", operation_to_json operation);
      ("assigned_unit_label", `String unit_label);
      ("intent", intent_json);
      ("search", operation_search_json ~store:search_store ~intents ~agents config units operations operation);
    ]

let list_operations_json_from_state ?operation_id (state : snapshot_state) =
  let agents = state.agents in
  let units = state.units in
  let intents = state.intents in
  let search_store = read_search_stats state.config in
  let operations =
    state.operations
    |> List.filter (fun (operation : operation_record) ->
           match operation_id with
           | None -> true
           | Some value ->
               String.equal operation.operation_id value
               || String.equal operation.trace_id value)
  in
  let managed_count =
    List.length
      (List.filter (fun (operation : operation_record) -> operation.source = "managed") operations)
  in
  let projected_count = List.length operations - managed_count in
  let microarch =
    operations_summary_json_from_state { state with operations }
    |> U.member "microarch"
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length operations));
            ( "active",
              `Int
                (List.length
                   (List.filter
                      (fun (op : operation_record) -> op.status = Active)
                      operations)) );
            ( "paused",
              `Int
                (List.length
                   (List.filter
                      (fun (op : operation_record) -> op.status = Paused)
                      operations)) );
            ("managed", `Int managed_count);
            ("projected", `Int projected_count);
          ] );
      ("microarch", microarch);
      ( "operations",
        `List
          (List.map
             (operation_card_json ~search_store ~intents ~agents state.config units
                state.operations)
             operations) );
    ]

let list_operations_json ?operation_id config =
  list_operations_json_from_state ?operation_id (build_snapshot_state config)

let linked_operations_for_intent config intent_id =
  let operations : operation_record list = read_operations config in
  let filtered =
    List.filter
      (fun (operation : operation_record) ->
        match operation.intent_id with
        | Some current -> String.equal current intent_id
        | None -> false)
      operations
  in
  List.sort
    (fun (left : operation_record) (right : operation_record) ->
      String.compare right.updated_at left.updated_at)
    filtered

let intent_focus_json focus = intent_focus_to_json focus

let unresolved_dependencies operations (operation : operation_record) =
  operation.depends_on_operation_ids
  |> List.filter_map (fun dep_id ->
         match operation_by_id operations dep_id with
         | Some upstream when upstream.status = Completed -> None
         | Some upstream when Option.is_some upstream.checkpoint_ref -> None
         | Some upstream -> Some upstream.operation_id
         | None -> Some dep_id)

let intent_forecast_json config intent_id ?(limit = 3) () =
  with_intent config intent_id (fun _ intent ->
      let _, _, units, _ = topology_units config in
      let all_operations = all_operations config units in
      let intent_operations =
        all_operations
        |> List.filter (fun (operation : operation_record) ->
               match operation.intent_id with
               | Some current -> String.equal current intent_id
               | None -> false)
        |> List.sort (fun (left : operation_record) (right : operation_record) ->
               String.compare right.updated_at left.updated_at)
      in
      let latest_operation = List.nth_opt intent_operations 0 in
      let base_focus =
        match latest_operation with
        | Some operation -> focus_of_operation operation
        | None ->
            {
              intent.current_focus with
              artifact_scope =
                if intent.current_focus.artifact_scope <> [] then
                  intent.current_focus.artifact_scope
                else
                  intent.artifact_priors;
            }
      in
      let risk_flags =
        let flags = ref [] in
        (match latest_operation with
        | None -> flags := "no_linked_operations" :: !flags
        | Some operation ->
            if operation.status = Failed then
              flags := "failed_operation_present" :: !flags;
            if
              String.equal intent.workload_profile "coding_task"
              && base_focus.artifact_scope = []
              &&
              match base_focus.stage with
              | Some "decompose" | None -> false
              | _ -> true
            then
              flags := "missing_artifact_scope" :: !flags;
            if
              match normalize_stage operation.stage with
              | Some ("verify" | "review") ->
                  unresolved_dependencies all_operations operation <> []
              | _ -> false
            then
              flags := "verification_gap" :: !flags);
        List.rev !flags
      in
      let blocked_by =
        match latest_operation with
        | Some operation -> unresolved_dependencies all_operations operation
        | None -> []
      in
      let candidate_focuses =
        let artifact_scope =
          if base_focus.artifact_scope <> [] then base_focus.artifact_scope
          else intent.artifact_priors
        in
        let make_candidate ~stage ~score ~reason =
          let verification_state =
            match stage with
            | Some "verify" -> Some "needs_implement_checkpoint"
            | Some "review" -> Some "needs_verify_checkpoint"
            | Some "implement" -> Some "code_change_pending"
            | _ -> base_focus.verification_state
          in
          `Assoc
            [
              ("stage", Json_util.string_opt_to_json stage);
              ("artifact_scope", json_list_of_strings artifact_scope);
              ("unit_id", Json_util.string_opt_to_json base_focus.unit_id);
              ("verification_state", Json_util.string_opt_to_json verification_state);
              ("successor_score", `Float score);
              ("reason", `String reason);
            ]
        in
        match latest_operation with
        | None ->
            [ make_candidate ~stage:(next_stage_for intent.workload_profile None)
                ~score:0.9 ~reason:"bootstrap from adopted intent" ]
        | Some operation -> (
            let next_stage = next_stage_for intent.workload_profile operation.stage in
            match operation.status with
            | Completed ->
                [
                  make_candidate ~stage:next_stage ~score:0.92
                    ~reason:"advance to successor stage after completed operation";
                  make_candidate ~stage:operation.stage ~score:0.35
                    ~reason:"keep recent focus warm for follow-up";
                ]
            | Active | Planned | Paused ->
                [
                  make_candidate ~stage:operation.stage ~score:0.78
                    ~reason:"continue active focus";
                  make_candidate ~stage:next_stage ~score:0.58
                    ~reason:"prepare successor stage in parallel";
                ]
            | Failed | Cancelled ->
                [
                  make_candidate ~stage:operation.stage ~score:0.25
                    ~reason:"recover failed focus before advancing";
                ])
      in
      let candidate_focuses =
        candidate_focuses
        |> List.filteri (fun idx _ -> idx < limit)
      in
      let recommended_focus =
        match candidate_focuses with
        | (`Assoc _ as focus) :: _ -> focus
        | _ -> intent_focus_json base_focus
      in
      Ok
        (`Assoc
          [
            ("intent", intent_to_json intent);
            ("current_focus", intent_focus_json base_focus);
            ("candidate_next_states", `List candidate_focuses);
            ("risk_flags", json_list_of_strings risk_flags);
            ("blocked_by", json_list_of_strings blocked_by);
            ("recommended_focus", recommended_focus);
          ]))

let list_intents_json ?intent_id config =
  let intents = read_intents config in
  let rows =
    intents
    |> List.filter (fun (intent : intent_record) ->
           match intent_id with
           | Some value -> String.equal intent.intent_id value
           | None -> true)
  in
  let state_count state =
    rows
    |> List.filter (fun (intent : intent_record) -> intent.state = state)
    |> List.length
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length rows));
            ("active", `Int (state_count Active_intent));
            ("blocked", `Int (state_count Blocked_intent));
            ("handoff_ready", `Int (state_count Handoff_ready));
          ] );
      ("intents", `List (List.map intent_to_json rows));
    ]

let create_intent_json config ~(actor : string) json =
  let title =
    match get_string_opt json "title" with
    | Some value -> value
    | None -> invalid_arg "title is required"
  in
  let workload_profile_raw =
    get_string_default json "workload_profile" "coding_task"
  in
  let* workload_profile = validate_workload_profile workload_profile_raw in
  let current_focus =
    match U.member "current_focus" json with
    | `Assoc _ as value -> intent_focus_of_json value
    | _ -> empty_intent_focus
  in
  let intent =
    {
      intent_id = next_intent_id ();
      title;
      owner = get_string_default json "owner" actor;
      workload_profile;
      success_metric =
        (match U.member "success_metric" json with
        | `Null -> None
        | value -> Some value);
      invariants = get_string_list json "invariants";
      artifact_priors = get_string_list json "artifact_priors";
      state =
        (match get_string_opt json "state" with
        | Some value -> (
            match intent_state_of_string value with
            | Some state -> state
            | None -> Adopted)
        | None -> Adopted);
      current_focus;
      checkpoint_ref = get_string_opt json "checkpoint_ref";
      source = "managed";
      created_at = Types.now_iso ();
      updated_at = Types.now_iso ();
    }
  in
  let intents = read_intents config in
  write_intents config (intent :: intents);
  append_cp_event config ~trace_id:(next_trace_id ()) ~event_type:"intent_created"
    ~actor (`Assoc [ ("intent_id", `String intent.intent_id) ]);
  Ok intent

let update_intent_json config ~(actor : string) json =
  let intent_id =
    match get_string_opt json "intent_id" with
    | Some value -> value
    | None -> invalid_arg "intent_id is required"
  in
  with_intent config intent_id (fun intents intent ->
      let workload_profile =
        match get_string_opt json "workload_profile" with
        | Some value -> validate_workload_profile value
        | None -> Ok intent.workload_profile
      in
      let* workload_profile = workload_profile in
      let current_focus =
        match U.member "current_focus" json with
        | `Assoc _ as value -> intent_focus_of_json value
        | _ -> intent.current_focus
      in
      let state =
        match get_string_opt json "state" with
        | Some value -> (
            match intent_state_of_string value with
            | Some state -> state
            | None ->
                invalid_arg
                  (Printf.sprintf "unsupported intent state: %s" value))
        | None -> intent.state
      in
      let updated =
        {
          intent with
          title = get_string_default json "title" intent.title;
          owner = get_string_default json "owner" intent.owner;
          workload_profile;
          success_metric =
            (match U.member "success_metric" json with
            | `Null -> intent.success_metric
            | value -> Some value);
          invariants =
            (match U.member "invariants" json with
            | `List _ -> get_string_list json "invariants"
            | _ -> intent.invariants);
          artifact_priors =
            (match U.member "artifact_priors" json with
            | `List _ -> get_string_list json "artifact_priors"
            | _ -> intent.artifact_priors);
          state;
          current_focus;
          checkpoint_ref =
            option_first_some (get_string_opt json "checkpoint_ref")
              intent.checkpoint_ref;
          updated_at = Types.now_iso ();
        }
      in
      write_intents config (replace_intent intents updated);
      append_cp_event config ~trace_id:(next_trace_id ()) ~event_type:"intent_updated"
        ~actor (`Assoc [ ("intent_id", `String updated.intent_id) ]);
      Ok updated)
