include Cp_unit

type snapshot_state = {
  config : Room.config;
  agents : Types.agent list;
  managed_units : unit_record list;
  units : unit_record list;
  source : string;
  sessions : Team_session_types.session list;
  intents : intent_record list;
  operations : operation_record list;
  detachments : detachment_record list;
  decisions : policy_decision_record list;
  live_agents : string list;
  status_map : (string * string) list;
  child_map : (string * unit_record list) list;
  unit_lookup : (string * unit_record) list;
}

let build_snapshot_state ?sessions config =
  let agents, managed_units, units, source = topology_units config in
  let sessions =
    match sessions with
    | Some s -> s
    | None -> Team_session_store.list_sessions config
  in
  let intents = read_intents config in
  let operations = all_operations ~sessions config units in
  let detachments = all_detachments ~sessions config units operations in
  let decisions = all_policy_decisions config in
  let live_agents = live_agent_names agents in
  let status_map = agent_status_map agents in
  let child_map = children_map units in
  let unit_lookup = unit_map units in
  {
    config;
    agents;
    managed_units;
    units;
    source;
    sessions;
    intents;
    operations;
    detachments;
    decisions;
    live_agents;
    status_map;
    child_map;
    unit_lookup;
  }

let topology_json_from_state (state : snapshot_state) =
  let agents = state.agents in
  let managed_units = state.managed_units in
  let units = state.units in
  let source = state.source in
  let operations = state.operations in
  let child_map = state.child_map in
  let lookup = state.unit_lookup in
  let roots =
    units
    |> List.filter (fun (unit : unit_record) ->
           match unit.parent_unit_id with
           | None -> true
           | Some parent_id -> lookup_unit units parent_id = None)
    |> List.sort (fun (a : unit_record) (b : unit_record) ->
           compare (kind_order a.kind, a.label) (kind_order b.kind, b.label))
  in
  let trees =
    roots
    |> List.filter_map (fun (unit : unit_record) ->
           build_tree_json ~child_map ~unit_lookup:lookup
             ~agent_statuses:(agent_status_map agents)
             ~live_agents:(live_agent_names agents) ~operations unit.unit_id)
  in
  let summary =
    {
      total_units = List.length units;
      company_count = List.length (List.filter (fun (unit : unit_record) -> unit.kind = Company) units);
      platoon_count = List.length (List.filter (fun (unit : unit_record) -> unit.kind = Platoon) units);
      squad_count = List.length (List.filter (fun (unit : unit_record) -> unit.kind = Squad) units);
      leaf_agent_unit_count = List.length (List.filter (fun (unit : unit_record) -> unit.kind = Agent_unit) units);
      live_agent_count = List.length (live_agent_names agents);
      managed_unit_count = List.length managed_units;
      active_operation_count =
        operations
        |> List.filter (fun (operation : operation_record) -> active_operation_status operation.status)
        |> List.length;
    }
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("source", `String source);
      ( "summary",
        `Assoc
          [
            ("total_units", `Int summary.total_units);
            ("company_count", `Int summary.company_count);
            ("platoon_count", `Int summary.platoon_count);
            ("squad_count", `Int summary.squad_count);
            ("leaf_agent_unit_count", `Int summary.leaf_agent_unit_count);
            ("live_agent_count", `Int summary.live_agent_count);
            ("managed_unit_count", `Int summary.managed_unit_count);
            ("active_operation_count", `Int summary.active_operation_count);
          ] );
      ("units", `List trees);
    ]

let topology_json config =
  topology_json_from_state (build_snapshot_state config)

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
             unit.roster |> List.filter (fun agent_name -> List.mem agent_name live_agents) |> List.length
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

let list_alerts_json_from_state config (state : snapshot_state) =
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
        unit.roster |> List.filter (fun name -> List.mem name live_agents) |> List.length
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
      match operation.detachment_session_id with
      | Some session_id -> (
          match Team_session_store.load_session config session_id with
          | Some session -> (
              match session.last_event_at with
              | Some last_event_at ->
                  let age_sec = max 0. (Unix.gettimeofday () -. last_event_at) in
                  if age_sec > 1800. then
                    push_alert ~severity:"warn" ~kind:"detachment_quiet"
                      ~scope_type:"operation" ~scope_id:operation.operation_id
                      ~title:(operation.operation_id ^ " detachment went quiet")
                      ~detail:
                        (Printf.sprintf "No detachment event for %.0fs" age_sec)
              | None -> ())
          | None -> ())
      | None -> ())
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
    let occurrences = match Hashtbl.find_opt seen key with
      | Some count -> !count
      | None -> 1
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
             | "bad" -> 0
             | "warn" -> 1
             | _ -> 2
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
            ("bad", `Int (List.length (List.filter (fun json -> get_string_default json "severity" "" = "bad") ordered)));
            ("warn", `Int (List.length (List.filter (fun json -> get_string_default json "severity" "" = "warn") ordered)));
          ] );
      ("alerts", `List ordered);
    ]

