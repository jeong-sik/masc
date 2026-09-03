type t =
  { operation : string
  ; approval_id : string
  ; reason : Keeper_gate.deferred_reason
  ; audit_receipts : Keeper_approval.Audit.receipt list
  ; context : Yojson.Safe.t option
  }

(* The Keeper is the only thing that can say this out loud. Approval prompts
   deliberately never reach chat connectors -- approval is offered on the
   operator's own surface -- so for anyone talking to this Keeper elsewhere,
   its own sentence is the only account of why the answer is not here yet. *)
let message =
  "External effect deferred; nothing has run yet. This Keeper is not blocked, so continue other work in this same turn. If someone is waiting on an answer, tell them the call is parked for approval before you move on: your reply is the only place they see it. The host replays the parked call once the approval resolves, so do not call it again."
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
