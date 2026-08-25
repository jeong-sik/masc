(** Dashboard projection of the Keeper external-effect Gate.

    This module exposes only the non-hierarchical Gate mode, durable HITL
    queue, exact Always Allowed rules, and recent decisions. It derives no
    product policy or execution authority. *)

(* Which exact-output lane serves Gate Auto Judge, read from the published
   runtime registry. The first slot is the model that judges; later slots are
   AGENT_CORE failover order. An unpublished or busy registry reports itself as a
   closed unavailable variant instead of guessing (#26126). *)
let judge_lane_json () =
  let lane_id = Hitl_summary_worker.lane_id in
  let unavailable reason =
    `Assoc
      [ "status", `String "unavailable"
      ; "lane_id", `String lane_id
      ; "reason", `String reason
      ]
  in
  match Runtime_exact_output_registry.current () with
  | Error error ->
    unavailable (Runtime_exact_output_registry.publication_error_to_string error)
  | Ok registry ->
    (match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
     | Error error ->
       unavailable (Runtime_exact_output_registry.lane_resolution_error_to_string error)
     | Ok { selected_slots } ->
       `Assoc
         [ "status", `String "available"
         ; "lane_id", `String lane_id
         ; ( "slots"
           , `List
               (List.map
                  (fun (slot : Runtime_exact_output_registry.selected_slot) ->
                    `String slot.slot_id)
                  selected_slots) )
         ])
;;

let hitl_status_json ~base_path =
  `Assoc
    [ "gate_mode", Keeper_gate_mode.status_json ~base_path
    ; "judge_lane", judge_lane_json ()
    ]
;;

(* The page bounds travel with the rows. Without them a client cannot tell an
   empty window from a store it never reached, or a complete history from the
   newest slice of one. *)
let recent_resolved_page_json (history : Keeper_approval.Audit.resolved_history) =
  `Assoc
    [ "returned", `Int (List.length history.resolved_rows)
    ; "matched", `Int history.resolved_matched
    ; "limit", `Int history.resolved_limit
    ; "window_minutes", `Int history.resolved_window_minutes
    ; "truncated", `Bool (history.resolved_matched > history.resolved_limit)
    ; "scan_exhausted", `Bool history.resolved_scan_exhausted
    ]
;;

let dashboard_json ~base_path ~limit ~window_minutes =
  let approval_queue, approval_queue_state =
    match
      Keeper_approval_queue.list_pending_dashboard_json_for_workspace
        ~base_path
    with
    | Ok items ->
      `List items, Keeper_approval_queue.approval_queue_ready_state_json
    | Error error ->
      `Null, Keeper_approval_queue.approval_queue_unavailable_state_json error
  in
  (* NDT-OK: HTTP observation boundary; captured once for the pure projection,
     matching [Dashboard_gate_metrics.gate_tool_events_json]. *)
  let now_ts = Unix.gettimeofday () in
  let recent_resolved, recent_resolved_page, recent_resolved_state =
    match
      Keeper_approval.Audit.list_recent_resolved
        ~base_path
        ~now_ts
        ~limit
        ~window_minutes
        ()
    with
    | Ok history ->
      ( `List history.resolved_rows
      , recent_resolved_page_json history
      , `Assoc [ "state", `String "ready" ] )
    | Error error ->
      ( `Null
      , `Null
      , `Assoc
          [ "state", `String "unavailable"
          ; "stage", `String (Keeper_approval.Audit.read_stage_to_string error.stage)
          ; "error", `String error.detail
          ] )
  in
  let approval_rules, approval_rules_state =
    match Keeper_approval_queue_rules.list_rules_dashboard_json ~base_path () with
    | Ok json -> json, `Assoc [ "state", `String "ready" ]
    | Error error ->
      ( `List []
      , `Assoc
          [ "state", `String "unavailable"
          ; "error", `String (Keeper_approval_queue_rules_types.rule_store_error_to_string error)
          ] )
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; ( "note"
      , `String
          "External effects use exact Always Allowed, Auto Judge, or nonblocking human HITL." )
    ; "approval_queue", approval_queue
    ; "approval_queue_state", approval_queue_state
    ; "recent_resolved", recent_resolved
    ; "recent_resolved_page", recent_resolved_page
    ; "recent_resolved_state", recent_resolved_state
    ; "approval_rules", approval_rules
    ; "approval_rules_state", approval_rules_state
    ; "hitl", hitl_status_json ~base_path
    ]
;;
