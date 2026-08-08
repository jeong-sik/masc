(** Canonical OpenAI-compatible reasoning effort values. *)

type t =
  | None_
  | Minimal
  | Low
  | Medium
  | High
  | XHigh
  | Max

let all = [ None_; Minimal; Low; Medium; High; XHigh; Max ]

let to_string = function
  | None_ -> "none"
  | Minimal -> "minimal"
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | XHigh -> "xhigh"
  | Max -> "max"
;;

let pp formatter effort = Format.pp_print_string formatter (to_string effort)
let show = to_string
let all_wire_values = List.map to_string all

let of_string value =
  let normalized = String.lowercase_ascii (String.trim value) in
  List.find_opt (fun effort -> String.equal normalized (to_string effort)) all
;;

let values_for_log = String.concat "/" (List.map to_string all)
