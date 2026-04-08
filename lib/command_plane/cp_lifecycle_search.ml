include Cp_snapshot

let normalized_allowlist_value raw =
  String.trim raw |> String.lowercase_ascii

let normalize_allowlist raw =
  raw
  |> List.map normalized_allowlist_value
  |> List.filter (fun item -> item <> "")

let allowlist_allows_value allowlist value =
  let allowlist = normalize_allowlist allowlist in
  allowlist = []
  || List.mem (normalized_allowlist_value value) allowlist

let effective_capability_profile (unit : unit_record) =
  unit.capability_profile
  |> List.filter (fun raw ->
         match Cp_search_fabric.extract_tag_value "tool" raw with
         | Some tool_name ->
             allowlist_allows_value unit.policy.tool_allowlist tool_name
         | None -> (
             match Cp_search_fabric.extract_tag_value "model" raw with
             | Some model_name ->
                 allowlist_allows_value unit.policy.model_allowlist model_name
             | None -> true))

let operation_policy_scope_label ~workload_profile ~stage =
  match normalize_stage stage with
  | Some stage_label -> Printf.sprintf "%s/%s" workload_profile stage_label
  | None -> workload_profile

let operation_requires_allowed_tools ~workload_profile ~stage =
  match workload_profile, normalize_stage stage with
  | "coding_task", Some ("implement" | "verify") -> true
  | _ -> false

let operation_requires_allowed_models ~workload_profile ~stage =
  match workload_profile, normalize_stage stage with
  | "research_pipeline", _ -> true
  | "coding_task", Some ("inspect" | "review") -> true
  | _ -> false

let unit_policy_blocker (unit : unit_record) ~workload_profile ~stage =
  let scope = operation_policy_scope_label ~workload_profile ~stage in
  let effective_capabilities = effective_capability_profile unit in
  let effective_tool_tags =
    Cp_search_fabric.tag_values "tool" effective_capabilities
  in
  let effective_model_tags =
    Cp_search_fabric.tag_values "model" effective_capabilities
  in
  if
    operation_requires_allowed_tools ~workload_profile ~stage
    && normalize_allowlist unit.policy.tool_allowlist <> []
    && effective_tool_tags = []
  then
    Some
      (Printf.sprintf
         "assigned unit policy blocks %s: no allowed tool capability remains for unit %s"
         scope unit.unit_id)
  else if
    operation_requires_allowed_models ~workload_profile ~stage
    && normalize_allowlist unit.policy.model_allowlist <> []
    && effective_model_tags = []
  then
    Some
      (Printf.sprintf
         "assigned unit policy blocks %s: no allowed model capability remains for unit %s"
         scope unit.unit_id)
  else
    None

