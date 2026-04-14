include Cp_lifecycle
open Result_syntax

let required_string json ~key ~message =
  match Json_util.require_string json key with
  | Ok value -> Ok value
  | Error _ -> Error message

let request_or_apply_assignment config ~(actor : string) ~requested_action json =
  let* operation_id =
    required_string json ~key:"operation_id"
      ~message:"operation_id is required. Call masc_operation_start first."
  in
  let* target_unit_id =
    required_string json ~key:"target_unit_id"
      ~message:"target_unit_id is required"
  in
  with_operation config operation_id (fun _ current ->
      let _, _, units, _ = topology_units config in
      let needs_approval =
        decision_requires_approval units (Some current.assigned_unit_id) target_unit_id
      in
      if needs_approval then
        let decision =
          match
            find_pending_decision config ~requested_action ~operation_id
              ~target_unit_id ()
          with
          | Some existing -> existing
          | None ->
              create_policy_decision config ~actor ~requested_action
                ~scope_type:"company"
                ~scope_id:
                  (company_scope_id_for units (Some current.assigned_unit_id)
                     (Some target_unit_id))
                ~operation_id ~target_unit_id
                ~reason:
                  (Some
                     (Printf.sprintf "%s from %s to %s requires company approval"
                        requested_action current.assigned_unit_id target_unit_id))
                (`Assoc
                  [
                    ( "apply",
                      `Assoc
                        [
                          ("kind", `String "reassign_operation");
                          ("operation_id", `String operation_id);
                          ("target_unit_id", `String target_unit_id);
                          ( "note",
                            Json_util.string_opt_to_json (get_string_opt json "note") );
                        ] );
                    ( "preview",
                      `Assoc
                        [
                          ("from_unit_id", `String current.assigned_unit_id);
                          ("to_unit_id", `String target_unit_id);
                        ] );
                  ])
        in
        Ok
          (`Assoc
            [
              ("status", `String "pending_approval");
              ("decision", policy_decision_to_json decision);
              ("operations", list_operations_json config);
              ("decisions", list_policy_decisions_json config);
            ])
      else
        Result.map
          (fun operation ->
            `Assoc
              [
                ("status", `String "ok");
                ("result", operation_to_json operation);
                ("operations", list_operations_json config);
              ])
          (apply_operation_assignment config ~actor current ~target_unit_id
             ~note:(get_string_opt json "note") ~event_type:requested_action))

let dispatch_assign_json config ~(actor : string) json =
  try
    request_or_apply_assignment config ~actor ~requested_action:"dispatch_assign"
      json
  with Invalid_argument message -> Error message

let dispatch_rebalance_json config ~(actor : string) json =
  try
    request_or_apply_assignment config ~actor
      ~requested_action:"dispatch_rebalance" json
  with Invalid_argument message -> Error message

