include Cp_io

let validate_parent_kind child_kind parent_kind =
  match child_kind, parent_kind with
  | Company, _ -> false
  | Platoon, Company -> true
  | Squad, Company | Squad, Platoon -> true
  | Agent_unit, Squad -> true
  | _ -> false

let unit_map units =
  List.fold_left (fun acc (unit : unit_record) -> (unit.unit_id, unit) :: acc) [] units

let lookup_unit units unit_id =
  List.find_opt (fun (unit : unit_record) -> String.equal unit.unit_id unit_id) units

let validate_unit_shape units (unit : unit_record) =
  match unit.kind, unit.parent_unit_id with
  | Company, Some _ -> Error "company units cannot have a parent"
  | Company, None -> Ok ()
  | (Platoon | Squad | Agent_unit), None ->
      Error "non-company units require parent_unit_id"
  | kind, Some parent_id -> (
      match lookup_unit units parent_id with
      | None -> Error (Printf.sprintf "parent unit not found: %s" parent_id)
      | Some parent ->
          if validate_parent_kind kind parent.kind then Ok ()
          else
            Error
              (Printf.sprintf "invalid hierarchy: %s cannot be nested under %s"
                 (string_of_unit_kind kind) (string_of_unit_kind parent.kind)))

let resolve_unit_id label kind provided =
  match nonempty_string provided with
  | Some value -> value
  | None ->
      let prefix =
        match kind with
        | Company -> "company"
        | Platoon -> "platoon"
        | Squad -> "squad"
        | Agent_unit -> "agent"
      in
      Printf.sprintf "%s-%s" prefix (safe_slug label)

let effective_units_for_validation config managed_units =
  if lookup_unit managed_units "company-runtime" <> None then
    managed_units
  else
    let live_names =
      Room.get_agents_raw config
      |> List.map (fun (agent : Types.agent) -> agent.name)
      |> List.sort_uniq String.compare
    in
    let now = Types.now_iso () in
    let runtime_root =
      {
        unit_id = "company-runtime";
        label = "Runtime Company";
        kind = Company;
        parent_unit_id = None;
        leader_id = List.nth_opt live_names 0;
        roster = live_names;
        capability_profile = [];
        policy = default_policy Company;
        budget = default_budget Company;
        source = "auto";
        created_at = now;
        updated_at = now;
      }
    in
    runtime_root :: managed_units

let upsert_unit config ~(actor : string) json =
  let managed_units = read_units config in
  let effective_units = effective_units_for_validation config managed_units in
  let kind =
    match
      (match get_string_opt json "kind" with
      | Some value -> unit_kind_of_string value
      | None -> None)
    with
    | Some value -> value
    | None -> invalid_arg "kind is required (company|platoon|squad|agent)"
  in
  let label =
    match get_string_opt json "label" with
    | Some value -> value
    | None -> invalid_arg "label is required"
  in
  let unit_id = resolve_unit_id label kind (get_string_opt json "unit_id") in
  let existing = lookup_unit managed_units unit_id in
  let created_at =
    match existing with
    | Some unit -> unit.created_at
    | None -> Types.now_iso ()
  in
  let policy_json =
    match U.member "policy" json with `Assoc _ as value -> value | _ -> `Assoc []
  in
  let budget_json =
    match U.member "budget" json with `Assoc _ as value -> value | _ -> `Assoc []
  in
  let unit =
    {
      unit_id;
      label;
      kind;
      parent_unit_id = get_string_opt json "parent_unit_id";
      leader_id = get_string_opt json "leader_id";
      roster = get_string_list json "roster";
      capability_profile = get_string_list json "capability_profile";
      policy = policy_of_json policy_json kind;
      budget = budget_of_json budget_json kind;
      source = "managed";
      created_at;
      updated_at = Types.now_iso ();
    }
  in
  match
    validate_unit_shape
      (List.filter
         (fun (row : unit_record) -> not (String.equal row.unit_id unit_id))
         effective_units)
      unit
  with
  | Error message -> Error message
  | Ok () ->
      let next_units =
        unit
        :: List.filter
             (fun (row : unit_record) -> not (String.equal row.unit_id unit_id))
             managed_units
      in
      write_units config next_units;
      append_event config
        {
          event_id = next_event_id "evt";
          trace_id = next_trace_id ();
          event_type =
            if existing = None then "unit_defined" else "unit_updated";
          operation_id = None;
          unit_id = Some unit_id;
          actor = Some actor;
          source = "control_plane";
          ts = Types.now_iso ();
          detail =
            `Assoc
              [
                ("label", `String label);
                ("kind", `String (string_of_unit_kind kind));
                ("roster_size", `Int (List.length unit.roster));
              ];
        };
      Ok unit

