(** Keeper_persona — persona list and persona-backed keeper creation handlers. *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_persona_runtime

module Turn = Keeper_turn
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
  tool_result_ok (Yojson.Safe.to_string json)

(* TEL-OK: thin wrapper — telemetry stays in [persona_list_handler]. *)
let handle_persona_list _ctx args : tool_result = persona_list_handler args

let persona_schema_handler args : tool_result =
  let include_examples = get_bool args "include_examples" false in
  let schema =
    schemas
    |> List.find_opt (fun schema ->
      String.equal schema.Masc_domain.name "masc_persona_save")
    |> Option.map (fun schema -> schema.Masc_domain.input_schema)
    (* DET-OK: local schema registry miss degrades to an empty schema response. *)
    |> Option.value ~default:(`Assoc [])
  in
  let payload =
    [ "schema", schema
    ; ( "notes"
      , `List
          [ `String "profile must be a JSON object"
          ; `String "handle must match the keeper/persona name policy"
          ] )
    ]
  in
  let payload =
    if include_examples
    then
      ( "example"
      , `Assoc
          [ "handle", `String "reviewer"
          ; ( "profile"
            , `Assoc
                [ "name", `String "Reviewer"
                ; "role", `String "code reviewer"
                ; "keeper", `Assoc [ "goal", `String "Review pull requests" ]
                ] )
          ] )
      :: payload
    else payload
  in
  tool_result_ok (Yojson.Safe.to_string (`Assoc payload))
;;

let handle_persona_schema _ctx args = persona_schema_handler args

let persona_profile_arg args =
  match Json_util.get_object args "profile" with
  | Some profile -> Ok profile
  | None -> Error "profile must be a JSON object"
;;

let persona_target_path handle =
  match personas_root_opt () with
  | None -> Error "personas root is not configured"
  | Some root ->
    if not (validate_name handle)
    then Error "handle must match [A-Za-z0-9._-]+"
    else (
      let dir = Filename.concat root handle in
      Ok (dir, Filename.concat dir "profile.json"))
;;

let persona_save_handler args : tool_result =
  let handle = get_string args "handle" "" |> String.trim in
  let overwrite = get_bool args "overwrite" false in
  let dry_run = get_bool args "dry_run" false in
  match persona_profile_arg args, persona_target_path handle with
  | Error e, _ | _, Error e -> tool_result_error e
  | Ok profile, Ok (dir, path) ->
    if Sys.file_exists path && not overwrite
    then tool_result_error "persona already exists; pass overwrite=true to replace it"
    else (
      let payload =
        `Assoc
          [ "handle", `String handle
          ; "path", `String path
          ; "dry_run", `Bool dry_run
          ]
      in
      if dry_run
      then tool_result_ok (Yojson.Safe.to_string payload)
      else (
        let _created = ensure_dir dir in
        match Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string profile ^ "\n") with
        | Ok () -> tool_result_ok (Yojson.Safe.to_string payload)
        | Error e -> tool_result_error e))
;;

let handle_persona_save _ctx args = persona_save_handler args

let handle_keeper_create_from_persona ctx args : tool_result =
  match resolved_keeper_args_from_persona args with
  | Error e -> tool_result_error ("" ^ e)
  | Ok (persona, resolved_args) ->
      let errors = validate_resolved_keeper_create_json resolved_args in
      let dry_run = get_bool args "dry_run" false in
      if dry_run then
        let json =
          `Assoc
            [
              ("persona", persona_summary_to_json persona);
              ("ready", `Bool (errors = []));
              ("errors", Json_util.json_string_list errors);
              ("resolved_args", resolved_args);
            ]
        in
        tool_result_ok (Yojson.Safe.to_string json)
      else if errors <> [] then
        tool_result_error
          (Yojson.Safe.pretty_to_string
             (`Assoc
               [
                 ("persona", persona_summary_to_json persona);
                 ("ready", `Bool false);
                 ("errors", Json_util.json_string_list errors);
                 ("resolved_args", resolved_args);
               ]))
      else
        let result = Turn.handle_keeper_up ctx resolved_args in
        if not (tool_result_success result) then
          result
        else begin
          let body = tool_result_body result in
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
          tool_result_ok (Yojson.Safe.to_string json)
        end
