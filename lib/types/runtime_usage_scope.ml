type t =
  | Per_request
  | Turn_total
  | Conversation_cumulative
  | Usage_scope_unavailable
[@@deriving enumerate]

let to_string = function
  | Per_request -> "per_request"
  | Turn_total -> "turn_total"
  | Conversation_cumulative -> "conversation_cumulative"
  | Usage_scope_unavailable -> "unavailable"
;;

let of_string = function
  | "per_request" -> Some Per_request
  | "turn_total" -> Some Turn_total
  | "conversation_cumulative" -> Some Conversation_cumulative
  | "unavailable" -> Some Usage_scope_unavailable
  | _ -> None
;;