let list_alerts_json config =
  list_alerts_json_from_state config (build_snapshot_state config)

let iso_of_unix = Dashboard_utils.iso_of_unix

let file_mtime path =
  try Some (Unix.stat path).st_mtime with Unix.Unix_error _ -> None

let read_jsonl_local path =
  match Safe_ops.read_file_safe path with
  | Error _ -> []
  | Ok content ->
      content
      |> String.split_on_char '\n'
      |> List.filter_map (fun line ->
             let trimmed = String.trim line in
             if trimmed = "" then None
             else
               match Safe_ops.parse_json_safe ~context:path trimmed with
               | Ok json -> Some json
               | Error _ -> None)

let swarm_live_dir config =
  Filename.concat (control_plane_dir config) "swarm-live"

type swarm_live_artifact = {
  run_id : string;
  run_dir : string;
  path : string;
  captured_at : float;
}

type slot_metrics = {
  peak_hot_slots : int option;
  ctx_per_slot : int option;
  captured_at : string option;
}

type runtime_doctor = {
  checked_at : string option;
  provider_base_url : string option;
  provider_reachable : bool option;
  provider_status_code : int option;
  provider_error : string option;
  provider_model_id : string option;
  actual_model_id : string option;
  slot_url : string option;
  slot_reachable : bool option;
  slot_status_code : int option;
  expected_slots : int option;
  actual_slots : int option;
  expected_ctx : int option;
  actual_ctx : int option;
  configured_capacity : int option;
  runtime_blocker : string option;
  detail : string option;
}

let latest_swarm_live_artifact config filename =
  let root = swarm_live_dir config in
  match Safe_ops.list_dir_safe root with
  | Error _ -> None
  | Ok entries ->
      entries
      |> List.filter_map (fun run_id ->
             let run_dir = Filename.concat root run_id in
             if Sys.file_exists run_dir && Sys.is_directory run_dir then
               let path = Filename.concat run_dir filename in
               match file_mtime path with
               | Some captured_at ->
                   Some { run_id; run_dir; path; captured_at }
               | None -> None
             else None)
      |> List.sort (fun (left : swarm_live_artifact) (right : swarm_live_artifact) ->
             Float.compare right.captured_at left.captured_at)
      |> list_hd_opt

let read_slot_metrics_from_json path =
  match Safe_ops.read_json_file_safe path with
  | Error _ -> None
  | Ok json ->
      Some
        {
          peak_hot_slots =
            (match U.member "peak_active_slots" json with
            | `Int value -> Some value
            | `Intlit value -> int_of_string_opt value
            | _ -> None);
          ctx_per_slot =
            (match U.member "ctx_per_slot" json with
            | `Int value -> Some value
            | `Intlit value -> int_of_string_opt value
            | _ -> None);
          captured_at = get_string_opt json "last_sample_at";
        }

let read_slot_metrics_from_samples path =
  let rows = read_jsonl_local path in
  let peak_hot_slots =
    rows
    |> List.fold_left
         (fun acc row ->
           max acc
             (match U.member "active_slots" row with
             | `Int value -> value
             | `Intlit value -> Option.value ~default:0 (int_of_string_opt value)
             | _ -> 0))
         0
  in
  let ctx_per_slot =
    rows
    |> List.find_map (fun row ->
           match U.member "ctx_per_slot" row with
           | `Int value -> Some value
           | `Intlit value -> int_of_string_opt value
           | _ -> None)
  in
  let captured_at =
    rows
    |> List.rev
    |> List.find_map (fun row -> get_string_opt row "timestamp")
  in
  if rows = [] then None
  else Some { peak_hot_slots = Some peak_hot_slots; ctx_per_slot; captured_at }

