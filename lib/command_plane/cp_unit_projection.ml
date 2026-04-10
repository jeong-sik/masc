(** Cp_unit_projection — Projected operations, detachments, and policy decisions
    from team sessions, swarm state, and operator confirmations.

    Extracted from cp_unit to reduce file size. *)

include Cp_io

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

let projected_team_session_operations ?sessions:_ _config _units _managed_operations =
  (* Team session store removed — no projected session operations. *)
  []

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

let projected_team_session_detachments ?sessions:_ _config _operations =
  (* Team session store removed — no projected session detachments. *)
  []

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
