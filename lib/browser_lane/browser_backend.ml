type t = Ego [@@deriving enumerate]

let lane = function
  | Ego -> Browser_lane_name.Live
;;

let to_wire = function
  | Ego -> "ego"
;;

let of_wire raw = List.find_opt (fun backend -> String.equal (to_wire backend) raw) all
let expected = String.concat ", " (List.map to_wire all)