let unit_guard_json_with ~agents ~units config unit_id =
  match lookup_unit units unit_id with
  | None -> Error (Printf.sprintf "assigned unit not found: %s" unit_id)
  | Some unit ->
      let live_count =
        unit.roster
        |> List.filter (roster_name_is_live (live_agent_names agents))
        |> List.length
      in
      let active_count =
        all_operations config units
        |> List.filter (fun (operation : operation_record) ->
               active_operation_status operation.status
               && String.equal operation.assigned_unit_id unit.unit_id)
        |> List.length
      in
      if unit.leader_id = None then
        Error "assigned unit has no leader"
      else if unit.policy.kill_switch then
        Error "assigned unit has kill-switch enabled"
      else if unit.policy.frozen then
        Error "assigned unit is frozen"
      else if live_count = 0 then
        Error "assigned unit has no live agents"
      else if active_count >= unit.budget.active_operation_cap then
        Error
          (Printf.sprintf "assigned unit reached active operation cap (%d)"
             unit.budget.active_operation_cap)
      else
        Ok
          ( unit,
            `Assoc
              [
                ("unit_id", `String unit.unit_id);
                ("live_roster", `Int live_count);
                ("active_operations", `Int active_count);
                ("active_operation_cap", `Int unit.budget.active_operation_cap);
              ] )

let unit_guard_json config unit_id =
  let agents, _, units, _ = topology_units config in
  unit_guard_json_with ~agents ~units config unit_id
  |> Result.map snd

let operation_assignment_guard_json config unit_id ~workload_profile ~stage =
  let agents, _, units, _ = topology_units config in
  match unit_guard_json_with ~agents ~units config unit_id with
  | Error _ as error -> error
  | Ok (unit, guard) -> (
      match unit_policy_blocker unit ~workload_profile ~stage with
      | Some message -> Error message
      | None -> (
          match guard with
          | `Assoc fields ->
              Ok
                (`Assoc
                  ( fields
                  @ [
                      ( "effective_capability_profile",
                        json_list_of_strings (effective_capability_profile unit) );
                    ] ))
          | _ -> Ok guard))

let replace_operation operations (updated : operation_record) =
  updated
  :: List.filter
       (fun (operation : operation_record) ->
         not (String.equal operation.operation_id updated.operation_id))
       operations

let replace_detachment detachments (updated : detachment_record) =
  updated
  :: List.filter
       (fun (detachment : detachment_record) ->
         not (String.equal detachment.detachment_id updated.detachment_id))
       detachments

let lookup_intent intents intent_id =
  List.find_opt
    (fun (intent : intent_record) -> String.equal intent.intent_id intent_id)
    intents

let replace_intent intents (updated : intent_record) =
  updated
  :: List.filter
       (fun (intent : intent_record) ->
         not (String.equal intent.intent_id updated.intent_id))
       intents

let empty_intent_focus =
  {
    stage = None;
    artifact_scope = [];
    unit_id = None;
    verification_state = None;
  }

let verification_state_of_operation (operation : operation_record) =
  match operation.status, operation.stage with
  | Failed, _ -> Some "failed"
  | Cancelled, _ -> Some "cancelled"
  | Completed, Some "review" -> Some "reviewed"
  | Completed, Some "verify" -> Some "verified"
  | Completed, Some "implement" -> Some "implemented"
  | _, Some "review" -> Some "reviewing"
  | _, Some "verify" -> Some "verifying"
  | _, Some "implement" -> Some "implementing"
  | _ -> None

let intent_state_hint_of_operation_status (operation : operation_record) =
  match operation.status with
  | Planned | Active -> Active_intent
  | Paused -> Suspended_intent
  | Completed -> Completed_intent
  | Cancelled -> Dropped_intent
  | Failed -> Blocked_intent

let focus_of_operation (operation : operation_record) =
  {
    stage = operation.stage;
    artifact_scope = operation.artifact_scope;
    unit_id = Some operation.assigned_unit_id;
    verification_state = verification_state_of_operation operation;
  }

let touch_intent_from_operation config ~actor (operation : operation_record)
    ~state =
  match operation.intent_id with
  | None -> ()
  | Some intent_id -> (
      match lookup_intent (read_intents config) intent_id with
      | None -> ()
      | Some intent ->
          let linked_operations =
            let operations : operation_record list = read_operations config in
            let filtered =
              List.filter
                (fun (linked_operation : operation_record) ->
                  match linked_operation.intent_id with
                  | Some current -> String.equal current intent_id
                  | None -> false)
                operations
            in
            List.sort
              (fun (left : operation_record) (right : operation_record) ->
                String.compare right.updated_at left.updated_at)
              filtered
          in
          let aggregated_state =
            if
              List.exists
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Failed)
                linked_operations
            then
              Blocked_intent
            else if
              List.exists
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Active
                  || linked_operation.status = Planned)
                linked_operations
            then
              Active_intent
            else if
              List.exists
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Paused)
                linked_operations
            then
              Suspended_intent
            else if
              linked_operations <> []
              &&
              List.for_all
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Completed)
                linked_operations
            then
              Completed_intent
            else if
              linked_operations <> []
              &&
              List.for_all
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Cancelled)
                linked_operations
            then
              Dropped_intent
            else
              state
          in
          let updated =
            {
              intent with
              state = aggregated_state;
              current_focus = focus_of_operation operation;
              checkpoint_ref =
                option_first_some operation.checkpoint_ref intent.checkpoint_ref;
              updated_at = Types.now_iso ();
            }
          in
          write_intents config (replace_intent (read_intents config) updated);
          append_event config
            {
              event_id = next_event_id "evt";
              trace_id = next_trace_id ();
              event_type = "intent_synced_from_operation";
              operation_id = Some operation.operation_id;
              unit_id = None;
              actor = Some actor;
              source = "control_plane";
              ts = Types.now_iso ();
              detail =
                `Assoc
                  [
                    ("intent_id", `String updated.intent_id);
                    ("intent_state", `String (string_of_intent_state updated.state));
                  ];
            })

