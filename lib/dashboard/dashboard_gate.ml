(** Dashboard projection of the Keeper external-effect Gate.

    This module exposes only the non-hierarchical Gate mode, durable HITL
    queue, and recent decisions. It derives no product policy or execution
    authority. *)

let hitl_status_json ~base_path =
  `Assoc [ "gate_mode", Keeper_gate_mode.status_json ~base_path ]
;;

let dashboard_json ~base_path ~limit:_ ~offset:_ ~status_filter:_ =
  let approval_queue = Keeper_approval_queue.list_pending_dashboard_json () in
  let recent_resolved =
    Keeper_approval_queue.list_recent_resolved_json
      ~base_path
      ~n:Keeper_approval_queue.recent_resolved_history_limit
      ()
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; ( "note"
      , `String
          "External effects use explicit configured allow, Auto Judge, or nonblocking human HITL." )
    ; "approval_queue", approval_queue
    ; "recent_resolved", `List recent_resolved
    ; "hitl", hitl_status_json ~base_path
    ]
;;
