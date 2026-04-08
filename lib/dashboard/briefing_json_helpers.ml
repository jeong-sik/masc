(** Generic JSON extraction and normalization helpers for mission briefing. *)

let compact_text ?(max_len = 96) raw =
  let normalized =
    String.trim raw |> String.split_on_char '\n' |> String.concat " " |> String.trim
  in
  if normalized = "" then ""
  else if String.length normalized <= max_len then normalized
  else String.sub normalized 0 (max_len - 1) ^ "…"

let member_assoc key json =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some value -> value | None -> `Null)
  | _ -> `Null

let string_field ?(default = "") key json =
  match member_assoc key json with
  | `String value -> value
  | _ -> default

let string_json ?(default = "unknown") ?(max_len = 96) json =
  match json with
  | `String value ->
      let compact = compact_text ~max_len value in
      if compact = "" then `String default else `String compact
  | _ -> `String default

let string_list_json json =
  match json with
  | `List items ->
      `List
        (items
        |> List.filter_map (function
             | `String value ->
                 let trimmed = String.trim value in
                 if trimmed = "" then None else Some (`String trimmed)
             | _ -> None))
  | _ -> `List []

let int_json ?(default = 0) json =
  match json with
  | `Int value -> `Int value
  | `Intlit raw -> (
      try `Int (int_of_string raw) with Failure _ -> `Int default)
  | `Float value -> `Int (int_of_float value)
  | _ -> `Int default

let float_json ?(default = 0.0) json =
  match json with
  | `Float value -> `Float value
  | `Int value -> `Float (float_of_int value)
  | `Intlit raw -> (
      try `Float (float_of_string raw) with Failure _ -> `Float default)
  | _ -> `Float default

let int_field ?(default = 0) key json =
  match member_assoc key json with
  | `Int value -> value
  | `Intlit raw -> (
      Option.value ~default:default (int_of_string_opt raw))
  | `Float value -> int_of_float value
  | _ -> default

let rec take n = function
  | [] -> []
  | _ when n <= 0 -> []
  | x :: xs -> x :: take (n - 1) xs

let option_string_json = function
  | Some value when String.trim value <> "" -> `String (String.trim value)
  | _ -> `Null

let trim_to_option = function
  | Some text -> Dashboard_utils.trim_to_option text
  | None -> None

let parse_iso_opt = Dashboard_utils.parse_iso_opt