let dispatch_escalate_json config ~(actor : string) json =
  try
    let* operation_id =
      required_string json ~key:"operation_id"
        ~message:"operation_id is required. Call masc_operation_start first."
    in
    with_operation config operation_id (fun _ current ->
        let _, _, units, _ = topology_units config in
        let target_unit_id =
          match get_string_opt json "target_unit_id" with
          | Some value -> value
          | None ->
              nearest_ancestor units current.assigned_unit_id
                (fun (unit : unit_record) -> unit.kind = Platoon || unit.kind = Company)
              |> Option.map (fun (unit : unit_record) -> unit.unit_id)
              |> Option.value ~default:current.assigned_unit_id
        in
        request_or_apply_assignment config ~actor ~requested_action:"dispatch_escalate"
          (`Assoc
            [
              ("operation_id", `String operation_id);
              ("target_unit_id", `String target_unit_id);
              ("note", Json_util.string_opt_to_json (get_string_opt json "note"));
            ]))
  with Invalid_argument message -> Error message

let dispatch_recall_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required. Call masc_operation_start first."
  | Some operation_id ->
      Result.map
        (fun operation ->
          `Assoc
            [
              ("status", `String "ok");
              ("result", operation_to_json operation);
              ("operations", list_operations_json config);
            ])
        (update_operation_status config ~actor ~operation_id ~status:Paused
           ~note:(get_string_opt json "note") ~event_type:"dispatch_recall")

let unit_update_json config ~(actor : string) json =
  try
    match upsert_unit config ~actor json with
    | Ok unit ->
        Ok
          (`Assoc
            [
              ("status", `String "ok");
              ("result", unit_to_json unit);
              ("topology", topology_json config);
            ])
    | Error message -> Error message
  with Invalid_argument message -> Error message

let unit_reparent_json config ~(actor : string) json =
  try
    let* unit_id =
      required_string json ~key:"unit_id" ~message:"unit_id is required"
    in
    let parent_unit_id = get_string_opt json "parent_unit_id" in
    update_unit config ~actor ~unit_id
      (fun current ->
        { current with parent_unit_id; updated_at = Types.now_iso () })
      ~event_type:"unit_reparented"
      (`Assoc
        [
          ( "parent_unit_id",
            Json_util.string_opt_to_json parent_unit_id
          );
        ])
    |> Result.map (fun unit ->
           `Assoc
             [
               ("status", `String "ok");
               ("result", unit_to_json unit);
               ("topology", topology_json config);
             ])
  with Invalid_argument message -> Error message

let unit_reassign_json config ~(actor : string) json =
  try
    let* unit_id =
      required_string json ~key:"unit_id" ~message:"unit_id is required"
    in
    let leader_id = get_string_opt json "leader_id" in
    let roster =
      match U.member "roster" json with
      | `List _ -> get_string_list json "roster"
      | _ -> []
    in
    update_unit config ~actor ~unit_id
      (fun current ->
        {
          current with
          leader_id = option_first_some leader_id current.leader_id;
          roster = if roster = [] then current.roster else roster;
          updated_at = Types.now_iso ();
        })
      ~event_type:"unit_reassigned"
      (`Assoc
        [
          ("leader_id", Json_util.string_opt_to_json leader_id);
          ("roster", if roster = [] then json_list_of_strings [] else json_list_of_strings roster);
        ])
    |> Result.map (fun unit ->
           `Assoc
             [
               ("status", `String "ok");
               ("result", unit_to_json unit);
               ("topology", topology_json config);
             ])
  with Invalid_argument message -> Error message

let policy_status_json config =
  `Assoc
    [
      ("status", `String "ok");
      ("decisions", list_policy_decisions_json config);
      ("capacity", capacity_json config);
      ("topology", topology_json config);
    ]

