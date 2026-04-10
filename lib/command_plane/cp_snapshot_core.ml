include Cp_unit

type snapshot_state = {
  config : Room.config;
  agents : Types.agent list;
  managed_units : unit_record list;
  units : unit_record list;
  source : string;
  intents : intent_record list;
  operations : operation_record list;
  detachments : detachment_record list;
  decisions : policy_decision_record list;
  live_agents : string list;
  status_map : (string * string) list;
  child_map : (string * unit_record list) list;
  unit_lookup : (string * unit_record) list;
  tree_idx : Cp_tree_index.tree_index;
}

let count_operation_statuses operations =
  List.fold_left
    (fun (acc : operation_status_counts) (op : operation_record) ->
      match op.status with
      | Planned -> { acc with planned_count = acc.planned_count + 1 }
      | Active -> { acc with active_count = acc.active_count + 1 }
      | Paused -> { acc with paused_count = acc.paused_count + 1 }
      | Completed -> { acc with completed_count = acc.completed_count + 1 }
      | Failed -> { acc with failed_count = acc.failed_count + 1 }
      | Cancelled -> { acc with cancelled_count = acc.cancelled_count + 1 })
    { planned_count = 0; active_count = 0; paused_count = 0;
      completed_count = 0; failed_count = 0; cancelled_count = 0 }
    operations

let build_topology_summary ~units ~managed_units ~agents ~operations =
  let stale_cutoff = Cp_cleanup.cutoff_iso ~days:Env_config_runtime.Cp.cleanup_days in
  let op_counts = count_operation_statuses operations in
  {
    total_units = List.length units;
    company_count = List.length (List.filter (fun (u : unit_record) -> u.kind = Company) units);
    platoon_count = List.length (List.filter (fun (u : unit_record) -> u.kind = Platoon) units);
    squad_count = List.length (List.filter (fun (u : unit_record) -> u.kind = Squad) units);
    leaf_agent_unit_count = List.length (List.filter (fun (u : unit_record) -> u.kind = Agent_unit) units);
    live_agent_count = List.length (live_agent_names agents);
    managed_unit_count = List.length managed_units;
    active_operation_count = op_counts.planned_count + op_counts.active_count + op_counts.paused_count;
    stale_unit_count =
      List.length (List.filter (fun (u : unit_record) -> u.updated_at < stale_cutoff) units);
    operation_status_counts = op_counts;
  }

