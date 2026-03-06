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
  mode = Standard;
  enabled_categories = categories_for_mode Standard;
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
      | _ -> "standard"
    in
    let mode =
      match mode_of_string mode_str with
      | Some m -> m
      | None -> Standard
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

(** Placeholder tools that are hidden by default.

    Set MASC_PLACEHOLDER_TOOLS_ENABLED=1 to expose them for manual testing.
*)
let placeholder_tools = [ "masc_archive_save" ]

let placeholder_tools_enabled () =
  match Sys.getenv_opt "MASC_PLACEHOLDER_TOOLS_ENABLED" with
  | Some "1" | Some "true" | Some "TRUE" | Some "yes" | Some "YES" -> true
  | _ -> false

let is_tool_visible tool_name =
  if placeholder_tools_enabled () then
    true
  else
    not (List.mem tool_name placeholder_tools)

let all_tool_schemas : Types.tool_schema list =
  Tools.all_schemas
  @ Tool_board.tools
  @ Tool_lodge.tools
  @ Tool_perpetual.schemas
  @ Tool_mdal.schemas
  @ Tool_keeper.schemas
  @ Tool_operator.schemas
  @ Tool_llama.schemas
  @ Tool_goals.schemas
  @ Tool_team_session.schemas
  @ Tool_protocol_game_view.schemas

let visible_tool_schemas () : Types.tool_schema list =
  List.filter (fun (schema : Types.tool_schema) -> is_tool_visible schema.name)
    all_tool_schemas

let enabled_tool_schemas (enabled_categories : Mode.category list) :
    Types.tool_schema list =
  visible_tool_schemas ()
  |> List.filter (fun (schema : Types.tool_schema) ->
         Mode.is_tool_enabled enabled_categories schema.name)

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
  let hidden_placeholder_tools =
    if placeholder_tools_enabled () then []
    else
      placeholder_tools
  in
  `Assoc [
    ("mode", `String (mode_to_string config.mode));
    ("mode_description", `String (mode_description config.mode));
    ("enabled_categories", `List (List.map (fun s -> `String s) enabled_names));
    ("disabled_categories", `List (List.map (fun s -> `String s) disabled_names));
    ("enabled_tool_count", `Int tool_count);
    ("placeholder_tools_enabled", `Bool (placeholder_tools_enabled ()));
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
