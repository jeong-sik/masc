type t =
  | Runtime_status
  | Bindings
  | Audit

let to_wire = function
  | Runtime_status -> "runtime_status"
  | Bindings -> "bindings"
  | Audit -> "audit"
;;

let all = [ Runtime_status; Bindings; Audit ]
let to_yojson capabilities =
  `List (List.map (fun capability -> `String (to_wire capability)) capabilities)
;;

let all_json = to_yojson all