let auto_leaf_unit agent_name squad_id =
  let now = Types.now_iso () in
  {
    unit_id = Printf.sprintf "agent-%s" (safe_slug agent_name);
    label = agent_name;
    kind = Agent_unit;
    parent_unit_id = Some squad_id;
    leader_id = Some agent_name;
    roster = [ agent_name ];
    capability_profile = [];
    policy = default_policy Agent_unit;
    budget = default_budget Agent_unit;
    source = "auto";
    created_at = now;
    updated_at = now;
  }

let chunk size xs =
  let rec loop acc current n rest =
    match rest with
    | [] ->
        let acc' = if current = [] then acc else List.rev current :: acc in
        List.rev acc'
    | x :: tail ->
        if n = size then
          loop (List.rev current :: acc) [ x ] 1 tail
        else
          loop acc (x :: current) (n + 1) tail
  in
  if size <= 0 then [ xs ] else loop [] [] 0 xs

let build_auto_units agents =
  let live_names =
    agents
    |> List.map (fun (agent : Types.agent) -> agent.name)
    |> List.sort_uniq String.compare
  in
  let now = Types.now_iso () in
  let company_id = "company-runtime" in
  let company =
    {
      unit_id = company_id;
      label = "Runtime Company";
      kind = Company;
      parent_unit_id = None;
      leader_id = List.nth_opt live_names 0;
      roster = live_names;
      capability_profile = [];
      policy = default_policy Company;
      budget = default_budget Company;
      source = "auto";
      created_at = now;
      updated_at = now;
    }
  in
  let platoon_chunks = chunk 24 live_names in
  let units = ref [ company ] in
  List.iteri
    (fun platoon_idx platoon_roster ->
      let platoon_id = Printf.sprintf "platoon-auto-%02d" (platoon_idx + 1) in
      let platoon =
        {
          unit_id = platoon_id;
          label = Printf.sprintf "Platoon %d" (platoon_idx + 1);
          kind = Platoon;
          parent_unit_id = Some company_id;
          leader_id = List.nth_opt platoon_roster 0;
          roster = platoon_roster;
          capability_profile = [];
          policy = default_policy Platoon;
          budget = default_budget Platoon;
          source = "auto";
          created_at = now;
          updated_at = now;
        }
      in
      units := platoon :: !units;
      platoon_roster
      |> chunk 6
      |> List.iteri (fun squad_idx squad_roster ->
             let squad_id =
               Printf.sprintf "squad-auto-%02d-%02d" (platoon_idx + 1) (squad_idx + 1)
             in
             let squad =
               {
                 unit_id = squad_id;
                 label = Printf.sprintf "Squad %d.%d" (platoon_idx + 1) (squad_idx + 1);
                 kind = Squad;
                 parent_unit_id = Some platoon_id;
                 leader_id = List.nth_opt squad_roster 0;
                 roster = squad_roster;
                 capability_profile = [];
                 policy = default_policy Squad;
                 budget = default_budget Squad;
                 source = "auto";
                 created_at = now;
                 updated_at = now;
               }
             in
             units := squad :: !units;
             List.iter (fun agent_name -> units := auto_leaf_unit agent_name squad_id :: !units) squad_roster))
    platoon_chunks;
  List.rev !units