let with_intent config intent_id f =
  let intents = read_intents config in
  match lookup_intent intents intent_id with
  | None -> Error (Printf.sprintf "intent not found: %s" intent_id)
  | Some intent -> f intents intent

let stage_order_for_workload = function
  | "coding_task" -> [ "decompose"; "inspect"; "implement"; "verify"; "review" ]
  | "research_pipeline" -> [ "normalize"; "verify"; "curate"; "rank"; "audit" ]
  | _ -> []

let next_stage_for workload_profile stage =
  let order = stage_order_for_workload workload_profile in
  match stage with
  | None ->
      List.nth_opt order 0
  | Some current -> (
      match List.find_opt (fun stage_name -> String.equal stage_name current) order with
      | None -> None
      | Some stage_name ->
          let rec loop = function
            | [] | [ _ ] -> None
            | head :: next :: _ when String.equal head stage_name -> Some next
            | _ :: rest -> loop rest
          in
          loop order)

let append_cp_event config ~trace_id ~event_type ?operation_id ?unit_id ~actor detail =
  append_event config
    {
      event_id = next_event_id "evt";
      trace_id;
      event_type;
      operation_id;
      unit_id;
      actor = Some actor;
      source = "control_plane";
      ts = Types.now_iso ();
      detail;
    }

let detachment_targets_for_operation units (operation : operation_record) =
  let dedup_by_unit_id rows =
    rows
    |> List.sort_uniq (fun (left : unit_record) (right : unit_record) ->
           String.compare left.unit_id right.unit_id)
  in
  match lookup_unit units operation.assigned_unit_id with
  | Some ({ kind = Company | Platoon; _ } as unit) ->
      let squads = descendant_units_of_kind units unit.unit_id Squad |> dedup_by_unit_id in
      if squads = [] then [ unit ] else squads
  | Some ({ kind = Squad; _ } as unit) -> [ unit ]
  | Some ({ kind = Agent_unit; parent_unit_id = Some parent_id; _ } as unit) -> (
      match lookup_unit units parent_id with
      | Some ({ kind = Squad; _ } as squad) -> [ squad ]
      | _ -> [ unit ])
  | Some unit -> [ unit ]
  | None -> []

let detachment_id_for_operation (operation : operation_record) target_count
    (target_unit : unit_record) =
  if target_count <= 1 then
    "det-" ^ operation.operation_id
  else
    Printf.sprintf "det-%s-%s" operation.operation_id (safe_slug target_unit.unit_id)

let detachment_semantic_equal (left : detachment_record) (right : detachment_record) =
  String.equal left.detachment_id right.detachment_id
  && String.equal left.operation_id right.operation_id
  && String.equal left.assigned_unit_id right.assigned_unit_id
  && left.leader_id = right.leader_id
  && left.roster = right.roster
  && left.session_id = right.session_id
  && left.checkpoint_ref = right.checkpoint_ref
  && left.runtime_kind = right.runtime_kind
  && left.runtime_ref = right.runtime_ref
  && String.equal left.source right.source
  && String.equal left.status right.status
  && left.last_event_at = right.last_event_at
  && left.last_progress_at = right.last_progress_at
  && left.heartbeat_deadline = right.heartbeat_deadline
  && String.equal left.created_at right.created_at