let operation_status_counts_to_json (c : operation_status_counts) =
  `Assoc
    [
      ("planned", `Int c.planned_count);
      ("active", `Int c.active_count);
      ("paused", `Int c.paused_count);
      ("completed", `Int c.completed_count);
      ("failed", `Int c.failed_count);
      ("cancelled", `Int c.cancelled_count);
    ]

let topology_summary_to_json (s : topology_summary) =
  `Assoc
    [
      ("total_units", `Int s.total_units);
      ("company_count", `Int s.company_count);
      ("platoon_count", `Int s.platoon_count);
      ("squad_count", `Int s.squad_count);
      ("leaf_agent_unit_count", `Int s.leaf_agent_unit_count);
      ("live_agent_count", `Int s.live_agent_count);
      ("managed_unit_count", `Int s.managed_unit_count);
      ("active_operation_count", `Int s.active_operation_count);
      ("stale_unit_count", `Int s.stale_unit_count);
      ("operation_status_counts", operation_status_counts_to_json s.operation_status_counts);
    ]

let topology_summary_json_from_state (state : snapshot_state) =
  build_topology_summary ~units:state.units ~managed_units:state.managed_units
    ~agents:state.agents ~operations:state.operations
  |> topology_summary_to_json

(* Per-section mtime-based cache for build_snapshot_state.
   Instead of invalidating the entire cache when ANY .masc/ file changes,
   each section tracks the mtime of its specific file(s) and only re-reads
   when that file is modified.  This reduces a 5-second full rebuild to
   sub-100ms incremental updates in the common case (heartbeats/board posts
   change files that don't affect the command-plane sections). *)

let _file_mtime path =
  try (Unix.stat path).Unix.st_mtime
  with Unix.Unix_error _ -> 0.0

type section_cache = Cp_snapshot_section_cache.section_cache

let _section_cache = Cp_snapshot_section_cache.shared_cache

let _session_limit = 20

let _make_section_cache = Cp_snapshot_section_cache.create

let snapshot_state_of_sections ~config ~agents ~managed_units ~units ~source
    ~intents ~operations ~detachments ~decisions =
  let live_agents = live_agent_names agents in
  let status_map = agent_status_map agents in
  let child_map = children_map units in
  let unit_lookup = unit_map units in
  let tree_idx = Cp_tree_index.build_tree_index ~units ~operations ~agents in
  Cp_tree_index.bottom_up_aggregate tree_idx;
  {
    config;
    agents;
    managed_units;
    units;
    source;
    intents;
    operations;
    detachments;
    decisions;
    live_agents;
    status_map;
    child_map;
    unit_lookup;
    tree_idx;
  }

let build_snapshot_state (config : Room_utils.config) =
  let sc = match !_section_cache with
    | Some cache -> cache
    | None ->
        let cache = _make_section_cache () in
        _section_cache := Some cache;
        cache
  in
  match config.backend with
      | FileSystem _ ->
          (* Per-section mtime check: only re-read sections whose files changed. *)
          let units_mt = _file_mtime (units_path config) in
          let agents_dir =
            Filename.concat (Room.masc_dir config) "agents"
          in
          let agents_mt = _file_mtime agents_dir in
          let intents_mt = _file_mtime (intents_path config) in
          let ops_mt = _file_mtime (operations_path config) in
          let det_mt = _file_mtime (detachments_path config) in
          let decisions_mt = _file_mtime (decisions_path config) in
          let operator_mt = _file_mtime (operator_pending_confirms_path config) in
          (* Section 1: topology (agents + units) — re-read if units.json or agents dir changed *)
          if units_mt <> sc.topo_units_mtime || agents_mt <> sc.topo_agents_mtime then begin
            let agents, managed_units, units, source = topology_units config in
            sc.agents <- agents;
            sc.managed_units <- managed_units;
            sc.units <- units;
            sc.source <- source;
            sc.topo_units_mtime <- units_mt;
            sc.topo_agents_mtime <- agents_mt
          end;
          (* Section 2: sessions removed — team session cleanup *)
          (* Section 3: intents *)
          if intents_mt <> sc.intents_mtime then begin
            sc.intents <- read_intents config;
            sc.intents_mtime <- intents_mt
          end;
          (* Section 4: operations — re-read if ops file or topology changed *)
          if ops_mt <> sc.ops_mtime
             || sc.topo_units_mtime <> sc.ops_topo_units_mtime
             || sc.topo_agents_mtime <> sc.ops_topo_agents_mtime then begin
            sc.operations <- all_operations config sc.units;
            sc.ops_mtime <- ops_mt;
            sc.ops_topo_units_mtime <- sc.topo_units_mtime;
            sc.ops_topo_agents_mtime <- sc.topo_agents_mtime
          end;
          (* Section 5: detachments — re-read if detachments file or operations changed *)
          if det_mt <> sc.det_mtime || sc.ops_mtime <> sc.det_ops_mtime then begin
            sc.detachments <- all_detachments config sc.units sc.operations;
            sc.det_mtime <- det_mt;
            sc.det_ops_mtime <- sc.ops_mtime
          end;
          (* Section 6: decisions — re-read if decisions file or operator confirms changed *)
          if decisions_mt <> sc.decisions_mtime
             || operator_mt <> sc.decisions_operator_mtime then begin
            sc.decisions <- all_policy_decisions config;
            sc.decisions_mtime <- decisions_mt;
            sc.decisions_operator_mtime <- operator_mt
          end;
          let state =
            snapshot_state_of_sections ~config ~agents:sc.agents
              ~managed_units:sc.managed_units ~units:sc.units ~source:sc.source
              ~intents:sc.intents ~operations:sc.operations
              ~detachments:sc.detachments ~decisions:sc.decisions
          in
          state
      | Memory _ | PostgresNative _ ->
          let agents, managed_units, units, source = topology_units config in
          let intents = read_intents config in
          let operations = all_operations config units in
          let detachments = all_detachments config units operations in
          let decisions = all_policy_decisions config in
          snapshot_state_of_sections ~config ~agents ~managed_units ~units
            ~source ~intents ~operations ~detachments ~decisions

let topology_json_from_state (state : snapshot_state) =
  let tree_idx = state.tree_idx in
  let units = state.units in
  let source = state.source in
  let roots =
    units
    |> List.filter (fun (unit : unit_record) ->
           match unit.parent_unit_id with
           | None -> true
           | Some parent_id ->
               not (Hashtbl.mem tree_idx.Cp_tree_index.unit_tbl parent_id))
    |> List.sort (fun (a : unit_record) (b : unit_record) ->
           compare (kind_order a.kind, a.label) (kind_order b.kind, b.label))
  in
  let trees =
    roots
    |> List.filter_map (fun (unit : unit_record) ->
           build_tree_json_indexed ~tree_idx unit.unit_id)
  in
  let summary = topology_summary_json_from_state state in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("source", `String source);
      ("summary", summary);
      ("units", `List trees);
    ]

let topology_json config =
  topology_json_from_state (build_snapshot_state config)

let topology_summary_json config =
  topology_summary_json_from_state (build_snapshot_state config)

let list_units_json config =
  let _, managed_units, normalized_units, source = topology_units config in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("source", `String source);
      ("managed_units", `List (List.map unit_to_json managed_units));
      ("effective_units", `List (List.map unit_to_json normalized_units));
    ]

let list_detachments_json_from_state ?operation_id ?detachment_id
    (state : snapshot_state) =
  let units = state.units in
  let operations = state.operations in
  let detachments =
    state.detachments
    |> List.filter (fun (detachment : detachment_record) ->
           let operation_match =
             match operation_id with
             | None -> true
             | Some value ->
                 String.equal detachment.operation_id value
                 ||
                 match operation_by_id operations detachment.operation_id with
                 | Some operation -> String.equal operation.trace_id value
                 | None -> false
           in
           let detachment_match =
             match detachment_id with
             | None -> true
             | Some value -> String.equal detachment.detachment_id value
           in
           operation_match && detachment_match)
  in
  let rows =
    detachments
    |> List.map (fun (detachment : detachment_record) ->
           let operation =
             operation_by_id operations detachment.operation_id
             |> Option.map operation_to_json
             |> Option.value ~default:`Null
           in
           let unit_label =
             lookup_unit units detachment.assigned_unit_id
             |> Option.map (fun (unit : unit_record) -> unit.label)
             |> Option.value ~default:detachment.assigned_unit_id
           in
            `Assoc
              [
                ("detachment", detachment_to_json detachment);
                ("assigned_unit_label", `String unit_label);
                ("operation", operation);
              ])
  in
  let projected_count =
    List.length
      (List.filter (fun (detachment : detachment_record) -> detachment.source <> "managed") detachments)
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length detachments));
            ( "active",
              `Int
                (List.length
                   (List.filter
                      (fun (row : detachment_record) ->
                        String.equal row.status "active")
                      detachments)) );
            ( "awaiting_approval",
              `Int
                (List.length
                   (List.filter
                      (fun (row : detachment_record) ->
                        String.equal row.status "awaiting_approval")
                      detachments)) );
            ( "stalled",
              `Int
                (List.length
                   (List.filter
                      (fun (row : detachment_record) ->
                        String.equal row.status "stalled")
                      detachments)) );
            ("projected", `Int projected_count);
          ] );
      ("detachments", `List rows);
    ]

let list_detachments_json ?operation_id ?detachment_id config =
  list_detachments_json_from_state ?operation_id ?detachment_id
    (build_snapshot_state config)

let list_policy_decisions_json_from_state ?decision_id (state : snapshot_state) =
  let decisions =
    state.decisions
    |> List.filter (fun (decision : policy_decision_record) ->
           match decision_id with
           | None -> true
           | Some value ->
               String.equal decision.decision_id value
               || String.equal decision.trace_id value)
    |> List.sort (fun (a : policy_decision_record) (b : policy_decision_record) ->
           String.compare b.created_at a.created_at)
  in
  let count_status status =
    List.length (List.filter (fun (decision : policy_decision_record) -> String.equal decision.status status) decisions)
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length decisions));
            ("pending", `Int (count_status "pending"));
            ("approved", `Int (count_status "approved"));
            ("denied", `Int (count_status "denied"));
          ] );
      ("decisions", `List (List.map policy_decision_to_json decisions));
    ]

