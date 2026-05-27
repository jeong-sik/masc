(** Keeper_persona — persona list and persona-backed keeper creation handlers. *)

open Tool_args
open Keeper_types
open Agent_tool_persona_runtime

module Turn = Keeper_turn
module Authoring = Keeper_persona_authoring
type tool_result = Keeper_types.tool_result

(* RFC-0182 §3.1 — ctx-free body shared with the persona dispatch ref
   path.  Keeper_persona / Keeper_persona_authoring transitively touch
   Keeper_turn_driver, so static import from
   Agent_tool_in_process_runtime closes a cycle.  These [_handler]
   entry points let Tool_keeper register the persona surface into
   Persona_dispatch_ref at module load. *)
let persona_list_handler args : tool_result =
  let detailed = get_bool args "detailed" true in
  let personas = list_persona_summaries () in
  let payload =
    if detailed then
      `List (List.map persona_summary_to_json personas)
    else
      string_list_to_json (List.map (fun (persona : Keeper_types_profile.persona_summary) -> persona.persona_name) personas)
  in
  let json =
    `Assoc
      [
        ("count", `Int (List.length personas));
        ("personas", payload);
      ]
  in
  (true, Yojson.Safe.to_string json)

(* TEL-OK: thin wrapper — telemetry stays in [persona_list_handler]. *)
let handle_persona_list _ctx args : tool_result = persona_list_handler args

let handle_persona_schema = Authoring.handle_persona_schema
let persona_schema_handler args : tool_result =
  Authoring.handle_persona_schema_no_ctx args

let handle_persona_generate = Authoring.handle_persona_generate

let handle_persona_save = Authoring.handle_persona_save
let persona_save_handler args : tool_result =
  Authoring.handle_persona_save_no_ctx args

let handle_keeper_create_from_persona ctx args : tool_result =
  match resolved_keeper_args_from_persona args with
  | Error e -> (false, "" ^ e)
  | Ok (persona, resolved_args) ->
      let errors = validate_resolved_keeper_create_json resolved_args in
      let dry_run = get_bool args "dry_run" false in
      if dry_run then
        let json =
          `Assoc
            [
              ("persona", persona_summary_to_json persona);
              ("ready", `Bool (errors = []));
              ("errors", string_list_to_json errors);
              ("resolved_args", resolved_args);
            ]
        in
        (true, Yojson.Safe.to_string json)
      else if errors <> [] then
        ( false,
          Yojson.Safe.pretty_to_string
            (`Assoc
              [
                ("persona", persona_summary_to_json persona);
                ("ready", `Bool false);
                ("errors", string_list_to_json errors);
                ("resolved_args", resolved_args);
              ]) )
      else
        let ok, body = Turn.handle_keeper_up ctx resolved_args in
        if not ok then
          (false, body)
        else begin
          (* Apply per-persona shard configuration after keeper creation *)
          let name = Safe_ops.json_string ~default:"" "name" resolved_args in
          if name <> "" then
            (match Safe_ops.json_string_list "shards" resolved_args with
             | _ :: _ as shard_names ->
                 Tool_shard.set_agent_shards name shard_names
             | [] -> ());
          let created_json =
            try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
          in
          let json =
            `Assoc
              [
                ("persona", persona_summary_to_json persona);
                ("created", `Bool true);
                ("result", created_json);
                ("resolved_args", resolved_args);
              ]
          in
          (true, Yojson.Safe.to_string json)
        end