let make_detachment_runtime config (target_unit : unit_record) (operation : operation_record)
    ~target_count ~base =
  let session_id =
    if target_count = 1 then operation.detachment_session_id
    else None
  in
  let session_last_event =
    match session_id with
    | Some value -> (
        match Team_session_store.load_session config value with
        | Some session -> Option.map iso_of_unix session.last_event_at
        | None -> None)
    | None -> None
  in
  let last_progress_at =
    match session_last_event, session_id with
    | Some ts, _ -> Some ts
    | None, Some _ ->
        option_first_some base.last_progress_at (Some operation.updated_at)
    | None, None -> Some operation.updated_at
  in
  let last_event_at =
    match session_last_event, session_id with
    | Some ts, _ -> Some ts
    | None, Some _ -> base.last_event_at
    | None, None -> Some operation.updated_at
  in
  let heartbeat_deadline =
    if operation.status = Active || operation.status = Planned then
      Option.bind last_progress_at (fun base_ts ->
          iso_after_seconds base_ts target_unit.policy.escalation_timeout_sec)
    else
      None
  in
  let draft =
    {
      detachment_id = detachment_id_for_operation operation target_count target_unit;
      operation_id = operation.operation_id;
      assigned_unit_id = target_unit.unit_id;
      leader_id = option_first_some target_unit.leader_id base.leader_id;
      roster = if target_unit.roster <> [] then target_unit.roster else base.roster;
      session_id;
      checkpoint_ref = option_first_some operation.checkpoint_ref base.checkpoint_ref;
      runtime_kind =
        (if target_count = 1 && session_id <> None then Some "team_session"
         else Some "managed");
      runtime_ref =
        (if target_count = 1 then option_first_some session_id (Some target_unit.unit_id)
         else Some target_unit.unit_id);
      source = "managed";
      status = string_of_operation_status operation.status;
      last_event_at;
      last_progress_at;
      heartbeat_deadline;
      created_at = base.created_at;
      updated_at = Types.now_iso ();
    }
  in
  if detachment_semantic_equal draft base then
    { draft with updated_at = base.updated_at }
  else
    draft

let default_detachment_for_operation config units (operation : operation_record) =
  let fallback_target =
    match detachment_targets_for_operation units operation with
    | target :: _ -> target
    | [] ->
        {
          unit_id = operation.assigned_unit_id;
          label = operation.assigned_unit_id;
          kind = Squad;
          parent_unit_id = None;
          leader_id = None;
          roster = [];
          capability_profile = [];
          policy = default_policy Squad;
          budget = default_budget Squad;
          source = "managed";
          created_at = operation.created_at;
          updated_at = operation.updated_at;
        }
  in
  make_detachment_runtime config fallback_target operation ~target_count:1
    ~base:
      {
        detachment_id = "det-" ^ operation.operation_id;
        operation_id = operation.operation_id;
        assigned_unit_id = fallback_target.unit_id;
        leader_id = fallback_target.leader_id;
        roster = fallback_target.roster;
        session_id = operation.detachment_session_id;
        checkpoint_ref = operation.checkpoint_ref;
        runtime_kind = None;
        runtime_ref = None;
        source = "managed";
        status = string_of_operation_status operation.status;
        last_event_at = None;
        last_progress_at = Some operation.updated_at;
        heartbeat_deadline = None;
        created_at = operation.created_at;
        updated_at = operation.updated_at;
      }

let search_upstreams operations (operation : operation_record) =
  operation.depends_on_operation_ids
  |> List.map (fun upstream_id ->
         match
           List.find_opt
             (fun (candidate : operation_record) ->
               String.equal candidate.operation_id upstream_id)
             operations
         with
         | Some upstream ->
             {
               Cp_search_fabric.operation_id = upstream.operation_id;
               status = string_of_operation_status upstream.status;
               checkpoint_ref = upstream.checkpoint_ref;
             }
         | None ->
             {
               Cp_search_fabric.operation_id = upstream_id;
               status = "missing";
               checkpoint_ref = None;
             })

let operation_readiness operations operation =
  match operation_search_strategy operation with
  | Cp_search_fabric.Legacy -> Cp_search_fabric.Ready
  | Cp_search_fabric.Best_first_v1 ->
      Cp_search_fabric.readiness_for_operation
        ~upstreams:(search_upstreams operations operation)