let augment_managed_units units agents =
  let live_names =
    agents
    |> List.map (fun (agent : Types.agent) -> agent.name)
    |> List.sort_uniq String.compare
  in
  if units = [] then
    build_auto_units agents
  else
    let now = Types.now_iso () in
    let missing_parent unit =
      match unit.parent_unit_id with
      | None -> true
      | Some parent_id -> lookup_unit units parent_id = None
    in
    let roots = List.filter missing_parent units in
    let roots_need_runtime_root =
      match roots with
      | [ root ] when root.kind = Company -> false
      | _ -> true
    in
    let runtime_root_id = "company-runtime" in
    let rewritten_units =
      if roots_need_runtime_root then
        List.map
          (fun unit ->
            if missing_parent unit then
              { unit with parent_unit_id = Some runtime_root_id }
            else
              unit)
          units
      else
        units
    in
    (* BUG-002: Preserve existing leader if still live, instead of always
       picking the first alphabetically sorted name. *)
    let existing_company_leader =
      match List.find_opt (fun (u : unit_record) -> u.kind = Company) units with
      | Some u -> u.leader_id
      | None -> None
    in
    let pick_leader_stable ~existing_leader candidates =
      match existing_leader with
      | Some leader when List.mem leader candidates -> Some leader
      | _ -> List.nth_opt candidates 0
    in
    let root_units =
      if roots_need_runtime_root then
        [
          {
            unit_id = runtime_root_id;
            label = "Runtime Company";
            kind = Company;
            parent_unit_id = None;
            leader_id = pick_leader_stable ~existing_leader:existing_company_leader live_names;
            roster = live_names;
            capability_profile = [];
            policy = default_policy Company;
            budget = default_budget Company;
            source = "auto";
            created_at = now;
            updated_at = now;
          };
        ]
      else
        []
    in
    let assigned_agents =
      rewritten_units
      |> List.concat_map (fun (unit : unit_record) -> unit.roster)
      |> List.sort_uniq String.compare
    in
    let unassigned =
      live_names |> List.filter (fun agent_name -> not (List.mem agent_name assigned_agents))
    in
    let fallback_parent_id =
      rewritten_units
      |> List.find_opt (fun (unit : unit_record) -> unit.kind = Platoon)
      |> Option.map (fun (unit : unit_record) -> unit.unit_id)
      |> option_first_some
           (rewritten_units
           |> List.find_opt (fun (unit : unit_record) -> unit.kind = Company)
           |> Option.map (fun (unit : unit_record) -> unit.unit_id))
      |> Option.value ~default:runtime_root_id
    in
    let unassigned_units =
      if unassigned = [] then
        []
      else
        let squad_id = "squad-unassigned" in
        let existing_squad_leader =
          match List.find_opt (fun (u : unit_record) -> u.unit_id = squad_id) units with
          | Some u -> u.leader_id
          | None -> None
        in
        let squad =
          {
            unit_id = squad_id;
            label = "Unassigned Squad";
            kind = Squad;
            parent_unit_id = Some fallback_parent_id;
            leader_id = pick_leader_stable ~existing_leader:existing_squad_leader unassigned;
            roster = unassigned;
            capability_profile = [ "unassigned" ];
            policy = default_policy Squad;
            budget = default_budget Squad;
            source = "auto";
            created_at = now;
            updated_at = now;
          }
        in
        squad :: List.map (fun agent_name -> auto_leaf_unit agent_name squad_id) unassigned
    in
    root_units @ rewritten_units @ unassigned_units

let operation_status_of_session (status : Team_session_types.session_status) =
  match status with
  | Running -> Active
  | Paused -> Paused
  | Completed -> Completed
  | Interrupted -> Cancelled
  | Cancelled -> Cancelled
  | Failed -> Failed

let choose_unit_for_session units (session : Team_session_types.session) =
  let session_agents = session.agent_names |> filter_nonempty_strings in
  let overlap (unit : unit_record) =
    List.fold_left
      (fun acc agent_name -> if List.mem agent_name unit.roster then acc + 1 else acc)
      0 session_agents
  in
  let cmp (score_a, rank_a, roster_a) (score_b, rank_b, roster_b) =
    match Int.compare score_a score_b with
    | 0 -> (
        match Int.compare rank_b rank_a with
        | 0 -> Int.compare roster_b roster_a
        | other -> other)
    | other -> other
  in
  let candidates : (unit_record * int * int * int) list =
    units
    |> List.filter (fun (unit : unit_record) ->
           unit.kind = Squad || unit.kind = Platoon || unit.kind = Company)
    |> List.map (fun (unit : unit_record) ->
           (unit, overlap unit, kind_order unit.kind, List.length unit.roster))
  in
  candidates
  |> List.sort (fun (_, score_a, rank_a, roster_a) (_, score_b, rank_b, roster_b) ->
         cmp (score_b, rank_b, roster_b) (score_a, rank_a, roster_a))
  |> List.filter (fun (_unit, score, _rank, _roster) -> score > 0)
  |> List.map (fun ((unit : unit_record), _, _, _) -> unit.unit_id)
  |> list_hd_opt

