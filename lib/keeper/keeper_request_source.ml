type t =
  | Keeper_history of { trace_id : string }
  | Completion_review

let trace_id = function
  | Keeper_history { trace_id } -> Some trace_id
  | Completion_review -> None
