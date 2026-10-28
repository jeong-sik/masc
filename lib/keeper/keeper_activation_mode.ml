type t = Manual | On_demand | Autonomous [@@deriving enumerate]
let default = Autonomous
let restore_owner = function Manual -> false | On_demand | Autonomous -> true
let spontaneous = function Manual | On_demand -> false | Autonomous -> true
let to_string = function Manual -> "manual" | On_demand -> "on_demand" | Autonomous -> "autonomous"
let of_string s = List.find_opt (fun v -> String.equal (to_string v) s) all
let all = [ Manual; On_demand; Autonomous ]
let to_yojson mode = `String (to_string mode)