let iso_of_unix = Dashboard_utils.iso_of_unix

let days_from_civil year month day =
  let year = if month <= 2 then year - 1 else year in
  let era = if year >= 0 then year / 400 else (year - 399) / 400 in
  let yoe = year - (era * 400) in
  let month_prime = if month > 2 then month - 3 else month + 9 in
  let doy = ((153 * month_prime) + 2) / 5 + day - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let parse_iso_timestamp (s : string) : float option =
  try
    let open Scanf in
    sscanf s "%04d-%02d-%02dT%02d:%02d:%02dZ" (fun y m d h min sec ->
        let days = days_from_civil y m d in
        let seconds =
          (days * 86_400) + (h * 3_600) + (min * 60) + sec
        in
        Some (float_of_int seconds))
  with Scanf.Scan_failure _ | Failure _ | End_of_file -> None

let iso_after_seconds base seconds =
  parse_iso_timestamp base
  |> Option.map (fun ts -> iso_of_unix (ts +. float_of_int seconds))

let iso_expired_at now deadline =
  match parse_iso_timestamp deadline with
  | Some ts -> ts <= now
  | None -> false

let rec descendant_units_of_kind units unit_id kind =
  let direct_children =
    units
    |> List.filter (fun (unit : unit_record) ->
           match unit.parent_unit_id with
           | Some parent_id -> String.equal parent_id unit_id
           | None -> false)
  in
  let direct_matches =
    direct_children
    |> List.filter (fun (unit : unit_record) -> unit.kind = kind)
  in
  direct_matches
  @ List.concat_map
      (fun (child : unit_record) -> descendant_units_of_kind units child.unit_id kind)
      direct_children

let projected_team_session_operations ?sessions config units managed_operations =
  let managed_session_ids =
    managed_operations
    |> List.filter_map (fun (operation : operation_record) -> operation.detachment_session_id)
    |> List.sort_uniq String.compare
  in
  let all_sessions =
    match sessions with
    | Some s -> s
    | None -> Team_session_store.list_sessions config
  in
  all_sessions
  |> List.filter (fun (session : Team_session_types.session) ->
         not (List.mem session.session_id managed_session_ids))
  |> List.map (fun (session : Team_session_types.session) ->
         let assigned_unit_id =
           choose_unit_for_session units session
           |> Option.value
                ~default:
                  (match units with
                  | (unit : unit_record) :: _ -> unit.unit_id
                  | [] -> "company-runtime")
         in
         {
           operation_id = "detachment-" ^ session.session_id;
           objective = session.goal;
           intent_id = None;
           assigned_unit_id;
           autonomy_level =
             Team_session_types.orchestration_mode_to_string session.orchestration_mode;
           policy_class =
             Team_session_types.execution_scope_to_string session.execution_scope;
           budget_class =
             Team_session_types.communication_mode_to_string session.communication_mode;
           workload_template = None;
           workload_profile = "coding_task";
           stage = Some "implement";
           artifact_scope = [];
           depends_on_operation_ids = [];
           search_strategy = room_search_strategy_default config;
           detachment_session_id = Some session.session_id;
           trace_id = session.session_id;
           checkpoint_ref = nonempty_string (Some session.artifacts_dir);
           active_goal_ids = [];
           note = session.stop_reason;
           created_by = session.created_by;
           source = "projected";
           status = operation_status_of_session session.status;
           chain = None;
           created_at = session.created_at_iso;
           updated_at = session.updated_at_iso;
         })