let sync_managed_detachments config units (operation : operation_record) =
  let operations = read_operations config in
  let detachments = read_detachments config in
  let existing_for_operation =
    detachments
    |> List.filter (fun (detachment : detachment_record) ->
           String.equal detachment.operation_id operation.operation_id
           && String.equal detachment.source "managed")
  in
  let readiness = operation_readiness operations operation in
  let targets =
    match operation_search_strategy operation, readiness with
    | Cp_search_fabric.Best_first_v1, Cp_search_fabric.Blocked _ -> []
    | _ -> (
        match detachment_targets_for_operation units operation with
        | [] -> []
        | rows -> rows)
  in
  let target_count = max 1 (List.length targets) in
  let updated_rows =
    match operation_search_strategy operation, readiness, targets with
    | Cp_search_fabric.Best_first_v1, Cp_search_fabric.Blocked _, _ -> []
    | _, _, [] ->
        [ default_detachment_for_operation config units operation ]
    | _, _, rows ->
        rows
        |> List.map (fun (target_unit : unit_record) ->
               let detachment_id =
                 detachment_id_for_operation operation target_count target_unit
               in
               let base =
                 existing_for_operation
                 |> List.find_opt (fun (detachment : detachment_record) ->
                        String.equal detachment.detachment_id detachment_id)
                 |> Option.value
                      ~default:
                        {
                          detachment_id;
                          operation_id = operation.operation_id;
                          assigned_unit_id = target_unit.unit_id;
                          leader_id = target_unit.leader_id;
                          roster = target_unit.roster;
                          session_id = operation.detachment_session_id;
                          checkpoint_ref = operation.checkpoint_ref;
                          runtime_kind = None;
                          runtime_ref = None;
                          source = "managed";
                          status = string_of_operation_status operation.status;
                          last_event_at = None;
                          last_progress_at = Some operation.updated_at;
                          heartbeat_deadline = None;
                          created_at = operation.created_at;
                          updated_at = operation.updated_at;
                        }
               in
               make_detachment_runtime config target_unit operation ~target_count ~base)
  in
  let remaining =
    detachments
    |> List.filter (fun (detachment : detachment_record) ->
           not
             (String.equal detachment.operation_id operation.operation_id
              && String.equal detachment.source "managed"))
  in
  write_detachments config (updated_rows @ remaining);
  updated_rows

let sync_managed_detachment config units (operation : operation_record) =
  match sync_managed_detachments config units operation with
  | row :: _ -> row
  | [] -> default_detachment_for_operation config units operation

let with_operation config operation_id f =
  let operations = read_operations config in
  match
    List.find_opt
      (fun (operation : operation_record) ->
        String.equal operation.operation_id operation_id)
      operations
  with
  | None -> Error (Printf.sprintf "operation not found: %s" operation_id)
  | Some current -> f operations current

let rec nearest_ancestor units unit_id predicate =
  match lookup_unit units unit_id with
  | Some unit when predicate unit -> Some unit
  | Some unit -> (
      match unit.parent_unit_id with
      | Some parent_id -> nearest_ancestor units parent_id predicate
      | None -> None)
  | None -> None

let platoon_ancestor_id units unit_id =
  nearest_ancestor units unit_id (fun (unit : unit_record) -> unit.kind = Platoon)
  |> Option.map (fun (unit : unit_record) -> unit.unit_id)

let company_ancestor_id units unit_id =
  nearest_ancestor units unit_id (fun (unit : unit_record) -> unit.kind = Company)
  |> Option.map (fun (unit : unit_record) -> unit.unit_id)

let same_platoon units left right =
  match platoon_ancestor_id units left, platoon_ancestor_id units right with
  | Some a, Some b -> String.equal a b
  | _ -> false

let list_children_of_kind units parent_id kind =
  units
  |> List.filter (fun (unit : unit_record) ->
         unit.kind = kind
         &&
         match unit.parent_unit_id with
         | Some value -> String.equal value parent_id
         | None -> false)

let candidate_units_for_operation units operations current_unit_id =
  let score_unit (unit : unit_record) =
    let active_count =
      operations
      |> List.filter (fun (operation : operation_record) ->
             active_operation_status operation.status
             && String.equal operation.assigned_unit_id unit.unit_id)
      |> List.length
    in
    let capacity_left = max 0 (unit.budget.active_operation_cap - active_count) in
    let same_parent =
      match current_unit_id with
      | Some source -> same_platoon units source unit.unit_id
      | None -> false
    in
    (if same_parent then 1000 else 0) + (capacity_left * 10) + List.length unit.roster
  in
  units
  |> List.filter (fun (unit : unit_record) ->
         (unit.kind = Squad || unit.kind = Platoon)
         && not unit.policy.kill_switch && not unit.policy.frozen)
  |> List.sort (fun a b -> compare (score_unit b, b.label) (score_unit a, a.label))