let list_policy_decisions_json ?decision_id config =
  list_policy_decisions_json_from_state ?decision_id (build_snapshot_state config)

let capacity_json_from_state (state : snapshot_state) =
  let units = state.units in
  let operations = state.operations in
  let live_agents = state.live_agents in
  let rows =
    units
    |> List.map (fun (unit : unit_record) ->
           let live_count =
             unit.roster
             |> List.filter (roster_name_is_live live_agents)
             |> List.length
           in
           let active_ops =
             operations
             |> List.filter (fun (operation : operation_record) ->
                    active_operation_status operation.status
                    && String.equal operation.assigned_unit_id unit.unit_id)
             |> List.length
           in
           let utilization =
             if unit.budget.active_operation_cap <= 0 then 0.0
             else float_of_int active_ops /. float_of_int unit.budget.active_operation_cap
           in
           `Assoc
             [
               ("unit", unit_to_json unit);
               ("roster_total", `Int (List.length unit.roster));
               ("roster_live", `Int live_count);
               ("headcount_cap", `Int unit.budget.headcount_cap);
               ("active_operations", `Int active_ops);
               ("active_operation_cap", `Int unit.budget.active_operation_cap);
               ("utilization", `Float utilization);
             ])
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("capacity", `List rows);
    ]

let capacity_json config =
  capacity_json_from_state (build_snapshot_state config)