let projected_swarm_operations config units managed_operations =
  let swarm_json =
    if Room_utils.path_exists config (swarm_path config) then
      Room_utils.read_json_opt config (swarm_path config)
    else
      None
  in
  match swarm_json with
  | Some (`Assoc _ as root) ->
      let config_json =
        match U.member "config" root with `Assoc _ as value -> value | _ -> `Assoc []
      in
      let swarm_id = get_string_default config_json "id" "swarm-runtime" in
      let operation_id = "swarm-" ^ safe_slug swarm_id in
      let already_managed =
        List.exists (fun (operation : operation_record) -> String.equal operation.operation_id operation_id) managed_operations
      in
      if already_managed then
        []
      else
        let swarm_name = get_string_default config_json "name" "Runtime Swarm" in
        let behavior = get_string_default config_json "behavior" "flocking" in
        let generation = get_int_default root "generation" 0 in
        let assigned_unit_id =
          units
          |> List.find_opt (fun (unit : unit_record) -> unit.kind = Company)
          |> Option.map (fun (unit : unit_record) -> unit.unit_id)
          |> Option.value ~default:"company-runtime"
        in
        let last_evolution =
          match U.member "last_evolution" root with
          | `Float value -> iso_of_unix value
          | `Int value -> iso_of_unix (float_of_int value)
          | _ -> Types.now_iso ()
        in
        [
          {
            operation_id;
            objective = Printf.sprintf "Swarm %s (%s) generation %d" swarm_name behavior generation;
            intent_id = None;
            assigned_unit_id;
            autonomy_level = "L5_Independent";
            policy_class = "swarm";
            budget_class = "adaptive";
            workload_template = None;
            workload_profile = "coding_task";
            stage = None;
            artifact_scope = [];
            depends_on_operation_ids = [];
            search_strategy = room_search_strategy_default config;
            detachment_session_id = None;
            trace_id = "swarm-trace-" ^ safe_slug swarm_id;
            checkpoint_ref = None;
            active_goal_ids = [];
            note = Some (Printf.sprintf "Projected from .masc/swarm.json with behavior=%s" behavior);
            created_by = "swarm";
            source = "projected";
            status = Active;
            chain = None;
            created_at = last_evolution;
            updated_at = last_evolution;
          };
        ]
  | _ -> []

let all_operations ?sessions config units =
  let managed = read_operations config in
  managed
  @ projected_team_session_operations ?sessions config units managed
  @ projected_swarm_operations config units managed

let operation_by_id operations operation_id =
  List.find_opt
    (fun (operation : operation_record) -> String.equal operation.operation_id operation_id)
    operations

let projected_team_session_detachments ?sessions config operations =
  let find_session session_id =
    match sessions with
    | Some cached ->
        List.find_opt
          (fun (s : Team_session_types.session) ->
            String.equal s.session_id session_id)
          cached
    | None -> Team_session_store.load_session config session_id
  in
  operations
  |> List.filter_map (fun (operation : operation_record) ->
         match operation.detachment_session_id with
         | None when operation.source = "projected" -> None
         | None -> None
         | Some session_id -> (
             match find_session session_id with
             | None -> None
             | Some session ->
                 Some
                   {
                     detachment_id = "detachment-" ^ session_id;
                     operation_id = operation.operation_id;
                     assigned_unit_id = operation.assigned_unit_id;
                     leader_id = Some session.created_by;
                     roster = filter_nonempty_strings session.agent_names;
                     session_id = Some session_id;
                     checkpoint_ref = nonempty_string (Some session.artifacts_dir);
                     runtime_kind = Some "team_session";
                     runtime_ref = Some session_id;
                     source = "projected";
                     status = string_of_operation_status operation.status;
                     last_event_at = Option.map iso_of_unix session.last_event_at;
                     last_progress_at = Option.map iso_of_unix session.last_event_at;
                     heartbeat_deadline = None;
                     created_at = session.created_at_iso;
                     updated_at = session.updated_at_iso;
                   }))

let projected_swarm_detachments config operations =
  let swarm_json =
    if Room_utils.path_exists config (swarm_path config) then
      Room_utils.read_json_opt config (swarm_path config)
    else
      None
  in
  match swarm_json with
  | Some (`Assoc _ as root) ->
      let config_json =
        match U.member "config" root with `Assoc _ as value -> value | _ -> `Assoc []
      in
      let swarm_id = get_string_default config_json "id" "swarm-runtime" in
      let operation_id = "swarm-" ^ safe_slug swarm_id in
      let roster =
        match U.member "agents" root with
        | `List rows ->
            rows
            |> List.filter_map (fun row ->
                   match row with
                   | `Assoc _ ->
                       option_first_some (get_string_opt row "name") (get_string_opt row "id")
                   | _ -> None)
            |> dedup_strings
        | _ -> []
      in
      (match operation_by_id operations operation_id with
      | None -> []
      | Some operation ->
          let last_evolution =
            match U.member "last_evolution" root with
            | `Float value -> Some (iso_of_unix value)
            | `Int value -> Some (iso_of_unix (float_of_int value))
            | _ -> None
          in
          [
            {
              detachment_id = "detachment-" ^ safe_slug swarm_id;
              operation_id;
              assigned_unit_id = operation.assigned_unit_id;
              leader_id = list_hd_opt roster;
              roster;
              session_id = None;
              checkpoint_ref = None;
              runtime_kind = Some "swarm_projection";
              runtime_ref = Some swarm_id;
              source = "projected";
              status = "active";
              last_event_at = last_evolution;
              last_progress_at = last_evolution;
              heartbeat_deadline = None;
              created_at = Option.value ~default:(Types.now_iso ()) last_evolution;
              updated_at = Option.value ~default:(Types.now_iso ()) last_evolution;
            };
          ])
  | _ -> []