let decision_requires_approval units source_unit_id target_unit_id =
  match lookup_unit units target_unit_id with
  | None -> true
  | Some target ->
      if target.policy.approval_class = "strict" then
        true
      else
        match source_unit_id with
        | None -> false
        | Some source when String.equal source target_unit_id -> false
        | Some source -> not (same_platoon units source target_unit_id)

let search_operation_descriptor (operation : operation_record) =
  {
    Cp_search_fabric.operation_id = Some operation.operation_id;
    objective = operation.objective;
    assigned_unit_id = Some operation.assigned_unit_id;
    workload_profile = operation_workload_profile operation;
    stage = operation.stage;
    artifact_scope = operation.artifact_scope;
    depends_on_operation_ids = operation.depends_on_operation_ids;
    created_at = operation.created_at;
  }

let operation_active_count operations unit_id =
  operations
  |> List.filter (fun (operation : operation_record) ->
         active_operation_status operation.status
         && String.equal operation.assigned_unit_id unit_id)
  |> List.length

let search_candidates_for_operation config units operations
    (operation : operation_record) =
  let current_unit_id = Some operation.assigned_unit_id in
  let workload_profile = operation_workload_profile operation in
  let stage = operation.stage in
  candidate_units_for_operation units operations current_unit_id
  |> List.filter_map (fun (unit : unit_record) ->
         match
           operation_assignment_guard_json config unit.unit_id ~workload_profile
             ~stage
         with
         | Error _ -> None
         | Ok _ ->
             if decision_requires_approval units current_unit_id unit.unit_id then
               None
             else
                Some
                  {
                   Cp_search_fabric.unit_id = unit.unit_id;
                   label = unit.label;
                   capability_profile = effective_capability_profile unit;
                   active_operation_cap = unit.budget.active_operation_cap;
                   active_operations = operation_active_count operations unit.unit_id;
                   current_assignment = String.equal unit.unit_id operation.assigned_unit_id;
                 })

let candidate_matches_scope candidate scope =
  let haystack =
    String.concat " "
      [ candidate.Cp_search_fabric.unit_id; candidate.label; candidate.routing_reason ]
    |> String.lowercase_ascii
  in
  let terms =
    scope
    |> List.concat_map (fun raw ->
           raw
           |> String.split_on_char '/'
           |> List.concat_map (String.split_on_char '.'))
    |> List.map String.trim
    |> List.filter (fun value -> String.length value >= 3)
  in
  List.exists
    (fun term ->
      let term = String.lowercase_ascii term in
      let len_term = String.length term in
      let len_haystack = String.length haystack in
      let rec loop idx =
        if idx > len_haystack - len_term then false
        else if String.sub haystack idx len_term = term then true
        else loop (idx + 1)
      in
      len_haystack >= len_term && loop 0)
    terms