let read_slot_metrics run_dir =
  let telemetry_path = Filename.concat run_dir "slot-telemetry.json" in
  if Sys.file_exists telemetry_path then
    read_slot_metrics_from_json telemetry_path
  else
    let samples_path = Filename.concat run_dir "slot-samples.jsonl" in
    if Sys.file_exists samples_path then read_slot_metrics_from_samples samples_path
    else None

let read_runtime_doctor_json run_dir =
  let doctor_path = Filename.concat run_dir "runtime-doctor.json" in
  if not (Sys.file_exists doctor_path) then
    None
  else
    match Safe_ops.read_json_file_safe doctor_path with
    | Error _ -> None
    | Ok json ->
        Some
          {
            checked_at = get_string_opt json "checked_at";
            provider_base_url = get_string_opt json "provider_base_url";
            provider_reachable = U.member "provider_reachable" json |> U.to_bool_option;
            provider_status_code = U.member "provider_status_code" json |> U.to_int_option;
            provider_error = get_string_opt json "provider_error";
            provider_model_id = get_string_opt json "provider_model_id";
            actual_model_id = get_string_opt json "actual_model_id";
            slot_url = get_string_opt json "slot_url";
            slot_reachable = U.member "slot_reachable" json |> U.to_bool_option;
            slot_status_code = U.member "slot_status_code" json |> U.to_int_option;
            expected_slots = U.member "expected_slots" json |> U.to_int_option;
            actual_slots = U.member "actual_slots" json |> U.to_int_option;
            expected_ctx = U.member "expected_ctx" json |> U.to_int_option;
            actual_ctx = U.member "actual_ctx" json |> U.to_int_option;
            configured_capacity = U.member "configured_capacity" json |> U.to_int_option;
            runtime_blocker = get_string_opt json "runtime_blocker";
            detail = get_string_opt json "detail";
          }

