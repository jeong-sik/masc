type t =
  | Unknown
  | Not_dispatched
  | No_visible_output
  | Response_observed
  | Tool_execution_observed

let all =
  [ Unknown, "unknown"
  ; Not_dispatched, "not_dispatched"
  ; No_visible_output, "no_visible_output"
  ; Response_observed, "response_observed"
  ; Tool_execution_observed, "tool_execution_observed"
  ]
;;

let to_string = function
  | Unknown -> "unknown"
  | Not_dispatched -> "not_dispatched"
  | No_visible_output -> "no_visible_output"
  | Response_observed -> "response_observed"
  | Tool_execution_observed -> "tool_execution_observed"
;;

let of_string str =
  List.find_map
    (fun (label, encoded) -> if String.equal str encoded then Some label else None)
    all
;;
