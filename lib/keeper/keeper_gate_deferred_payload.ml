type t =
  { operation : string
  ; approval_id : string
  ; reason : Keeper_gate.deferred_reason
  ; audit_receipts : Keeper_approval.Audit.receipt list
  ; context : Yojson.Safe.t option
  }

let message =
  "External effect deferred without blocking this Keeper. Continue other work; the originating Keeper will wake after resolution."
;;

let create ~operation ~approval_id ~reason ~audit_receipts ?context () =
  { operation; approval_id; reason; audit_receipts; context }
;;

let gate_json t =
  Keeper_gate.decision_to_yojson
    (Keeper_gate.Deferred
       { operation = t.operation
       ; approval_id = t.approval_id
       ; reason = t.reason
       ; audit_receipts = t.audit_receipts
       })
;;

let data t =
  let context_field =
    match t.context with
    | Some context -> [ "context", context ]
    | None -> []
  in
  `Assoc
    ([ "message", `String message
     ; "operation", `String t.operation
     ; "gate", gate_json t
     ]
     @ context_field)
;;

let to_execution t =
  Keeper_tool_execution.deferred_external_effect_data (data t)
;;

let to_tool_result ~tool_name ~start_time t =
  Tool_result.make_deferred
    ~tool_name
    ~start_time
    ~data:(data t)
    ()
;;
