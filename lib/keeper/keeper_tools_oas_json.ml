(** JSON-extract helpers for keeper_tools_oas.

    Pure Yojson helpers used by workflow-rejection / failure-class
    inspection in [Keeper_tools_oas]. All callers are inside
    [Keeper_tools_oas]; not in .mli. Extracted as a sibling for
    cohesion. *)

let json_assoc_field_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let json_assoc_string_opt key json =
  match json_assoc_field_opt key json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let detail_json_opt json =
  match json_assoc_field_opt "detail" json with
  | Some (`Assoc _ as detail) -> Some detail
  | _ -> None
;;

let json_or_detail_string_opt key json =
  match json_assoc_string_opt key json with
  | Some _ as value -> value
  | None ->
    (match detail_json_opt json with
     | Some detail -> json_assoc_string_opt key detail
     | None -> None)
;;

let diagnosis_json_opt json =
  match json_assoc_field_opt "diagnosis" json with
  | Some (`Assoc _ as diagnosis) -> Some diagnosis
  | _ ->
    (match detail_json_opt json with
     | Some detail ->
       (match json_assoc_field_opt "diagnosis" detail with
        | Some (`Assoc _ as diagnosis) -> Some diagnosis
        | _ -> None)
     | None -> None)
;;
