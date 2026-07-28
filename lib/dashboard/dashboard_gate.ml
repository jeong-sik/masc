(** Dashboard projection of the Keeper external-effect Gate.

    This module exposes only the non-hierarchical Gate mode, durable HITL
    queue, exact Always Allowed rules, and recent decisions. It derives no
    product policy or execution authority. *)

let hitl_status_json ~base_path =
  `Assoc [ "gate_mode", Keeper_gate_mode.status_json ~base_path ]
;;

(* The page bounds travel with the rows. Without them a client cannot tell an
   empty window from a store it never reached, or a complete history from the
   newest slice of one. *)
let recent_resolved_page_json (history : Keeper_approval_queue.resolved_history) =
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
  let resolved_history =
    Keeper_approval_queue.list_recent_resolved ~base_path ~limit ~window_minutes ()
  in
  let approval_rules, approval_rules_state =
    match Keeper_approval_queue.list_rules_dashboard_json ~base_path () with
    | Ok json -> json, `Assoc [ "state", `String "ready" ]
    | Error error ->
      ( `List []
      , `Assoc
          [ "state", `String "unavailable"
          ; "error", `String (Keeper_approval_queue.rule_store_error_to_string error)
          ] )
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; ( "note"
      , `String
          "External effects use exact Always Allowed, Auto Judge, or nonblocking human HITL." )
    ; "approval_queue", approval_queue
    ; "approval_queue_state", approval_queue_state
    ; "recent_resolved", `List resolved_history.resolved_rows
    ; "recent_resolved_page", recent_resolved_page_json resolved_history
    ; "approval_rules", approval_rules
    ; "approval_rules_state", approval_rules_state
    ; "hitl", hitl_status_json ~base_path
    ]
;;
