(** Keeper_tools_oas_deterministic_error — Deterministic error recovery.

    Pure logic for extracting structured recovery plans from
    deterministic failure payloads.

    @since P3 extraction *)

open Keeper_tools_oas_workflow

let json_assoc_field_opt = Keeper_tools_oas_json.json_assoc_field_opt
let detail_json_opt = Keeper_tools_oas_json.detail_json_opt
let json_assoc_string_opt = Keeper_tools_oas_json.json_assoc_string_opt

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

let deterministic_recovery_plan_fields raw =
  try
    let json = Yojson.Safe.from_string raw in
    match recovery_plan_json_opt json with
    | None -> []
    | Some plan ->
      let next_tool =
        match json_assoc_string_opt "next_tool" plan with
        | Some next_tool -> [ "required_next_tool", `String next_tool ]
        | None -> []
      in
      ("recovery_plan", plan) :: next_tool
  with
  | Yojson.Json_error _ -> []
;;

