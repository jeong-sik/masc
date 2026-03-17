(** MASC Configuration Management

    Persists mode settings to .masc/config.json
*)

open Mode

(** Configuration record *)
type t = {
  mode : mode;
  enabled_categories : category list;
}

(** Default configuration — Full mode gives new users access to all tools.
    Use masc_switch_mode to restrict if needed (BUG-017 revisited). *)
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
    Log.Misc.error "config of_json failed: %s" (Printexc.to_string e);
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

let audit_log_path room_path =
  Filename.concat room_path "audit.jsonl"

let json_string_option = function
  | Some value when String.trim value <> "" -> `String (String.trim value)
  | _ -> `Null

let mode_change_audit_json ~actor ~source ~room_path ~previous_config ~config =
  let categories_to_json_values categories =
    `List
      (List.map
         (fun category -> `String (category_to_string category))
         categories)
  in
  let old_mode = mode_to_string previous_config.mode in
  let new_mode = mode_to_string config.mode in
  let actor_name =
    actor
    |> Option.map String.trim
    |> Option.value ~default:"unknown"
  in
  let detail =
    Printf.sprintf "mode=%s -> %s source=%s"
      old_mode new_mode
      (source |> Option.map String.trim |> Option.value ~default:"config")
  in
  `Assoc
    [
      ("timestamp", `Float (Unix.gettimeofday ()));
      ("agent", `String actor_name);
      ("event_type", `String "mode_change");
      ("success", `Bool true);
      ("detail", `String detail);
      ("room_path", `String room_path);
      ("source", json_string_option source);
      ("previous_mode", `String old_mode);
      ("mode", `String new_mode);
      ( "previous_enabled_categories",
        categories_to_json_values previous_config.enabled_categories );
      ("enabled_categories", categories_to_json_values config.enabled_categories);
    ]

let append_mode_change_audit ~actor ~source ~room_path ~previous_config ~config =
  Fs_compat.append_jsonl (audit_log_path room_path)
    (mode_change_audit_json ~actor ~source ~room_path ~previous_config ~config)

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
    @ Tool_trpg.schemas)

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
      List.iter (fun e -> Log.Config.warn "%s" e) errs

let all_tool_schemas : Types.tool_schema list =
  let schemas =
    Capability_registry.public_tool_schemas_from raw_all_tool_schemas
  in
  validate_schemas schemas;
  schemas

let all_tool_names () : string list =
  List.map (fun (s : Types.tool_schema) -> s.name) all_tool_schemas

let is_tool_visible tool_name =
  Tool_catalog.is_visible tool_name

let visible_tool_schemas ?(include_hidden = false) ?(include_deprecated = false) () :
    Types.tool_schema list =
  Capability_registry.visible_public_tool_schemas_from ~include_hidden
    ~include_deprecated raw_all_tool_schemas

let enabled_tool_schemas ?(include_hidden = false) ?(include_deprecated = false)
    (enabled_categories : Mode.category list) :
    Types.tool_schema list =
  visible_tool_schemas ~include_hidden ~include_deprecated ()
  |> List.filter (fun (schema : Types.tool_schema) ->
         if include_hidden then true
         else Mode.is_tool_enabled enabled_categories schema.name)

(** Switch to a preset mode *)
let switch_mode ?actor ?source room_path mode =
  let previous_config = load room_path in
  let enabled_categories = categories_for_mode mode in
  let config = { mode; enabled_categories } in
  save room_path config;
  append_mode_change_audit ~actor ~source ~room_path ~previous_config ~config;
  config

(** Enable specific categories (switches to Custom mode) *)
let set_categories ?actor ?source room_path categories =
  let previous_config = load room_path in
  let config = { mode = Custom; enabled_categories = categories } in
  save room_path config;
  append_mode_change_audit ~actor ~source ~room_path ~previous_config ~config;
  config

(** Enable a category *)
let enable_category ?actor ?source room_path category =
  let current = load room_path in
  let new_cats =
    if List.mem category current.enabled_categories then
      current.enabled_categories
    else
      category :: current.enabled_categories
  in
  set_categories ?actor ?source room_path new_cats

(** Disable a category *)
let disable_category ?actor ?source room_path category =
  let current = load room_path in
  let new_cats = List.filter (fun c -> c <> category) current.enabled_categories in
  set_categories ?actor ?source room_path new_cats

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
    ("server_version", `String Version.version);
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
