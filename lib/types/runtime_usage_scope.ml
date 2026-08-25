type t =
  | Per_request
  | Conversation_cumulative
  | Usage_scope_unavailable

let to_string = function
  | Per_request -> "per_request"
  | Conversation_cumulative -> "conversation_cumulative"
  | Usage_scope_unavailable -> "unavailable"
;;

let of_string = function
  | "per_request" -> Some Per_request
  | "conversation_cumulative" -> Some Conversation_cumulative
  | "unavailable" -> Some Usage_scope_unavailable
  | _ -> None
;;
