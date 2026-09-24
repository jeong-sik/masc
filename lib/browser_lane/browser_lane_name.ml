type t = Live | Automation | Stagehand [@@deriving enumerate]

let to_wire = function
  | Live -> "live"
  | Automation -> "automation"
  | Stagehand -> "stagehand"
;;

let of_wire raw = List.find_opt (fun lane -> String.equal (to_wire lane) raw) all
let expected = String.concat " or " (List.map to_wire all)