let swarm_proof_json config =
  let int_member json key =
    match U.member key json with
    | `Int value -> Some value
    | `Intlit value -> int_of_string_opt value
    | _ -> None
  in
  let workers_json
      ?expected ?joined ?current_task_bound ?fresh_heartbeats ?done_workers
      ?final_markers () =
    `Assoc
      [
        ("expected", Option.value ~default:`Null (Option.map (fun v -> `Int v) expected));
        ("joined", Option.value ~default:`Null (Option.map (fun v -> `Int v) joined));
        ( "current_task_bound",
          Option.value ~default:`Null
            (Option.map (fun v -> `Int v) current_task_bound) );
        ( "fresh_heartbeats",
          Option.value ~default:`Null
            (Option.map (fun v -> `Int v) fresh_heartbeats) );
        ("done", Option.value ~default:`Null (Option.map (fun v -> `Int v) done_workers));
        ("final", Option.value ~default:`Null (Option.map (fun v -> `Int v) final_markers));
      ]
  in
  let expected_dir = swarm_live_dir config in
  match latest_swarm_live_artifact config "swarm-live-summary.json" with
  | Some summary_artifact -> (
      match Safe_ops.read_json_file_safe summary_artifact.path with
      | Ok summary_json ->
          let slot_metrics = read_slot_metrics summary_artifact.run_dir in
          let captured_at =
            Option.value
              ~default:(iso_of_unix summary_artifact.captured_at)
              (Option.bind slot_metrics (fun metrics -> metrics.captured_at))
          in
          `Assoc
            [
              ("status", `String "present");
              ("source", `String "artifact");
              ("reason_code", `String "artifact_present");
              ( "status_summary",
                `String
                  "A swarm-live summary artifact was found and parsed successfully." );
              ("run_id", `String summary_artifact.run_id);
              ("captured_at", `String captured_at);
              ( "pass",
                match U.member "pass" summary_json with
                | `Bool value -> `Bool value
                | _ -> `Null );
              ( "peak_hot_slots",
                match Option.bind slot_metrics (fun metrics -> metrics.peak_hot_slots) with
                | Some value -> `Int value
                | None -> `Null );
              ( "ctx_per_slot",
                match Option.bind slot_metrics (fun metrics -> metrics.ctx_per_slot) with
                | Some value -> `Int value
                | None -> `Null );
              ( "workers",
                workers_json
                  ?expected:(option_or_else (int_member summary_json "expected_workers")
                               (fun () -> int_member summary_json "worker_count"))
                  ?joined:(int_member summary_json "joined_workers")
                  ?current_task_bound:(int_member summary_json "current_task_bound")
                  ?fresh_heartbeats:(int_member summary_json "fresh_heartbeats")
                  ?done_workers:(int_member summary_json "completed_workers")
                  ?final_markers:(int_member summary_json "final_markers_seen")
                  () );
              ("expected_artifact_dir", `String summary_artifact.run_dir);
              ("artifact_ref", `String summary_artifact.path);
              ("missing_reason", `Null);
            ]
      | Error _ -> `Assoc
          [
            ("status", `String "missing");
            ("source", `String "none");
            ("reason_code", `String "summary_unreadable");
            ( "status_summary",
              `String
                "A swarm-live summary artifact exists, but it could not be read." );
            ("run_id", `Null);
            ("captured_at", `Null);
            ("pass", `Null);
            ("peak_hot_slots", `Null);
            ("ctx_per_slot", `Null);
            ("workers", workers_json ());
            ("expected_artifact_dir", `String summary_artifact.run_dir);
            ("artifact_ref", `Null);
            ( "missing_reason",
              `String
                "Latest swarm-live summary artifact could not be read." );
          ] )
  | None -> (
      match latest_swarm_live_artifact config "slot-samples.jsonl" with
      | Some slot_artifact -> (
          match read_slot_metrics_from_samples slot_artifact.path with
          | Some metrics ->
              `Assoc
                [
                  ("status", `String "fallback");
                  ("source", `String "slot_samples");
                  ("reason_code", `String "slot_samples_only");
                  ( "status_summary",
                    `String
                      "Only slot telemetry was found; worker completion proof is still missing." );
                  ("run_id", `String slot_artifact.run_id);
                  ( "captured_at",
                    match metrics.captured_at with
                    | Some value -> `String value
                    | None -> `String (iso_of_unix slot_artifact.captured_at) );
                  ("pass", `Null);
                  ( "peak_hot_slots",
                    match metrics.peak_hot_slots with
                    | Some value -> `Int value
                    | None -> `Null );
                  ( "ctx_per_slot",
                    match metrics.ctx_per_slot with
                    | Some value -> `Int value
                    | None -> `Null );
                  ("workers", workers_json ());
                  ("expected_artifact_dir", `String slot_artifact.run_dir);
                  ("artifact_ref", `String slot_artifact.path);
                  ( "missing_reason",
                    `String
                      "Only slot samples were found; worker completion proof is unavailable." );
                ]
          | None ->
              `Assoc
                [
                  ("status", `String "missing");
                  ("source", `String "none");
                  ("reason_code", `String "slot_samples_unreadable");
                  ( "status_summary",
                    `String
                      "Slot telemetry exists, but the dashboard could not summarize it." );
                  ("run_id", `Null);
                  ("captured_at", `Null);
                  ("pass", `Null);
                  ("peak_hot_slots", `Null);
                  ("ctx_per_slot", `Null);
                  ("workers", workers_json ());
                  ("expected_artifact_dir", `String slot_artifact.run_dir);
                  ("artifact_ref", `Null);
                  ( "missing_reason",
                    `String
                      "Latest slot sample artifact could not be read." );
                ] )
      | None ->
          `Assoc
            [
              ("status", `String "missing");
              ("source", `String "none");
              ("reason_code", `String "no_swarm_live_artifacts");
              ( "status_summary",
                `String
                  "No swarm-live proof artifacts were found for the current control-plane state." );
              ("run_id", `Null);
              ("captured_at", `Null);
              ("pass", `Null);
              ("peak_hot_slots", `Null);
              ("ctx_per_slot", `Null);
              ("workers", workers_json ());
              ("expected_artifact_dir", `String expected_dir);
              ("artifact_ref", `Null);
              ( "missing_reason",
                `String
                  "No swarm-live proof artifacts were found under .masc/control-plane/swarm-live." );
            ] )

let topology_summary_json_from_state (state : snapshot_state) =
  let summary =
    {
      total_units = List.length state.units;
      company_count =
        List.length
          (List.filter
             (fun (unit : unit_record) -> unit.kind = Company)
             state.units);
      platoon_count =
        List.length
          (List.filter
             (fun (unit : unit_record) -> unit.kind = Platoon)
             state.units);
      squad_count =
        List.length
          (List.filter
             (fun (unit : unit_record) -> unit.kind = Squad)
             state.units);
      leaf_agent_unit_count =
        List.length
          (List.filter
             (fun (unit : unit_record) -> unit.kind = Agent_unit)
             state.units);
      live_agent_count = List.length state.live_agents;
      managed_unit_count = List.length state.managed_units;
      active_operation_count =
        state.operations
        |> List.filter (fun (operation : operation_record) ->
               active_operation_status operation.status)
        |> List.length;
    }
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("source", `String state.source);
      ( "summary",
        `Assoc
          [
            ("total_units", `Int summary.total_units);
            ("company_count", `Int summary.company_count);
            ("platoon_count", `Int summary.platoon_count);
            ("squad_count", `Int summary.squad_count);
            ("leaf_agent_unit_count", `Int summary.leaf_agent_unit_count);
            ("live_agent_count", `Int summary.live_agent_count);
            ("managed_unit_count", `Int summary.managed_unit_count);
            ("active_operation_count", `Int summary.active_operation_count);
          ] );
    ]

let operations_summary_json_from_state (state : snapshot_state) =
  let search_store = read_search_stats state.config in
  let readiness_of_operation (operation : operation_record) =
    let blockers =
      operation.depends_on_operation_ids
      |> List.filter_map (fun dep_id ->
             match operation_by_id state.operations dep_id with
             | Some upstream when upstream.status = Completed -> None
             | Some upstream when Option.is_some upstream.checkpoint_ref -> None
             | Some _upstream ->
                 Some
                   {
                     Cp_microarch_summary.strategy = operation.search_strategy;
                     readiness = "blocked";
                     status = string_of_operation_status operation.status;
                     candidate_count = 0;
                     best_score = None;
                     workload_profile = operation_workload_profile operation;
                     stage = operation.stage;
                     artifact_scope_count = List.length operation.artifact_scope;
                     artifact_scope_key =
                       (match List.sort_uniq String.compare operation.artifact_scope with
                       | [] -> None
                       | scopes -> Some (String.concat "|" scopes));
                   }
             | None ->
                 Some
                   {
                     Cp_microarch_summary.strategy = operation.search_strategy;
                     readiness = "blocked";
                     status = string_of_operation_status operation.status;
                     candidate_count = 0;
                     best_score = None;
                     workload_profile = operation_workload_profile operation;
                     stage = operation.stage;
                     artifact_scope_count = List.length operation.artifact_scope;
                     artifact_scope_key =
                       (match List.sort_uniq String.compare operation.artifact_scope with
                       | [] -> None
                       | scopes -> Some (String.concat "|" scopes));
                   })
    in
    if blockers = [] then "ready" else "blocked"
  in
  let search_rows =
    List.map
      (fun (operation : operation_record) ->
        let stats =
          Cp_search_fabric.lookup_stats search_store
            ~unit_id:operation.assigned_unit_id
            ~workload_profile:(operation_workload_profile operation)
            ~stage:(operation_stage_key operation)
        in
        {
          Cp_microarch_summary.strategy = operation.search_strategy;
          readiness = readiness_of_operation operation;
          status = string_of_operation_status operation.status;
          candidate_count =
            (match operation_search_strategy operation with
            | Cp_search_fabric.Best_first_v1 -> 1
            | Cp_search_fabric.Legacy -> 0);
          best_score =
            (match operation_search_strategy operation with
            | Cp_search_fabric.Best_first_v1 ->
                Some (Cp_search_fabric.posterior_mean stats *. 100.0)
            | Cp_search_fabric.Legacy -> None);
          workload_profile = operation_workload_profile operation;
          stage = operation.stage;
          artifact_scope_count = List.length operation.artifact_scope;
          artifact_scope_key =
            (match List.sort_uniq String.compare operation.artifact_scope with
            | [] -> None
            | scopes -> Some (String.concat "|" scopes));
        })
      state.operations
  in
  let managed_count =
    List.length
      (List.filter
         (fun (operation : operation_record) -> operation.source = "managed")
         state.operations)
  in
  let active_count =
    List.length
      (List.filter
         (fun (operation : operation_record) -> operation.status = Active)
         state.operations)
  in
  let paused_count =
    List.length
      (List.filter
         (fun (operation : operation_record) -> operation.status = Paused)
         state.operations)
  in
  let microarch = Cp_microarch_summary.summary_json ~search_rows in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length state.operations));
            ("active", `Int active_count);
            ("paused", `Int paused_count);
            ("managed", `Int managed_count);
            ("projected", `Int (List.length state.operations - managed_count));
          ] );
      ("microarch", microarch);
    ]

let detachments_summary_json_from_state (state : snapshot_state) =
  let projected_count =
    List.length
      (List.filter
         (fun (detachment : detachment_record) -> detachment.source <> "managed")
         state.detachments)
  in
  let count_status status =
    List.length
      (List.filter
         (fun (detachment : detachment_record) ->
           String.equal detachment.status status)
         state.detachments)
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length state.detachments));
            ("active", `Int (count_status "active"));
            ("awaiting_approval", `Int (count_status "awaiting_approval"));
            ("stalled", `Int (count_status "stalled"));
            ("projected", `Int projected_count);
          ] );
    ]

let intents_summary_json_from_state (state : snapshot_state) =
  let count_state target =
    state.intents
    |> List.filter (fun (intent : intent_record) -> intent.state = target)
    |> List.length
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length state.intents));
            ("active", `Int (count_state Active_intent));
            ("blocked", `Int (count_state Blocked_intent));
            ("handoff_ready", `Int (count_state Handoff_ready));
          ] );
      ("intents", `List (List.map intent_to_json state.intents));
    ]

let summary_json ?sessions config =
  let state = build_snapshot_state ?sessions config in
  let alerts =
    list_alerts_json_from_state config state
    |> U.member "summary"
  in
  let decisions =
    list_policy_decisions_json_from_state state
    |> U.member "summary"
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("topology", topology_summary_json_from_state state);
      ("intents", intents_summary_json_from_state state);
      ("operations", operations_summary_json_from_state state);
      ("detachments", detachments_summary_json_from_state state);
      ("alerts", `Assoc [ ("summary", alerts) ]);
      ("decisions", `Assoc [ ("summary", decisions) ]);
      ("swarm_proof", swarm_proof_json config);
    ]

let recent_team_session_trace_events config session_id limit =
  Team_session_store.read_events ~max_events:limit config session_id
  |> List.filter_map (fun json ->
         let event_type = get_string_opt json "event_type" in
         let timestamp = get_string_opt json "ts_iso" in
         let detail =
           match U.member "detail" json with
           | `Assoc _ as value -> value
           | `List _ as value -> value
           | `Null -> `Assoc []
           | value -> value
         in
         match event_type, timestamp with
         | Some event_type, Some timestamp ->
             Some
               (`Assoc
                 [
                   ("event_id", `String (next_event_id "trace"));
                   ("trace_id", `String session_id);
                   ("event_type", `String event_type);
                   ("source", `String "team_session");
                   ("timestamp", `String timestamp);
                   ("detail", detail);
                 ])
         | _ -> None)

let recent_operator_trace_events config ?trace_id limit =
  if not (Room_utils.path_exists config (operator_action_log_path config)) then
    []
  else
    In_channel.with_open_text (operator_action_log_path config) (fun ic ->
        let rec loop acc =
          match input_line ic with
          | line ->
              let trimmed = String.trim line in
              let acc' =
                if trimmed = "" then
                  acc
                else
                  match Safe_ops.parse_json_safe ~context:"command_plane_v2.operator_log" trimmed with
                  | Ok (`Assoc _ as row) ->
                      let row_trace_id = get_string_opt row "trace_id" in
                      let keep =
                        match trace_id, row_trace_id with
                        | None, _ -> true
                        | Some expected, Some actual -> String.equal expected actual
                        | Some _, None -> false
                      in
                      if keep then
                        `Assoc
                          [
                            ("event_id", `String (next_event_id "trace"));
                            ("trace_id", `String (get_string_default row "trace_id" "operator"));
                            ("event_type", `String (get_string_default row "action_type" "operator_action"));
                            ("operation_id", `Null);
                            ("unit_id", `Null);
                            ("actor", match get_string_opt row "actor" with Some value -> `String value | None -> `Null);
                            ("source", `String "operator");
                            ("timestamp", `String (get_string_default row "created_at" (Types.now_iso ())));
                            ("detail", row);
                          ]
                        :: acc
                      else
                        acc
                  | Ok _ | Error _ -> acc
              in
              loop acc'
          | exception End_of_file -> List.rev acc
        in
        loop []
        |> List.rev |> List.filteri (fun idx _ -> idx < limit) |> List.rev)

let recent_swarm_trace_events config limit =
  if not (Room_utils.path_exists config (swarm_path config)) then
    []
  else
    match Room_utils.read_json_opt config (swarm_path config) with
    | Some (`Assoc _ as root) ->
        let config_json =
          match U.member "config" root with `Assoc _ as value -> value | _ -> `Assoc []
        in
        let swarm_id = get_string_default config_json "id" "swarm-runtime" in
        let generation = get_int_default root "generation" 0 in
        let timestamp =
          match U.member "last_evolution" root with
          | `Float value -> iso_of_unix value
          | `Int value -> iso_of_unix (float_of_int value)
          | _ -> Types.now_iso ()
        in
        [
          `Assoc
            [
              ("event_id", `String (next_event_id "trace"));
              ("trace_id", `String ("swarm-trace-" ^ safe_slug swarm_id));
              ("event_type", `String "swarm_projected");
              ("operation_id", `String ("swarm-" ^ safe_slug swarm_id));
              ("unit_id", `Null);
              ("actor", `String "swarm");
              ("source", `String "swarm");
              ("timestamp", `String timestamp);
              ("detail", `Assoc [ ("generation", `Int generation); ("config", config_json) ]);
            ];
        ]
        |> List.filteri (fun idx _ -> idx < limit)
    | _ -> []

let list_traces_json config ?operation_id ?(limit = 25) () =
  let events =
    read_events config
    |> List.filter (fun (event : event_record) ->
           match operation_id with
           | None -> true
           | Some operation_ref ->
               (match event.operation_id with
               | Some value -> String.equal value operation_ref
               | None -> false)
               || String.equal event.trace_id operation_ref)
  in
  let cp_events =
    events
    |> List.rev
    |> List.filteri (fun idx _ -> idx < limit)
    |> List.rev
    |> List.map (fun (event : event_record) ->
           `Assoc
             [
               ("event_id", `String event.event_id);
               ("trace_id", `String event.trace_id);
               ("event_type", `String event.event_type);
               ("operation_id", match event.operation_id with Some value -> `String value | None -> `Null);
               ("unit_id", match event.unit_id with Some value -> `String value | None -> `Null);
               ("actor", match event.actor with Some value -> `String value | None -> `Null);
               ("source", `String event.source);
               ("timestamp", `String event.ts);
               ("detail", event.detail);
             ])
  in
  let team_session_events =
    match operation_id with
    | Some operation_ref -> (
        let _, _, units, _ = topology_units config in
        let operations = all_operations config units in
        match
          operations
          |> List.find_opt (fun (operation : operation_record) ->
                 String.equal operation.operation_id operation_ref
                 || String.equal operation.trace_id operation_ref)
        with
        | Some operation -> (
            match operation.detachment_session_id with
            | Some session_id -> recent_team_session_trace_events config session_id limit
            | None -> [])
        | None -> [])
    | None -> []
  in
  let operator_events =
    match operation_id with
    | Some operation_ref -> recent_operator_trace_events config ~trace_id:operation_ref limit
    | None -> recent_operator_trace_events config limit
  in
  let merged = cp_events @ team_session_events @ operator_events in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("events", `List merged);
    ]

let string_contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 then true
  else
    let rec loop idx =
      if idx + needle_len > haystack_len then false
      else if String.sub haystack idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0

let string_contains_ci ~needle haystack =
  string_contains ~needle:(String.lowercase_ascii needle)
    (String.lowercase_ascii haystack)

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