let policy_apply_unit_toggle config ~(actor : string) ~unit_id ~event_type ~field json =
  let enabled =
    match U.member "enabled" json with
    | `Bool value -> value
    | `String raw -> String.equal (String.lowercase_ascii raw) "true"
    | _ -> get_bool_default json "enabled" true
  in
  update_unit config ~actor ~unit_id
    (fun current ->
      let policy =
        match field with
        | "kill_switch" -> { current.policy with kill_switch = enabled }
        | "frozen" -> { current.policy with frozen = enabled }
        | _ -> current.policy
      in
      { current with policy; updated_at = Types.now_iso () })
    ~event_type
    (`Assoc [ ("enabled", `Bool enabled); ("field", `String field) ])
  |> Result.map (fun unit ->
         `Assoc
           [
             ("status", `String "ok");
             ("result", unit_to_json unit);
             ("topology", topology_json config);
             ("alerts", list_alerts_json config);
           ])

let policy_freeze_unit_json config ~(actor : string) json =
  match get_string_opt json "unit_id" with
  | None -> Error "unit_id is required"
  | Some unit_id -> (
      let _, _, units, _ = topology_units config in
      let enabled =
        match U.member "enabled" json with
        | `Bool value -> value
        | `String raw -> String.equal (String.lowercase_ascii raw) "true"
        | _ -> get_bool_default json "enabled" true
      in
      match
        find_pending_decision config ~requested_action:"policy_freeze_unit"
          ~target_unit_id:unit_id ()
      with
      | Some decision ->
          Ok
            (`Assoc
              [
                ("status", `String "pending_approval");
                ("decision", policy_decision_to_json decision);
                ("decisions", list_policy_decisions_json config);
              ])
      | None ->
          let company_id = company_scope_id_for units None (Some unit_id) in
          let decision =
            create_policy_decision config ~actor
              ~requested_action:"policy_freeze_unit" ~scope_type:"company"
              ~scope_id:company_id ~target_unit_id:unit_id
              ~reason:
                (Some
                   (Printf.sprintf "%s freeze toggle on %s requires company approval"
                      (if enabled then "Enabling" else "Clearing")
                      unit_id))
              (`Assoc
                [
                  ( "apply",
                    `Assoc
                      [
                        ("kind", `String "toggle_unit_policy");
                        ("unit_id", `String unit_id);
                        ("field", `String "frozen");
                        ("enabled", `Bool enabled);
                      ] );
                ])
          in
          Ok
            (`Assoc
              [
                ("status", `String "pending_approval");
                ("decision", policy_decision_to_json decision);
                ("decisions", list_policy_decisions_json config);
              ]))

let policy_kill_switch_json config ~(actor : string) json =
  match get_string_opt json "unit_id" with
  | None -> Error "unit_id is required"
  | Some unit_id -> (
      let _, _, units, _ = topology_units config in
      let enabled =
        match U.member "enabled" json with
        | `Bool value -> value
        | `String raw -> String.equal (String.lowercase_ascii raw) "true"
        | _ -> get_bool_default json "enabled" true
      in
      match
        find_pending_decision config ~requested_action:"policy_kill_switch"
          ~target_unit_id:unit_id ()
      with
      | Some decision ->
          Ok
            (`Assoc
              [
                ("status", `String "pending_approval");
                ("decision", policy_decision_to_json decision);
                ("decisions", list_policy_decisions_json config);
              ])
      | None ->
          let company_id = company_scope_id_for units None (Some unit_id) in
          let decision =
            create_policy_decision config ~actor
              ~requested_action:"policy_kill_switch" ~scope_type:"company"
              ~scope_id:company_id ~target_unit_id:unit_id
              ~reason:
                (Some
                   (Printf.sprintf "%s kill-switch on %s requires company approval"
                      (if enabled then "Enabling" else "Clearing")
                      unit_id))
              (`Assoc
                [
                  ( "apply",
                    `Assoc
                      [
                        ("kind", `String "toggle_unit_policy");
                        ("unit_id", `String unit_id);
                        ("field", `String "kill_switch");
                        ("enabled", `Bool enabled);
                      ] );
                ])
          in
          Ok
            (`Assoc
              [
                ("status", `String "pending_approval");
                ("decision", policy_decision_to_json decision);
                ("decisions", list_policy_decisions_json config);
              ]))

let policy_update_json config ~(actor : string) json =
  try
    let* unit_id =
      required_string json ~key:"unit_id" ~message:"unit_id is required"
    in
    let policy_json =
      match U.member "policy" json with `Assoc _ as value -> value | _ -> `Assoc []
    in
    let budget_json =
      match U.member "budget" json with `Assoc _ as value -> value | _ -> `Assoc []
    in
    update_unit config ~actor ~unit_id
      (fun current ->
        {
          current with
          policy = policy_of_json policy_json current.kind;
          budget = budget_of_json budget_json current.kind;
          updated_at = Types.now_iso ();
        })
      ~event_type:"unit_policy_updated"
      (`Assoc [ ("policy", policy_json); ("budget", budget_json) ])
    |> Result.map (fun unit ->
           `Assoc
             [
               ("status", `String "ok");
               ("result", unit_to_json unit);
               ("topology", topology_json config);
               ("capacity", capacity_json config);
             ])
  with Invalid_argument message -> Error message

let apply_policy_decision config ~(actor : string) (decision : policy_decision_record) =
  let apply =
    match U.member "apply" decision.detail with `Assoc _ as value -> value | _ -> `Assoc []
  in
  match get_string_opt apply "kind" with
  | Some "reassign_operation" -> (
      match get_string_opt apply "operation_id", get_string_opt apply "target_unit_id" with
      | Some operation_id, Some target_unit_id ->
          with_operation config operation_id (fun _ current ->
              apply_operation_assignment config ~actor current ~target_unit_id
                ~note:(get_string_opt apply "note") ~event_type:"policy_assignment_applied")
          |> Result.map operation_to_json
      | _ -> Error "decision apply payload missing operation_id or target_unit_id")
  | Some "toggle_unit_policy" -> (
      match get_string_opt apply "unit_id", get_string_opt apply "field" with
      | Some unit_id, Some field ->
          policy_apply_unit_toggle config ~actor ~unit_id
            ~event_type:
              (if String.equal field "kill_switch" then
                 "unit_kill_switch_toggled"
               else
                 "unit_freeze_toggled")
            ~field (`Assoc [ ("enabled", U.member "enabled" apply) ])
      | _ -> Error "decision apply payload missing unit_id or field")
  | Some other -> Error (Printf.sprintf "unsupported decision apply kind: %s" other)
  | None -> Error "decision apply payload missing kind"

let update_decision_status config ~(actor : string) ~decision_id ~status ?reason () =
  let decisions = read_policy_decisions config in
  match
    List.find_opt
      (fun (decision : policy_decision_record) -> String.equal decision.decision_id decision_id)
      decisions
  with
  | None -> Error (Printf.sprintf "decision not found or not managed: %s" decision_id)
  | Some decision ->
      let updated =
        {
          decision with
          status;
          reason = option_first_some reason decision.reason;
          decided_at = Some (Types.now_iso ());
        }
      in
      write_policy_decisions config
        (updated
        :: List.filter
             (fun (row : policy_decision_record) ->
               not (String.equal row.decision_id decision_id))
             decisions);
      append_cp_event config ~trace_id:updated.trace_id
        ~event_type:
          (match status with Dec_approved -> "policy_decision_approved" | _ -> "policy_decision_denied")
        ?operation_id:updated.operation_id ?unit_id:updated.target_unit_id ~actor
        (`Assoc [ ("decision_id", `String decision_id); ("status", `String (Cp_serde.decision_status_to_string status)) ]);
      Ok updated

let policy_approve_json config ~(actor : string) json =
  match get_string_opt json "decision_id" with
  | None -> Error "decision_id is required. Call masc_policy_status to find pending decisions."
  | Some decision_id ->
      let decisions = read_policy_decisions config in
      (match
         List.find_opt
           (fun (decision : policy_decision_record) -> String.equal decision.decision_id decision_id)
           decisions
       with
      | None -> Error "decision not found or is legacy projected decision"
      | Some decision ->
          if not (decision.status = Dec_pending) then
            Error "decision is not pending"
          else
            let* result = apply_policy_decision config ~actor decision in
            let* updated =
              update_decision_status config ~actor ~decision_id ~status:Dec_approved ()
                ?reason:(get_string_opt json "reason")
            in
            Ok
              (`Assoc
                [
                  ("status", `String "ok");
                  ("decision", policy_decision_to_json updated);
                  ("result", result);
                  ("operations", list_operations_json config);
                  ("decisions", list_policy_decisions_json config);
                ]))

let policy_deny_json config ~(actor : string) json =
  match get_string_opt json "decision_id" with
  | None -> Error "decision_id is required. Call masc_policy_status to find pending decisions."
  | Some decision_id ->
      let* updated =
        update_decision_status config ~actor ~decision_id ~status:Dec_denied ()
          ?reason:(get_string_opt json "reason")
      in
      Ok
        (`Assoc
          [
            ("status", `String "ok");
            ("decision", policy_decision_to_json updated);
            ("decisions", list_policy_decisions_json config);
          ])

let detachment_status_detail_json config units agents operations
    (detachment : detachment_record) =
  let now = Time_compat.now () in
  let leader_status =
    match detachment.leader_id with
    | Some leader -> agent_status_for (agent_status_map agents) leader
    | None -> "missing"
  in
  let heartbeat_expired =
    match detachment.heartbeat_deadline with
    | Some deadline -> iso_expired_at now deadline
    | None -> false
  in
  let progress_age_sec =
    Option.bind detachment.last_progress_at parse_iso_timestamp
    |> Option.map (fun ts -> max 0 (int_of_float (now -. ts)))
  in
  let unit_label =
    lookup_unit units detachment.assigned_unit_id
    |> Option.map (fun (unit : unit_record) -> unit.label)
    |> Option.value ~default:detachment.assigned_unit_id
  in
  let operation_json =
    operation_by_id operations detachment.operation_id
    |> Option.map operation_to_json |> Option.value ~default:`Null
  in
  let search_json =
    operation_by_id operations detachment.operation_id
    |> Option.map (operation_search_json config units operations)
    |> Option.value ~default:`Null
  in
  `Assoc
    [
      ("detachment", detachment_to_json detachment);
      ("assigned_unit_label", `String unit_label);
      ("operation", operation_json);
      ("search", search_json);
      ("leader_status", `String leader_status);
      ("heartbeat_expired", `Bool heartbeat_expired);
      ( "progress_age_sec",
        Json_util.int_opt_to_json progress_age_sec );
      ( "needs_attention",
        `Bool
          (heartbeat_expired
           || String.equal leader_status "offline"
           || String.equal leader_status "missing"
           || detachment.status = Det_stalled
           || detachment.status = Det_awaiting_approval) );
    ]

let detachment_status_json config json =
  let operation_id = get_string_opt json "operation_id" in
  let detachment_id = get_string_opt json "detachment_id" in
  let agents, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let detachments =
    all_detachments config units operations
    |> List.filter (fun (detachment : detachment_record) ->
           (match operation_id with
           | Some value -> String.equal detachment.operation_id value
           | None -> true)
           &&
           match detachment_id with
           | Some value -> String.equal detachment.detachment_id value
           | None -> true)
  in
  match detachments with
  | [] -> Error "detachment not found"
  | detachment :: _ ->
      Ok
        (`Assoc
          [
            ("status", `String "ok");
            ("result", detachment_status_detail_json config units agents operations detachment);
          ])

let stalled_or_quiet_detachment now (detachment : detachment_record) =
  match detachment.heartbeat_deadline with
  | Some deadline when iso_expired_at now deadline -> true
  | _ ->
      Option.bind detachment.last_progress_at parse_iso_timestamp
      |> Option.map (fun ts -> now -. ts > 1800.0)
      |> Option.value ~default:false

(** Pick failover leader using deterministic hash-based selection.
    BUG-006: List.find_opt always returned the first eligible agent,
    causing failover to concentrate on a single keeper. *)
let pick_failover_leader live_agents (detachment : detachment_record) =
  let eligible =
    detachment.roster
    |> List.filter (fun agent_name ->
           List.mem agent_name live_agents
           && (match detachment.leader_id with
               | Some current -> not (String.equal current agent_name)
               | None -> true))
  in
  match eligible with
  | [] -> None
  | [single] -> Some single
  | _ ->
      (* Deterministic selection: hash detachment id + sorted roster to get
         a stable index that is replayable and testable. *)
      let sorted = List.sort String.compare eligible in
      let arr = Array.of_list sorted in
      let n = Array.length arr in
      let seed = Hashtbl.hash (detachment.detachment_id, sorted) in
      let idx = (seed land max_int) mod n in
      Some arr.(idx)

let maybe_escalation_target units (detachment : detachment_record) =
  match lookup_unit units detachment.assigned_unit_id with
  | Some ({ kind = Squad; parent_unit_id = Some parent_id; _ } as _unit) -> Some parent_id
  | Some unit when unit.kind = Platoon || unit.kind = Company -> unit.parent_unit_id
  | Some ({ parent_unit_id = Some parent_id; _ } as _unit) -> Some parent_id
  | _ -> None

let maybe_apply_best_first_assignment config ~actor units operations
    (operation : operation_record) =
  match operation_search_strategy operation with
  | Cp_search_fabric.Legacy -> operation
  | Cp_search_fabric.Best_first_v1 -> (
      match operation_readiness operations operation with
      | Cp_search_fabric.Blocked _ -> operation
      | Cp_search_fabric.Ready -> (
          let candidates =
            operation_search_candidates config units operations operation
          in
          match candidates with
          | [] -> operation
          | best :: _ ->
              let current =
                candidates
                |> List.find_opt (fun (candidate : Cp_search_fabric.scored_candidate) ->
                       String.equal candidate.unit_id operation.assigned_unit_id)
              in
              let should_move =
                match current with
                | Some current_candidate ->
                    String.equal best.unit_id current_candidate.unit_id
                    |> not
                    && Cp_search_fabric.should_rebalance ~current:current_candidate
                         ~best ~min_gain:15.0
                | None -> not (String.equal best.unit_id operation.assigned_unit_id)
              in
              if not should_move then
                operation
              else
                match
                  apply_operation_assignment config ~actor operation
                    ~target_unit_id:best.unit_id
                    ~note:
                      (Some
                         (Printf.sprintf "best_first_v1 routed to %s (score=%.1f)"
                            best.unit_id best.breakdown.total))
                    ~event_type:"operation_search_routed"
                with
                | Ok updated ->
                    append_cp_event config ~trace_id:updated.trace_id
                      ~event_type:"operation_search_scored"
                      ~operation_id:updated.operation_id
                      ~unit_id:updated.assigned_unit_id ~actor
                      (`Assoc
                        [
                          ("selected_unit_id", `String best.unit_id);
                          ("score", `Float best.breakdown.total);
                          ( "score_breakdown",
                            Cp_search_fabric.breakdown_to_json best.breakdown );
                          ("routing_reason", `String best.routing_reason);
                        ]);
                    updated
                | Error _ -> operation))

let dispatch_tick_json config ~(actor : string) json =
  let filter_operation_id = get_string_opt json "operation_id" in
  let filter_detachment_id = get_string_opt json "detachment_id" in
  let agents, _, units, _ = topology_units config in
  let live_agents = live_agent_names agents in
  let all_managed_operations = read_operations config in
  let managed_operations =
    all_managed_operations
    |> List.filter (fun (operation : operation_record) ->
           match filter_operation_id with
           | Some value -> String.equal operation.operation_id value
           | None -> true)
  in
  let planned_operations =
    managed_operations
    |> List.map
         (maybe_apply_best_first_assignment config ~actor units
            all_managed_operations)
  in
  let synced =
    planned_operations
    |> List.concat_map (fun (operation : operation_record) ->
           sync_managed_detachments config units operation)
    |> List.filter (fun (detachment : detachment_record) ->
           match filter_detachment_id with
           | Some value -> String.equal detachment.detachment_id value
           | None -> true)
  in
  let now = Time_compat.now () in
  let operations_by_id =
    List.map (fun (operation : operation_record) -> (operation.operation_id, operation))
      planned_operations
  in
  let decisions = ref [] in
  let failovers = ref [] in
  let escalations = ref [] in
  let stale_count = ref 0 in
  let upsert_detachment_row updated =
    write_detachments config (replace_detachment (read_detachments config) updated)
  in
  List.iter
    (fun (detachment : detachment_record) ->
      let is_stalled = stalled_or_quiet_detachment now detachment in
      let leader_status =
        match detachment.leader_id with
        | Some leader -> agent_status_for (agent_status_map agents) leader
        | None -> "missing"
      in
      if is_stalled then incr stale_count;
      if is_stalled || String.equal leader_status "offline" || String.equal leader_status "missing" then
        match pick_failover_leader live_agents detachment with
        | Some next_leader ->
            let refreshed =
              {
                detachment with
                leader_id = Some next_leader;
                status = Det_active;
                last_event_at = Some (Types.now_iso ());
                heartbeat_deadline =
                  (match lookup_unit units detachment.assigned_unit_id with
                  | Some unit ->
                      Option.bind
                        (option_first_some detachment.last_progress_at
                           (Some (Types.now_iso ())))
                        (fun base_ts ->
                          iso_after_seconds base_ts unit.policy.escalation_timeout_sec)
                  | None -> detachment.heartbeat_deadline);
                updated_at = Types.now_iso ();
              }
            in
            upsert_detachment_row refreshed;
            append_cp_event config
              ~trace_id:
                (match List.assoc_opt detachment.operation_id operations_by_id with
                | Some operation -> operation.trace_id
                | None -> next_trace_id ())
              ~event_type:"detachment_failed_over"
              ~operation_id:detachment.operation_id ~unit_id:detachment.assigned_unit_id
              ~actor
              (`Assoc
                [
                  ("detachment_id", `String detachment.detachment_id);
                  ("from_leader", Json_util.string_opt_to_json detachment.leader_id);
                  ("to_leader", `String next_leader);
                ]);
            failovers := refreshed.detachment_id :: !failovers
        | None ->
            (match
               maybe_escalation_target units detachment,
               List.assoc_opt detachment.operation_id operations_by_id
             with
            | Some target_unit_id, Some operation ->
                let pending =
                  find_pending_decision config ~requested_action:"dispatch_escalate"
                    ~operation_id:operation.operation_id ~target_unit_id ()
                in
                let refreshed =
                  {
                    detachment with
                    status =
                      (match pending with
                      | Some _ -> Det_awaiting_approval
                      | None -> Det_stalled);
                    updated_at = Types.now_iso ();
                  }
                in
                upsert_detachment_row refreshed;
                let decision =
                  match pending with
                  | Some existing -> existing
                  | None ->
                      if operation_search_strategy operation = Cp_search_fabric.Best_first_v1 then
                        update_search_stats_for_operation config operation
                          ~outcome:`Failure;
                      create_policy_decision config ~actor
                        ~requested_action:"dispatch_escalate"
                        ~scope_type:"company"
                        ~scope_id:
                          (company_scope_id_for units
                             (Some detachment.assigned_unit_id)
                             (Some target_unit_id))
                        ~operation_id:operation.operation_id
                        ~target_unit_id
                        ~reason:
                          (Some
                             (Printf.sprintf
                                "Detachment %s is stalled and needs escalation"
                                detachment.detachment_id))
                        (`Assoc
                          [
                            ( "apply",
                              `Assoc
                                [
                                  ("kind", `String "reassign_operation");
                                  ("operation_id", `String operation.operation_id);
                                  ("target_unit_id", `String target_unit_id);
                                ] );
                            ("detachment_id", `String detachment.detachment_id);
                          ])
                in
                decisions := decision.decision_id :: !decisions;
                escalations := detachment.detachment_id :: !escalations
            | _ -> ())
      else
        ())
    synced;
  let operations_json =
    list_operations_json ?operation_id:filter_operation_id config
  in
  let detachments_json =
    list_detachments_json ?operation_id:filter_operation_id ?detachment_id:filter_detachment_id
      config
  in
  Ok
    (`Assoc
      [
        ("status", `String "ok");
        ( "summary",
          `Assoc
            [
              ("operations_considered", `Int (List.length managed_operations));
              ("detachments_considered", `Int (List.length synced));
              ("stale_detachments", `Int !stale_count);
              ("failovers_applied", `Int (List.length !failovers));
              ("escalations_requested", `Int (List.length !escalations));
              ("approvals_pending", `Int (List.length !decisions));
            ] );
        ("failovers", json_list_of_strings (List.rev !failovers));
        ("escalations", json_list_of_strings (List.rev !escalations));
        ("decisions", json_list_of_strings (List.rev !decisions));
        ("operations", operations_json);
        ("detachments", detachments_json);
      ])

let observe_operations_json config =
  `Assoc
    [
      ("status", `String "ok");
      ("operations", list_operations_json config);
      ("detachments", list_detachments_json config);
    ]

let observe_capacity_json config =
  `Assoc
    [
      ("status", `String "ok");
      ("capacity", capacity_json config);
      ("alerts", list_alerts_json config);
    ]
