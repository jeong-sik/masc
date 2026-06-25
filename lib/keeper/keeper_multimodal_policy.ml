type t =
  | Delegate
  | Reroute
  | Inherit

let default = Reroute

let to_string = function
  | Delegate -> "delegate"
  | Reroute -> "reroute"
  | Inherit -> "inherit"

let of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "delegate" -> Some Delegate
  | "reroute" -> Some Reroute
  | "inherit" -> Some Inherit
  | _ -> None

let resolve = function
  | Inherit -> default
  | (Delegate | Reroute) as t -> t

let delegates t =
  match resolve t with
  | Delegate -> true
  | Reroute -> false
  | Inherit -> false (* unreachable: [resolve] maps Inherit to [default] *)
