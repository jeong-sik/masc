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

(* Ordinal position on the canonical effort ladder. The variant declaration
   order already encodes the ladder (None_ < Minimal < ... < Max); this
   explicit map makes the order nameable and keeps [compare] total so a future
   variant addition surfaces as a non-exhaustive match instead of a silent
   misorder. *)
let rank = function
  | None_ -> 0
  | Minimal -> 1
  | Low -> 2
  | Medium -> 3
  | High -> 4
  | XHigh -> 5
  | Max -> 6
;;

let compare a b = Int.compare (rank a) (rank b)

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

(* The categorical wire has no boolean toggle, so an explicit disable can only
   travel as the effort [None_]. Kept here, below both the request encoder and
   the ladder admission, so the two read one rule. *)
let under_explicit_toggle ~enable_thinking reasoning_effort =
  match enable_thinking with
  | Some false -> Some None_
  | Some true | None -> reasoning_effort
;;
