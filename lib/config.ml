(** MASC Configuration Management

    Persists mode settings to .masc/config.json
*)

open Mode

(** Configuration record *)
type t = {
  mode : mode;
  enabled_categories : category list;
}

(** Default configuration *)
let default = {
  mode = Full;
  enabled_categories = categories_for_mode Full;
}

(** Config file name *)
let config_filename = "config.json"

(** Get config file path *)
let config_path room_path =
  Filename.concat room_path config_filename

(** Convert config to JSON *)
let to_json config =
  `Assoc [
    ("mode", `String (mode_to_string config.mode));
    ("enabled_categories", categories_to_json config.enabled_categories);
  ]

(** Parse config from JSON *)
let of_json json =
  try
    let mode_str =
      match Yojson.Safe.Util.member "mode" json with
      | `String s -> s
      | _ -> "full"
    in
    let mode =
      match mode_of_string mode_str with
      | Some m -> m
      | None -> Full
    in
    let enabled_categories =
      match mode with
      | Custom ->
        let cats_json = Yojson.Safe.Util.member "enabled_categories" json in
        categories_of_json cats_json
      | _ -> categories_for_mode mode
    in
    { mode; enabled_categories }
  with e ->
    Printf.eprintf "[WARN] config of_json failed: %s\n%!" (Printexc.to_string e);
    default

(** Load config from file *)
let load room_path =
  let path = config_path room_path in
  match Safe_ops.read_json_file_safe path with
  | Ok json -> of_json json
  | Error _ -> default

(** Save config to file *)
let save room_path config =
  let path = config_path room_path in
  Room_utils.mkdir_p (Filename.dirname path);
  let json = to_json config in
  let content = Yojson.Safe.pretty_to_string json in
  let oc = open_out path in
  output_string oc content;
  close_out oc

let dedupe_schemas (schemas : Types.tool_schema list) =
  let seen = Hashtbl.create (List.length schemas) in
  List.filter
    (fun (schema : Types.tool_schema) ->
      if Hashtbl.mem seen schema.name then
        false
      else (
        Hashtbl.add seen schema.name ();
        true))
    schemas

let raw_all_tool_schemas : Types.tool_schema list =
  dedupe_schemas
    (Tools.raw_schemas
    @ Tool_board.tools
    @ Tool_lodge.tools
    @ Tool_perpetual.schemas
    @ Tool_mdal.schemas
    @ Tool_keeper.schemas
    @ Tool_operator.schemas
    @ Tool_llama.schemas
    @ Tool_command_plane.schemas
    @ Tool_goals.schemas
    @ Tool_team_session.schemas
    @ Tool_voice.schemas
    @ Tool_protocol_game_view.schemas
    @ Tool_experiment.schemas
    @ Tool_trpg.schemas
    @ Tool_risc.schemas
    @ Tool_autoresearch.schemas)

(** Validate tool schemas at module initialization time.
    Logs warnings for: duplicate names, empty names/descriptions,
    input_schema.type not "object". Does not block startup. *)
let validate_schemas (schemas : Types.tool_schema list) =
  let errors = ref [] in
  let seen = Hashtbl.create (List.length schemas) in
  List.iter
    (fun (schema : Types.tool_schema) ->
      if Hashtbl.mem seen schema.name then
        errors :=
          Printf.sprintf "Duplicate tool name: %s" schema.name :: !errors
      else Hashtbl.replace seen schema.name ();
      if schema.name = "" then
        errors := "Empty tool name found" :: !errors;
      if schema.description = "" then
        errors :=
          Printf.sprintf "Empty description for tool: %s" schema.name
          :: !errors;
      match Yojson.Safe.Util.member "type" schema.input_schema with
      | `String "object" -> ()
      | _ ->
          errors :=
            Printf.sprintf "Tool %s: input_schema.type is not 'object'"
              schema.name
            :: !errors)
    schemas;
  match !errors with
  | [] -> ()
  | errs ->
      List.iter (fun e -> Printf.eprintf "[SCHEMA WARN] %s\n%!" e) errs

let all_tool_schemas : Types.tool_schema list =
  let schemas = Tool_help_registry.canonicalize_schemas raw_all_tool_schemas in
  validate_schemas schemas;
  schemas

let all_tool_names () : string list =
  List.map (fun (s : Types.tool_schema) -> s.name) all_tool_schemas

let is_tool_visible tool_name =
  Tool_catalog.is_visible tool_name

let visible_tool_schemas ?(include_hidden = false) ?(include_deprecated = false) () :
    Types.tool_schema list =
  List.filter
    (fun (schema : Types.tool_schema) ->
      Tool_catalog.is_visible ~include_hidden ~include_deprecated schema.name)
    all_tool_schemas

let enabled_tool_schemas ?(include_hidden = false) ?(include_deprecated = false)
    (enabled_categories : Mode.category list) :
    Types.tool_schema list =
  visible_tool_schemas ~include_hidden ~include_deprecated ()
  |> List.filter (fun (schema : Types.tool_schema) ->
         if include_hidden then true
         else
           let meta = Tool_catalog.metadata schema.name in
           meta.Tool_catalog.visibility = Tool_catalog.Hidden
           || Mode.is_tool_enabled enabled_categories schema.name)

(** Switch to a preset mode *)
let switch_mode room_path mode =
  let enabled_categories = categories_for_mode mode in
  let config = { mode; enabled_categories } in
  save room_path config;
  config

(** Enable specific categories (switches to Custom mode) *)
let set_categories room_path categories =
  let config = { mode = Custom; enabled_categories = categories } in
  save room_path config;
  config

(** Enable a category *)
let enable_category room_path category =
  let current = load room_path in
  let new_cats =
    if List.mem category current.enabled_categories then
      current.enabled_categories
    else
      category :: current.enabled_categories
  in
  set_categories room_path new_cats

(** Disable a category *)
let disable_category room_path category =
  let current = load room_path in
  let new_cats = List.filter (fun c -> c <> category) current.enabled_categories in
  set_categories room_path new_cats

(** Get current config summary as JSON for tool response *)
let get_config_summary room_path =
  let config = load room_path in
  let enabled_names = List.map category_to_string config.enabled_categories in
  let disabled = List.filter (fun c -> not (List.mem c config.enabled_categories)) all_categories in
  let disabled_names = List.map category_to_string disabled in
  let enabled = enabled_tool_schemas config.enabled_categories in
  let tool_count = List.length enabled in
  let hidden_placeholder_tools = Tool_catalog.hidden_placeholder_tools () in
  `Assoc [
    ("mode", `String (mode_to_string config.mode));
    ("mode_description", `String (mode_description config.mode));
    ("enabled_categories", `List (List.map (fun s -> `String s) enabled_names));
    ("disabled_categories", `List (List.map (fun s -> `String s) disabled_names));
    ("enabled_tool_count", `Int tool_count);
    ("placeholder_tools_enabled", `Bool (Tool_catalog.placeholder_tools_enabled ()));
    ("hidden_placeholder_tools", `List (List.map (fun s -> `String s) hidden_placeholder_tools));
    ("available_modes", `List [
      `Assoc [("name", `String "minimal"); ("description", `String (mode_description Minimal))];
      `Assoc [("name", `String "standard"); ("description", `String (mode_description Standard))];
      `Assoc [("name", `String "parallel"); ("description", `String (mode_description Parallel))];
      `Assoc [("name", `String "coding"); ("description", `String (mode_description Coding))];
      `Assoc [("name", `String "full"); ("description", `String (mode_description Full))];
      `Assoc [("name", `String "solo"); ("description", `String (mode_description Solo))];
    ]);
  ]
