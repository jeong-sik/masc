type t = Automation | Stagehand | Owned_firefox | Ego | External_host [@@deriving enumerate]

let lane = function
  | Automation -> Browser_lane_name.Automation
  | Stagehand -> Browser_lane_name.Stagehand
  | Owned_firefox | Ego | External_host -> Browser_lane_name.Live
;;

let to_wire = function
  | Automation -> "automation"
  | Stagehand -> "stagehand"
  | Owned_firefox -> "owned_firefox"
  | Ego -> "ego"
  | External_host -> "external_host"
;;

let of_wire raw = List.find_opt (fun backend -> String.equal (to_wire backend) raw) all
let expected = String.concat ", " (List.map to_wire all)
