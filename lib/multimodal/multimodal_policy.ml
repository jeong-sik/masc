type t =
  | Delegate
  | Reroute
  | Inherit

let default = Reroute

let to_string = function
  | Delegate -> "delegate"
  | Reroute -> "reroute"
  | Inherit -> "inherit"

let expected_values = [ "delegate"; "reroute"; "inherit" ]

let of_string_result raw =
  let normalized = String.lowercase_ascii (String.trim raw) in
  match normalized with
  | "delegate" -> Ok Delegate
  | "reroute" -> Ok Reroute
  | "inherit" -> Ok Inherit
  | _ ->
    Error
      (Printf.sprintf
         "invalid multimodal_policy %S; expected one of: %s"
         raw
         (String.concat ", " expected_values))

let of_string raw = Result.to_option (of_string_result raw)

let of_string_or_log ?(source = "multimodal_policy") raw =
  match of_string_result raw with
  | Ok policy -> Some policy
  | Error msg ->
    Log.Keeper.warn "%s: %s" source msg;
    None

let resolve = function
  | Inherit -> default
  | (Delegate | Reroute) as t -> t

let resolve_optional = function
  | Some policy -> resolve policy
  | None -> default

let delegates t =
  match resolve t with
  | Delegate -> true
  | Reroute -> false
  | Inherit -> false (* unreachable: [resolve] maps Inherit to [default] *)