let apply_intent_forecast_bias ?intents config (operations : operation_record list)
    (operation : operation_record)
    (candidates : Cp_search_fabric.scored_candidate list) =
  let intents =
    match intents with
    | Some intents -> intents
    | None -> read_intents config
  in
  match operation.intent_id with
  | None -> candidates
  | Some intent_id -> (
      match lookup_intent intents intent_id with
      | None -> candidates
      | Some intent ->
          let unresolved_for_operation (current_operation : operation_record) =
            current_operation.depends_on_operation_ids
            |> List.filter_map (fun dep_id ->
                   match operation_by_id operations dep_id with
                   | Some upstream when upstream.status = Completed -> None
                   | Some upstream when Option.is_some upstream.checkpoint_ref -> None
                   | Some upstream -> Some upstream.operation_id
                   | None -> Some dep_id)
          in
          let linked : operation_record list =
            let filtered =
              List.filter
                (fun (linked_operation : operation_record) ->
                  match linked_operation.intent_id with
                  | Some current -> String.equal current intent_id
                  | None -> false)
                operations
            in
            List.sort
              (fun (left : operation_record) (right : operation_record) ->
                String.compare right.updated_at left.updated_at)
              filtered
          in
          let latest_operation = List.nth_opt linked 0 in
          let recommended_stage =
            match latest_operation with
            | Some latest when latest.status = Completed ->
                next_stage_for intent.workload_profile latest.stage
            | Some latest -> latest.stage
            | None ->
                option_first_some (next_stage_for intent.workload_profile intent.current_focus.stage)
                  intent.current_focus.stage
          in
          let recommended_scope =
            match latest_operation with
            | Some latest when latest.artifact_scope <> [] -> latest.artifact_scope
            | _ ->
                if intent.current_focus.artifact_scope <> [] then
                  intent.current_focus.artifact_scope
                else
                  intent.artifact_priors
          in
          let verification_ready =
            match normalize_stage operation.stage with
            | Some ("verify" | "review") -> unresolved_for_operation operation = []
            | _ -> true
          in
          candidates
          |> List.map (fun (candidate : Cp_search_fabric.scored_candidate) ->
                 let intent_successor =
                   (if recommended_stage = operation.stage then 10.0 else 0.0)
                   +. if candidate_matches_scope candidate recommended_scope then 5.0 else 0.0
                 in
                 let verification_readiness =
                   match normalize_stage operation.stage with
                   | Some "verify" ->
                       if verification_ready then 10.0 else 0.0
                   | Some "review" ->
                       if verification_ready then 10.0 else 0.0
                   | _ -> 0.0
                 in
                 let breakdown =
                   {
                     candidate.breakdown with
                     intent_successor;
                     verification_readiness;
                     total =
                       candidate.breakdown.total
                       +. intent_successor +. verification_readiness;
                   }
                 in
                 {
                   candidate with
                   breakdown;
                   routing_reason =
                     Printf.sprintf "%s intent=%.1f verify=%.1f"
                       candidate.routing_reason intent_successor
                       verification_readiness;
                 })
          |> List.sort (fun left right ->
                 let left : Cp_search_fabric.scored_candidate = left in
                 let right : Cp_search_fabric.scored_candidate = right in
                 compare
                   (right.breakdown.total, right.breakdown.capability_match, right.label)
                   (left.breakdown.total, left.breakdown.capability_match, left.label)))

let operation_search_candidates ?store ?intents config units operations
    (operation : operation_record) =
  let stats =
    match store with
    | Some store -> store
    | None -> read_search_stats config
  in
  Cp_search_fabric.score_candidates ~store:stats
    ~operation:(search_operation_descriptor operation)
    ~candidates:(search_candidates_for_operation config units operations operation)
  |> apply_intent_forecast_bias ?intents config operations operation

let take_list n xs =
  let rec loop acc remaining count =
    match remaining, count with
    | _, count when count <= 0 -> List.rev acc
    | [], _ -> List.rev acc
    | item :: rest, _ -> loop (item :: acc) rest (count - 1)
  in
  loop [] xs n

let operation_search_json ?store ?intents config units operations
    (operation : operation_record) =
  let readiness = operation_readiness operations operation in
  let candidates =
    match operation_search_strategy operation with
    | Cp_search_fabric.Legacy -> []
    | Cp_search_fabric.Best_first_v1 ->
        operation_search_candidates ?store ?intents config units operations operation
  in
  let selected_unit_id =
    match candidates with
    | best :: _ -> Some best.Cp_search_fabric.unit_id
    | [] -> Some operation.assigned_unit_id
  in
  let base_json =
    Cp_search_fabric.summary_json
      ~strategy:(operation_search_strategy operation)
      ~readiness ~candidates ~selected_unit_id
  in
  match base_json with
  | `Assoc fields ->
      `Assoc
        ( ("speculation",
           `Assoc
             [
               ("enabled", `Bool (room_speculation_enabled config));
               ( "stage_allowed",
                 `Bool
                   (String.equal (operation_workload_profile operation) "coding_task"
                    &&
                    match normalize_stage operation.stage with
                    | Some ("inspect" | "review") -> true
                    | _ -> false) );
               ("budget", `Int (room_speculation_budget config));
             ] )
        :: fields )
  | other -> other
