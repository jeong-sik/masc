(** Keeper_runtime_trust_timeline_json — JSON accessors and small
    utility functions extracted from [Keeper_runtime_trust_timeline]
    (514 LoC).  Timeline event builders and sort/selection logic
    remain in the parent.
    @since Keeper 500-line decomposition *)

let json_member = Server_dashboard_http_json_utils.json_member

let json_int_opt_member key json =
  match json_member key json with
  | `Int n -> Some n
  | `Intlit raw -> int_of_string_opt raw
  | _ -> None

let json_float_opt_member key json =
  match json_member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> float_of_string_opt raw
  | _ -> None

let json_string_opt_member key json =
  match json_member key json with
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let json_string_opt_value = function
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let json_bool_opt_member key json =
  match json_member key json with
  | `Bool value -> Some value
  | _ -> None

let json_list_member key json =
  match json_member key json with
  | `List items -> items
  | _ -> []

let json_string_list_member key json =
  json_list_member key json
  |> List.filter_map (function
       | `String value when String.trim value <> "" -> Some value
       | _ -> None)

let assoc_bool_default key ~default fields =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> value
  | _ -> default

let assoc_string_opt key fields =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None

let assoc_json_opt key fields =
  match List.assoc_opt key fields with
  | Some `Null | None -> None
  | Some value -> Some value

let iso_of_unix_seconds ts =
  Masc_domain.iso8601_of_unix_seconds ts

let take limit values =
  values |> List.filteri (fun idx _ -> idx < limit)

let goal_ids_of_json json =
  match json_string_list_member "goal_ids" json with
  | [] -> (
      match json_string_opt_member "goal_id" json with
      | Some goal_id -> [ goal_id ]
      | None -> [])
  | goal_ids -> goal_ids

let keeper_turn_id_of_json json =
  match json_int_opt_member "keeper_turn_id" json with
  | Some _ as value -> value
  | None -> (
      match json_int_opt_member "turn_id" json with
      | Some _ as value -> value
      | None -> json_int_opt_member "turn" json)
