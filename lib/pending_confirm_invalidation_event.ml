(* This is a hint to re-read the workspace waiting inventory, not a row or a
   claim that a store write succeeded. No confirmation tokens are sent. *)
let event_type = "operator_pending_confirm_invalidated"
let json = `Assoc [ "type", `String event_type ]
