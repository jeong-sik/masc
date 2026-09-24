type t = Live | Automation

(* The [function] is exhaustive only while it names every constructor, so a
   constructor added to [t] but not to this list fails the build here. *)
let all = List.map (function (Live | Automation) as lane -> lane) [ Live; Automation ]

let to_wire = function
  | Live -> "live"
  | Automation -> "automation"
;;

let of_wire raw = List.find_opt (fun lane -> String.equal (to_wire lane) raw) all
let expected = String.concat " or " (List.map to_wire all)
