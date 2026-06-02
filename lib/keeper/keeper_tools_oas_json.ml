(** JSON-extract helpers for keeper_tools_oas.

    Pure Yojson helpers used by workflow-rejection / failure-class
    inspection in [Keeper_tools_oas]. All callers are inside
    [Keeper_tools_oas]; not in .mli. Extracted as a sibling for
    cohesion. *)

let detail_json_opt json =
  match Json_util.assoc_member_opt "detail" json with
  | Some (`Assoc _ as detail) -> Some detail
  | _ -> None
;;

let json_or_detail_string_opt key json =
  match Json_util.assoc_string_opt key json with
  | Some _ as value -> value
  | None ->
    (match detail_json_opt json with
     | Some detail -> Json_util.assoc_string_opt key detail
     | None -> None)
;;

let json_or_detail_bool_opt key json =
  match Json_util.assoc_bool_opt key json with
  | Some _ as value -> value
  | None ->
    (match detail_json_opt json with
     | Some detail -> Json_util.assoc_bool_opt key detail
     | None -> None)
;;

let diagnosis_json_opt json =
  match Json_util.assoc_member_opt "diagnosis" json with
  | Some (`Assoc _ as diagnosis) -> Some diagnosis
  | _ ->
    (match detail_json_opt json with
     | Some detail ->
       (match Json_util.assoc_member_opt "diagnosis" detail with
        | Some (`Assoc _ as diagnosis) -> Some diagnosis
        | _ -> None)
     | None -> None)
;;
