let event_type = "internal_agent_runs_changed"

type registry =
  | Verification
  | Goal_verification
  | Exact_lane

let registry_to_wire = function
  | Verification -> "verification"
  | Goal_verification -> "goal_verification"
  | Exact_lane -> "exact_lane"
;;

let registry_of_wire = function
  | "verification" -> Some Verification
  | "goal_verification" -> Some Goal_verification
  | "exact_lane" -> Some Exact_lane
  | _ -> None
;;

let to_json registry =
  `Assoc [ ("type", `String event_type); ("registry", `String (registry_to_wire registry)) ]
;;
