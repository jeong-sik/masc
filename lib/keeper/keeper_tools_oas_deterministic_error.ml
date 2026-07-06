(** Keeper_tools_oas_deterministic_error — Deterministic error recovery.

    Pure logic for extracting structured recovery plans from
    deterministic failure payloads.

    @since P3 extraction *)

open Keeper_tools_oas_workflow

let json_assoc_field_opt = Json_util.assoc_member_opt
let detail_json_opt = Keeper_tools_oas_json.detail_json_opt
let json_assoc_string_opt = Json_util.assoc_string_opt

let recovery_plan_json_opt json =
  match json_assoc_field_opt "recovery_plan" json with
  | Some (`Assoc _ as plan) -> Some plan
  | _ ->
    (match detail_json_opt json with
     | Some detail ->
       (match json_assoc_field_opt "recovery_plan" detail with
        | Some (`Assoc _ as plan) -> Some plan
        | _ -> None)
     | None -> None)
;;

type deterministic_recovery_plan_parse_error =
  | Deterministic_recovery_plan_json_decode_error of string

let deterministic_recovery_plan_parse_error_to_string = function
  | Deterministic_recovery_plan_json_decode_error message ->
    "json_decode_error: " ^ message
;;

let deterministic_recovery_plan_fields_result raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error message ->
    Error (Deterministic_recovery_plan_json_decode_error message)
  | json ->
    match recovery_plan_json_opt json with
    | None -> Ok []
    | Some plan ->
      let next_tool =
        match json_assoc_string_opt "next_tool" plan with
        | Some next_tool -> [ "required_next_tool", `String next_tool ]
        | None -> []
      in
      Ok (("recovery_plan", plan) :: next_tool)
;;

let deterministic_recovery_plan_fields raw =
  match deterministic_recovery_plan_fields_result raw with
  | Ok fields -> fields
  | Error (Deterministic_recovery_plan_json_decode_error _) -> []
;;