let list_alerts_json_from_state _config (state : snapshot_state) =
  let units = state.units in
  let operations = state.operations in
  let live_agents = state.live_agents in
  let status_map = state.status_map in
  (* BUG-007: Dedup alerts by (kind, scope_type, scope_id) *)
  let seen : (string, int ref) Hashtbl.t = Hashtbl.create 32 in
  let alerts = ref [] in
  let push_alert ~severity ~kind ~scope_type ~scope_id ~title ~detail =
    let key = kind ^ "::" ^ scope_type ^ "::" ^ scope_id in
    match Hashtbl.find_opt seen key with
    | Some count -> incr count
    | None ->
        Hashtbl.replace seen key (ref 1);
        alerts :=
          (key, `Assoc
            [
              ("alert_id", `String (next_event_id "alert"));
              ("severity", `String severity);
              ("kind", `String kind);
              ("scope_type", `String scope_type);
              ("scope_id", `String scope_id);
              ("title", `String title);
              ("detail", `String detail);
              ("timestamp", `String (Types.now_iso ()));
            ])
          :: !alerts
  in
  List.iter
    (fun (unit : unit_record) ->
      let live_roster =
        unit.roster
        |> List.filter (roster_name_is_live live_agents)
        |> List.length
      in
      let active_ops =
        operations
        |> List.filter (fun (operation : operation_record) ->
               active_operation_status operation.status
               && String.equal operation.assigned_unit_id unit.unit_id)
        |> List.length
      in
      if unit.leader_id = None then
        push_alert ~severity:"warn" ~kind:"leader_missing" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " has no leader")
          ~detail:"Assign a leader before enabling automatic dispatch.";
      (match unit.leader_id with
      | Some leader when agent_status_for status_map leader = "offline" ->
          push_alert ~severity:"bad" ~kind:"leader_offline" ~scope_type:"unit"
            ~scope_id:unit.unit_id ~title:(unit.label ^ " leader is offline")
            ~detail:"Reassign leadership or recall the unit."
      | _ -> ());
      if List.length unit.roster > unit.budget.headcount_cap then
        push_alert ~severity:"warn" ~kind:"headcount_cap_exceeded" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " is over headcount cap")
          ~detail:
            (Printf.sprintf "%d assigned vs cap %d" (List.length unit.roster)
               unit.budget.headcount_cap);
      if unit.policy.frozen then
        push_alert ~severity:"warn" ~kind:"unit_frozen" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " is frozen")
          ~detail:"Dispatch into this unit is blocked until it is unfrozen.";
      if unit.policy.kill_switch then
        push_alert ~severity:"bad" ~kind:"kill_switch_enabled" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " kill-switch is enabled")
          ~detail:"All new operation assignment should stop until the switch is cleared.";
      if active_ops > unit.budget.active_operation_cap then
        push_alert ~severity:"bad" ~kind:"operation_cap_exceeded" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " exceeded active operation cap")
          ~detail:
            (Printf.sprintf "%d active vs cap %d" active_ops
               unit.budget.active_operation_cap);
      if unit.roster <> [] && live_roster = 0 then
        push_alert ~severity:"warn" ~kind:"roster_offline" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " has no live roster")
          ~detail:"All assigned agents are quiet or offline.")
    units;
  List.iter
    (fun (operation : operation_record) ->
      if active_operation_status operation.status then (
        match lookup_unit units operation.assigned_unit_id with
        | None ->
            push_alert ~severity:"bad" ~kind:"orphaned_operation" ~scope_type:"operation"
              ~scope_id:operation.operation_id
              ~title:(operation.operation_id ^ " is assigned to a missing unit")
              ~detail:"Reassign this operation before it continues."
        | Some _ -> ());
      (* Team_session_store removed — skip detachment quiet alerts *)
      ignore operation.detachment_session_id)
    operations;
  state.decisions
  |> List.iter (fun (decision : policy_decision_record) ->
         if String.equal decision.status "pending" then
           push_alert ~severity:"warn" ~kind:"approval_pending"
             ~scope_type:decision.scope_type ~scope_id:decision.scope_id
             ~title:(Printf.sprintf "%s waiting for approval" decision.requested_action)
             ~detail:
               (match decision.reason with
               | Some reason -> reason
               | None -> "Pending policy gate approval"));
  (* Add occurrences count to deduped alerts *)
  let enriched = List.rev !alerts |> List.map (fun (key, json) ->
    let occurrences =
      Hashtbl.find_opt seen key |> Option.map (fun count -> !count) |> Option.value ~default:1
    in
    match json with
    | `Assoc fields ->
        `Assoc (fields @ [("occurrences", `Int occurrences)])
    | other -> other
  ) in
  let ordered =
    enriched
    |> List.sort (fun a b ->
           let severity_rank json =
             match get_string_default json "severity" "warn" with
             | "critical" -> 0
             | "bad" -> 1
             | "warn" -> 2
             | _ -> 3
           in
           compare (severity_rank a) (severity_rank b))
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length ordered));
            ("critical", `Int (List.length (List.filter (fun json -> get_string_default json "severity" "" = "critical") ordered)));
            ("bad", `Int (List.length (List.filter (fun json -> let s = get_string_default json "severity" "" in s = "bad" || s = "critical") ordered)));
            ("warn", `Int (List.length (List.filter (fun json -> get_string_default json "severity" "" = "warn") ordered)));
          ] );
      ("alerts", `List ordered);
    ]

