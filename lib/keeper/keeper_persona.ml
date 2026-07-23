(** Keeper_persona — persona list handlers. *)

open Tool_args
open Keeper_types_profile
open Keeper_tool_persona_runtime

type tool_result = Keeper_types_profile.tool_result
let persona_list_handler args : tool_result =
  let detailed = get_bool args "detailed" true in
  let personas = list_persona_summaries () in
  let payload =
    if detailed then
      `List (List.map persona_summary_to_json personas)
    else
      Json_util.json_string_list (List.map (fun (persona : Keeper_types_profile.persona_summary) -> persona.persona_name) personas)
  in
  let json =
    `Assoc
      [
        ("count", `Int (List.length personas));
        ("personas", payload);
      ]
  in
  tool_result_ok_data json

(* TEL-OK: thin wrapper — telemetry stays in [persona_list_handler]. *)
let handle_persona_list _ctx args : tool_result = persona_list_handler args
