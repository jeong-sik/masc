type t = Owned_firefox | Ego [@@deriving enumerate]

let lane = function
  | Owned_firefox | Ego -> Browser_lane_name.Live
;;

let to_wire = function
  | Owned_firefox -> "owned_firefox"
  | Ego -> "ego"
;;

let of_wire raw = List.find_opt (fun backend -> String.equal (to_wire backend) raw) all
let expected = String.concat ", " (List.map to_wire all)