let list_alerts_json config =
  list_alerts_json_from_state config (build_snapshot_state config)

let string_contains = Dashboard_utils.string_contains
let string_contains_ci = Dashboard_utils.string_contains_ci

let json_string_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let json_event_field event key =
  Option.bind (json_string_opt key event) (function
    | `String value -> Some value
    | _ -> None)

let float_age_seconds timestamp =
  Option.map
    (fun ts -> max 0. (Unix.gettimeofday () -. ts))
    (Room.parse_iso_time_opt timestamp)

let timestamp_on_or_after ~boundary timestamp =
  match Room.parse_iso_time_opt timestamp with
  | Some ts -> ts >= boundary
  | None -> false

let run_tokens run_id =
  let safe = safe_slug run_id in
  [
    run_id;
    safe;
    "run_id=" ^ run_id;
    "run_id=" ^ safe;
    "swarm-live:" ^ run_id;
    "swarm-live:" ^ safe;
    "live-harness-" ^ run_id;
    "live-harness-" ^ safe;
  ]
  |> filter_nonempty_strings

let value_matches_tokens tokens value =
  List.exists (fun token -> string_contains_ci ~needle:token value) tokens

let option_matches_tokens tokens = function
  | Some value -> value_matches_tokens tokens value
  | None -> false

let best_overlap expected_names rows roster_of =
  let overlap_count row =
    roster_of row
    |> List.fold_left
         (fun acc name -> if List.mem name expected_names then acc + 1 else acc)
         0
  in
  rows
  |> List.map (fun row -> (row, overlap_count row))
  |> List.filter (fun (_, score) -> score > 0)
  |> List.sort (fun (_, left) (_, right) -> compare right left)
  |> list_hd_opt

let extract_run_id_from_note token =
  token
  |> String.split_on_char ' '
  |> List.find_map (fun part ->
         let trimmed = String.trim part in
         if String.length trimmed > 7
            && String.equal (String.lowercase_ascii (String.sub trimmed 0 7)) "run_id="
         then
           nonempty_string
             (Some
                (String.sub trimmed 7 (String.length trimmed - 7)
                |> String.trim))
         else None)

let extract_int_field_from_note ~field token =
  let prefix = String.lowercase_ascii field ^ "=" in
  let prefix_len = String.length prefix in
  token
  |> String.split_on_char ' '
  |> List.find_map (fun part ->
         let trimmed = String.trim part in
         if String.length trimmed > prefix_len
            && String.equal
                 (String.lowercase_ascii (String.sub trimmed 0 prefix_len))
                 prefix
         then
           int_of_string_opt
             (String.sub trimmed prefix_len (String.length trimmed - prefix_len)
             |> String.trim)
         else None)

let extract_run_id_from_prefixed_token ~prefix token =
  let prefix_len = String.length prefix in
  if String.length token > prefix_len
     && String.equal
          (String.lowercase_ascii (String.sub token 0 prefix_len))
          (String.lowercase_ascii prefix)
  then
    nonempty_string
      (Some
         (String.sub token prefix_len (String.length token - prefix_len)
         |> String.trim))
  else None

let extract_run_id token =
  option_or_else
    (extract_run_id_from_note token)
    (fun () ->
      option_or_else
        (extract_run_id_from_prefixed_token ~prefix:"swarm-live:" token)
        (fun () ->
          extract_run_id_from_prefixed_token ~prefix:"live-harness-" token))

let count_true rows predicate =
  List.fold_left (fun acc row -> if predicate row then acc + 1 else acc) 0 rows

let checklist_item ~id ~title ~status ~detail ~next_tool =
  `Assoc
    [
      ("id", `String id);
      ("title", `String title);
      ("status", `String status);
      ("detail", `String detail);
      ("next_tool", `String next_tool);
    ]

let blocker_item ~code ~severity ~title ~detail ~next_tool =
  `Assoc
    [
      ("code", `String code);
      ("severity", `String severity);
      ("title", `String title);
      ("detail", `String detail);
      ("next_tool", `String next_tool);
    ]
