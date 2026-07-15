type capability = Invoke_turn
type target = Keeper of Keeper_id.Keeper_name.t

type run_ref = { run_id : string; target : target; capability : capability }

type result_contract =
  | Awaiting_execution
  | Publication_uncertain
  | Running
  | Yielded
  | Cancellation_requested
  | Cancelled
  | Completed
  | Failed

let target_name = function Keeper name -> Keeper_id.Keeper_name.to_string name

let target_to_json target =
  `Assoc [ "kind", `String "keeper"; "name", `String (target_name target) ]

let run_id reference = reference.run_id
let run_ref_target_name reference = target_name reference.target

let run_ref_to_json reference =
  `Assoc
    [ "run_id", `String reference.run_id
    ; "target", target_to_json reference.target
    ; "capability", `String "invoke_turn"
    ]
;;

let result_contract_to_string = function
  | Awaiting_execution -> "awaiting_execution"
  | Publication_uncertain -> "publication_uncertain"
  | Running -> "running"
  | Yielded -> "yielded"
  | Cancellation_requested -> "cancellation_requested"
  | Cancelled -> "cancelled"
  | Completed -> "completed"
  | Failed -> "failed"
;;

let result_contract_of_string = function
  | "awaiting_execution" -> Some Awaiting_execution
  | "publication_uncertain" -> Some Publication_uncertain
  | "running" -> Some Running
  | "yielded" -> Some Yielded
  | "cancellation_requested" -> Some Cancellation_requested
  | "cancelled" -> Some Cancelled
  | "completed" -> Some Completed
  | "failed" -> Some Failed
  | _ -> None
;;
