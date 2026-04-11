include Cp_unit_projection

let safe_live_agents config =
  Room.get_active_agents config
  |> List.filter (fun (agent : Types.agent) ->
         try Room.is_agent_joined config ~agent_name:agent.name with
         | Sys_error _ | Not_found -> false)

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
      safe_live_agents config
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
    Option.bind (get_string_opt json "kind") unit_kind_of_string
    |> function
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
    existing
    |> Option.map (fun (unit : unit_record) -> unit.created_at)
    |> Option.value ~default:(Types.now_iso ())
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
    let existing_company_leader =
      Option.bind
        (List.find_opt (fun (u : unit_record) -> u.kind = Company) units)
        (fun (u : unit_record) -> u.leader_id)
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
          Option.bind
            (List.find_opt (fun (u : unit_record) -> u.unit_id = squad_id) units)
            (fun (u : unit_record) -> u.leader_id)
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

let rec descendant_units_of_kind units unit_id kind =
  let direct_children =
    units
    |> List.filter (fun (unit : unit_record) ->
           option_exists (String.equal unit_id) unit.parent_unit_id)
  in
  let direct_matches =
    direct_children
    |> List.filter (fun (unit : unit_record) -> unit.kind = kind)
  in
  direct_matches
  @ List.concat_map
      (fun (child : unit_record) -> descendant_units_of_kind units child.unit_id kind)
      direct_children

let live_agent_names agents =
  agents
  |> List.filter (fun (agent : Types.agent) ->
         match agent.status with
         | Active | Busy | Listening -> true
         | Inactive -> false)
  |> List.map (fun (agent : Types.agent) -> agent.name)
  |> List.sort_uniq String.compare

let live_agent_name_matches expected live_name =
  String.equal expected live_name
  || String.starts_with ~prefix:(expected ^ "-") live_name

let roster_name_is_live live_agents roster_name =
  List.exists (live_agent_name_matches roster_name) live_agents

let agent_status_map agents =
  List.map (fun (agent : Types.agent) -> (agent.name, Types.string_of_agent_status agent.status)) agents

let agent_status_for agents agent_name =
  match List.assoc_opt agent_name agents with
  | Some status -> status
  | None ->
      agents
      |> List.find_map (fun (live_name, status) ->
             if live_agent_name_matches agent_name live_name then
               Some status
             else
               None)
      |> Option.value ~default:"offline"

let active_operation_status = function
  | Active | Planned -> true
  | Paused | Completed | Cancelled | Failed -> false

let children_map units =
  List.fold_left
    (fun acc unit ->
      match unit.parent_unit_id with
      | None -> acc
      | Some parent_id ->
          let existing = List.assoc_opt parent_id acc |> Option.value ~default:[] in
          (parent_id, unit :: existing)
          :: List.remove_assoc parent_id acc)
    [] units

let _max_tree_depth = 50

(* [descendant_ids] was the Stack_overflow culprit for #6633: the visited-list
   cycle check catches true cycles but provides no protection against deep
   non-cyclic chains, and [@]/[List.concat_map] are non-tail so every level
   holds a stack frame.  Bound the recursion with [_max_tree_depth] (same
   ceiling used by [build_tree_json]) so a deep unit chain cannot blow the
   stack.  Returns the partial descendant list when the guard fires, matching
   the cycle-truncation branch's "best-effort" behaviour. *)
let rec descendant_ids ?(depth = 0) ?(visited = []) child_map unit_id =
  if depth > _max_tree_depth || List.mem unit_id visited then []
  else
  let visited = unit_id :: visited in
  let children = List.assoc_opt unit_id child_map |> Option.value ~default:[] in
  let direct = List.map (fun (unit : unit_record) -> unit.unit_id) children in
  direct
  @ List.concat_map
      (fun child_id ->
        descendant_ids ~depth:(depth + 1) ~visited child_map child_id)
      direct

let rec build_tree_json ?(depth = 0) ?(visited = [])
    ~child_map ~unit_lookup ~agent_statuses ~live_agents ~operations unit_id =
  if depth > _max_tree_depth || List.mem unit_id visited then None
  else
  let visited = unit_id :: visited in
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
                   build_tree_json ~depth:(depth + 1) ~visited
                     ~child_map ~unit_lookup ~agent_statuses
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
        unit.roster
        |> List.filter (roster_name_is_live live_agents)
        |> List.length
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

(* O(n + ops) indexed version — uses pre-computed Hashtbl lookups.
   Produces identical JSON output as build_tree_json.
   depth/visited guards prevent Stack_overflow on cyclic or deep graphs. *)
let rec build_tree_json_indexed ?(depth = 0) ?(visited = [])
    ~(tree_idx : Cp_tree_index.tree_index) unit_id =
  if depth > _max_tree_depth || List.mem unit_id visited then None
  else
  let visited = unit_id :: visited in
  match Hashtbl.find_opt tree_idx.unit_tbl unit_id with
  | None -> None
  | Some (unit : unit_record) ->
      let children =
        match Hashtbl.find_opt tree_idx.child_tbl unit_id with
        | Some rows ->
            rows
            |> List.sort (fun (a : unit_record) (b : unit_record) ->
                   compare (kind_order a.kind, a.label) (kind_order b.kind, b.label))
            |> List.filter_map (fun (child : unit_record) ->
                   build_tree_json_indexed ~depth:(depth + 1) ~visited
                     ~tree_idx child.unit_id)
        | None -> []
      in
      let descendant_op_count =
        Hashtbl.find_opt tree_idx.subtree_active_ops unit_id
        |> Option.value ~default:0
      in
      let live_roster =
        Hashtbl.find_opt tree_idx.live_roster_count unit_id
        |> Option.value ~default:0
      in
      let leader_status =
        match unit.leader_id with
        | Some leader -> Cp_tree_index.agent_status_for_tbl tree_idx leader
        | None -> "missing"
      in
      let reasons = ref [] in
      if unit.leader_id = None then reasons := "leader_missing" :: !reasons;
      if unit.leader_id <> None && leader_status = "offline" then
        reasons := "leader_offline" :: !reasons;
      if List.length unit.roster > unit.budget.headcount_cap then
        reasons := "headcount_cap_exceeded" :: !reasons;
      if descendant_op_count > unit.budget.active_operation_cap then
        reasons := "active_operation_cap_exceeded" :: !reasons;
      if unit.roster <> [] && live_roster = 0 then
        reasons := "roster_offline" :: !reasons;
      let health =
        if
          List.exists
            (fun reason ->
              reason = "leader_offline"
              || reason = "active_operation_cap_exceeded")
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
  let agents = safe_live_agents config in
  let managed_units = read_units config in
  let normalized_units = augment_managed_units managed_units agents in
  let source =
    if managed_units = [] then "auto"
    else if List.length normalized_units > List.length managed_units then "hybrid"
    else "explicit"
  in
  (agents, managed_units, normalized_units, source)
