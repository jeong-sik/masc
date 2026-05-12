type t =
  | Initialized
  | Updated
  | Added
  | Delivered
  | Set
  | Cleared

let to_label = function
  | Initialized -> "initialized"
  | Updated -> "updated"
  | Added -> "added"
  | Delivered -> "delivered"
  | Set -> "set"
  | Cleared -> "cleared"
;;

let status_field outcome : string * Yojson.Safe.t =
  ("status", `String (to_label outcome))
;;