let all_detachments ?sessions config units operations =
  let managed = read_detachments config in
  let managed_operation_ids =
    managed
    |> List.map (fun (detachment : detachment_record) -> detachment.operation_id)
    |> List.sort_uniq String.compare
  in
  let projected_ops =
    operations
    |> List.filter (fun (operation : operation_record) ->
           not (List.mem operation.operation_id managed_operation_ids))
  in
  let _ = units in
  managed
  @ projected_team_session_detachments ?sessions config projected_ops
  @ projected_swarm_detachments config projected_ops

let projected_operator_decisions config =
  if not (Room_utils.path_exists config (operator_pending_confirms_path config)) then
    []
  else
    match Room_utils.read_json_opt config (operator_pending_confirms_path config) with
    | Some (`List rows) ->
        rows
        |> List.filter_map (fun row ->
               let decision_id =
                 option_first_some
                   (get_string_opt row "token")
                   (get_string_opt row "trace_id")
               in
               let requested_action = get_string_default row "action_type" "operator_action" in
               let scope_type = get_string_default row "target_type" "operator" in
               let scope_id =
                 get_string_default row "target_id"
                   (get_string_default row "trace_id" "operator")
               in
               match decision_id with
               | None -> None
               | Some token ->
                   Some
                     {
                       decision_id = "legacy-" ^ token;
                       trace_id = get_string_default row "trace_id" token;
                       requested_action;
                       scope_type;
                       scope_id;
                       operation_id = None;
                       target_unit_id = None;
                       requested_by = get_string_default row "actor" "operator";
                       status = "pending";
                       reason = Some "Projected from operator pending confirmation queue";
                       source = "projected_operator";
                       detail = row;
                       created_at = get_string_default row "created_at" (Types.now_iso ());
                       decided_at = None;
                       expires_at = get_string_opt row "expires_at";
                     })
    | _ -> []

let all_policy_decisions config =
  let managed = read_policy_decisions config in
  let managed_ids =
    managed
    |> List.map (fun (decision : policy_decision_record) -> decision.decision_id)
    |> List.sort_uniq String.compare
  in
  let projected =
    projected_operator_decisions config
    |> List.filter (fun (decision : policy_decision_record) ->
           not (List.mem decision.decision_id managed_ids))
  in
  managed @ projected

let live_agent_names agents =
  agents
  |> List.filter (fun (agent : Types.agent) ->
         match agent.status with
         | Active | Busy | Listening -> true
         | Inactive -> false)
  |> List.map (fun (agent : Types.agent) -> agent.name)
  |> List.sort_uniq String.compare

let agent_status_map agents =
  List.map (fun (agent : Types.agent) -> (agent.name, Types.string_of_agent_status agent.status)) agents

let agent_status_for agents agent_name =
  match List.assoc_opt agent_name agents with
  | Some status -> status
  | None -> "offline"

let active_operation_status = function
  | Active | Planned -> true
  | Paused | Completed | Cancelled | Failed -> false

let children_map units =
  List.fold_left
    (fun acc unit ->
      match unit.parent_unit_id with
      | None -> acc
      | Some parent_id ->
          let existing = match List.assoc_opt parent_id acc with Some xs -> xs | None -> [] in
          (parent_id, unit :: existing)
          :: List.remove_assoc parent_id acc)
    [] units

let rec descendant_ids child_map unit_id =
  let children = match List.assoc_opt unit_id child_map with Some xs -> xs | None -> [] in
  let direct = List.map (fun (unit : unit_record) -> unit.unit_id) children in
  direct @ List.concat_map (fun child_id -> descendant_ids child_map child_id) direct

let rec build_tree_json ~child_map ~unit_lookup ~agent_statuses ~live_agents ~operations unit_id =
  match List.assoc_opt unit_id unit_lookup with
  | None -> None
  | Some (unit : unit_record) ->
      let children =
        match List.assoc_opt unit_id child_map with
        | Some rows ->
            rows
            |> List.sort (fun (a : unit_record) (b : unit_record) ->
                   compare (kind_order a.kind, a.label) (kind_order b.kind, b.label))
            |> List.filter_map (fun (child : unit_record) ->
                   build_tree_json ~child_map ~unit_lookup ~agent_statuses
                     ~live_agents ~operations child.unit_id)
        | None -> []
      in
      let descendants = descendant_ids child_map unit_id in
      let covered_unit_ids = unit_id :: descendants in
      let descendant_op_count =
        operations
        |> List.filter (fun (operation : operation_record) ->
               active_operation_status operation.status
               && List.mem operation.assigned_unit_id covered_unit_ids)
        |> List.length
      in
      let live_roster =
        unit.roster |> List.filter (fun name -> List.mem name live_agents) |> List.length
      in
      let leader_status =
        match unit.leader_id with
        | Some leader -> agent_status_for agent_statuses leader
        | None -> "missing"
      in
      let reasons = ref [] in
      if unit.leader_id = None then reasons := "leader_missing" :: !reasons;
      if unit.leader_id <> None && leader_status = "offline" then reasons := "leader_offline" :: !reasons;
      if List.length unit.roster > unit.budget.headcount_cap then reasons := "headcount_cap_exceeded" :: !reasons;
      if descendant_op_count > unit.budget.active_operation_cap then
        reasons := "active_operation_cap_exceeded" :: !reasons;
      if unit.roster <> [] && live_roster = 0 then reasons := "roster_offline" :: !reasons;
      let health =
        if List.exists (fun reason ->
               reason = "leader_offline" || reason = "active_operation_cap_exceeded")
             !reasons
        then "bad"
        else if !reasons <> [] then "warn"
        else "ok"
      in
      let cleanup_days = Env_config_runtime.Cp.cleanup_days in
      let stale_cutoff = Cp_cleanup.cutoff_iso ~days:cleanup_days in
      let is_stale = unit.updated_at < stale_cutoff in
      if is_stale then reasons := "stale" :: !reasons;
      Some
        (`Assoc
          [
            ("unit", unit_to_json unit);
            ("leader_status", `String leader_status);
            ("roster_total", `Int (List.length unit.roster));
            ("roster_live", `Int live_roster);
            ("roster_health",
             `Assoc
               [
                 ("total", `Int (List.length unit.roster));
                 ("live", `Int live_roster);
                 ("offline", `Int (List.length unit.roster - live_roster));
               ]);
            ("active_operation_count", `Int descendant_op_count);
            ("is_stale", `Bool is_stale);
            ("health", `String health);
            ("reasons", json_list_of_strings (List.rev !reasons));
            ("children", `List children);
          ])

let topology_units config =
  (* BUG-012: Filter to only actually-joined agents to prevent phantom entries *)
  let agents =
    Room.get_agents_raw config
    |> List.filter (fun (agent : Types.agent) ->
         try Room.is_agent_joined config ~agent_name:agent.name with Sys_error _ | Not_found -> false)
  in
  let managed_units = read_units config in
  let normalized_units = augment_managed_units managed_units agents in
  let source =
    if managed_units = [] then "auto"
    else if List.length normalized_units > List.length managed_units then "hybrid"
    else "explicit"
  in
  (agents, managed_units, normalized_units, source)
