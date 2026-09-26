type t =
  | Fleet_ok
  | Fleet_degraded
  | Fleet_blocked

let all = [ Fleet_ok; Fleet_degraded; Fleet_blocked ]

let wire_name = function
  | Fleet_ok -> "ok"
  | Fleet_degraded -> "degraded"
  | Fleet_blocked -> "blocked"

let of_wire_name name =
  List.find_opt (fun grade -> String.equal (wire_name grade) name) all
