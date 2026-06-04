(** Generic JSON extraction and normalization helpers for mission briefing. *)

let compact_text ?(max_len = 96) raw =
  let normalized =
    String.trim raw |> String.split_on_char '\n' |> String.concat " " |> String.trim
  in
  if normalized = "" then ""
  else String_util.utf8_safe ~max_bytes:((max_len - 1) + 3) ~suffix:"…" normalized |> String_util.to_string

let member_assoc = Dashboard_utils.member_assoc
let string_field = Dashboard_utils.string_field

let is_missing_or_unknown value =
  match String.lowercase_ascii (String.trim value) with
  | "" | "unknown" -> true
  | _ -> false

let string_json ?(default = "unknown") ?(max_len = 96) json =
  match json with
  | `String value ->
      let compact = compact_text ~max_len value in
      if compact = "" then `String default else `String compact
  | _ -> `String default

let string_json_opt ?(max_len = 96) json =
  match json with
  | `String value ->
      compact_text ~max_len value
      |> String_util.trim_to_option
      |> Json_util.string_opt_to_json
  | _ -> `Null

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
      match int_of_string_opt raw with
      | Some n -> `Int n
      | None -> `Int default)
  | `Float value -> `Int (int_of_float value)
  | _ -> `Int default

let float_json ?(default = 0.0) json =
  match json with
  | `Float value -> `Float value
  | `Int value -> `Float (float_of_int value)
  | `Intlit raw -> (
      match float_of_string_opt raw with
      | Some n -> `Float n
      | None -> `Float default)
  | _ -> `Float default

let take = List.take
