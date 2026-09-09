type t = Manual | On_demand | Autonomous
let default = Autonomous
let restore_owner = function Manual -> false | On_demand | Autonomous -> true
let spontaneous = function Manual | On_demand -> false | Autonomous -> true
let to_string = function Manual -> "manual" | On_demand -> "on_demand" | Autonomous -> "autonomous"
let of_string = function
  | "manual" -> Some Manual
  | "on_demand" -> Some On_demand
  | "autonomous" -> Some Autonomous
  | _ -> None
let to_yojson mode = `String (to_string mode)
