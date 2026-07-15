open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let current_task_id_opt (meta : keeper_meta) =
  Option.map Keeper_id.Task_id.to_string meta.current_task_id

let backend_of_meta (meta : keeper_meta) =
  match meta.sandbox_profile with
  | Docker -> "docker"
  | Local -> "local"

let string_opt_json = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null

let int_opt_json = function
  | Some value -> `Int value
  | None -> `Null

let nonempty_list = function
  | Some values -> values
  | None -> []

let backend_detail_keys =
  [ "sandbox_profile"; "network_mode"; "backend"; "sandbox_target" ]

let is_backend_detail_key key = List.mem key backend_detail_keys

let redact_backend_details = function
  | `Assoc fields ->
      `Assoc
        (List.filter
           (fun (key, _) -> not (is_backend_detail_key key))
           fields)
  | json -> json

let path_resolution_contract_json =
  `Assoc
    [ "read_implicit_cwd", `Bool false
    ; "read_explicit_cwd_supported", `Bool true
    ; ( "read_basis"
      , `String
          "Read file_path resolves against explicit cwd when cwd is provided; otherwise \
           it is relative to the keeper sandbox/allowed_paths. It does not inherit \
           Execute cwd implicitly." )
    ; ( "discover_before_read"
      , `String
          "When unsure, inspect visible paths with the currently exposed read/listing \
           tools before Read. For repo files, use cwd=\"repos/<repo>\" plus \
           file_path=\"lib/...\", or use file_path=\"repos/<repo>/lib/...\"."
      )
    ; ( "execute_path_basis"
      , `String
          "Execute path arguments resolve against cwd. If cwd=\"repos/<repo>\" is set, \
           pass repo-relative paths such as lib/...; do not repeat the repo prefix \
           as repos/<repo>/lib/..." )
    ; ( "masc_state_basis"
      , `String
          ".masc runtime state is not a sandbox filesystem target. Use keeper \
           task/context tools for .masc state instead of Read/Grep/Execute paths \
           under .masc." )
    ]

let runtime_observability_contract_json_from_fields ~keeper_name ?agent_name ?trace_id
    ?session_id ?generation ?keeper_turn_id ?task_id
    ?sandbox_profile ?sandbox_root ?allowed_paths ?network_mode
    ?runtime_profile () : Yojson.Safe.t =
  `Assoc
    [
      ("keeper_name", `String keeper_name);
      ("agent_name", string_opt_json agent_name);
      ("trace_id", string_opt_json trace_id);
      ("session_id", string_opt_json session_id);
      ("generation", int_opt_json generation);
      ("keeper_turn_id", int_opt_json keeper_turn_id);
      ("task_id", string_opt_json task_id);
      ("sandbox_profile", string_opt_json sandbox_profile);
      ("sandbox_root", string_opt_json sandbox_root);
      ("allowed_paths", Json_util.json_string_list (nonempty_list allowed_paths));
      ("path_resolution", path_resolution_contract_json);
      ("network_mode", string_opt_json network_mode);
      ("runtime_profile", string_opt_json runtime_profile);
    ]

let runtime_contract_json_from_fields ~keeper_name ?agent_name ?trace_id
    ?session_id ?generation ?keeper_turn_id ?task_id
    ?sandbox_profile ?sandbox_root ?allowed_paths ?network_mode
    ?runtime_profile () : Yojson.Safe.t =
  runtime_observability_contract_json_from_fields
    ~keeper_name
    ?agent_name
    ?trace_id
    ?session_id
    ?generation
    ?keeper_turn_id
    ?task_id
    ?sandbox_profile
    ?sandbox_root
    ?allowed_paths
    ?network_mode
    ?runtime_profile
    ()
  |> redact_backend_details


let json_string_field name = function
  | `Assoc _ as json -> Json_util.get_string_nonempty json name
  | _ -> None

let first_string_field names json =
  List.find_map (fun name -> json_string_field name json) names

let path_like_key key =
  let key = String.lowercase_ascii key in
  key = "cwd" || key = "dir" || key = "directory" || key = "file"
  || String_util.contains_substring key "path"

let collect_observed_paths json =
  let rec loop acc = function
    | `Assoc fields ->
        List.fold_left
          (fun acc (key, value) ->
            match value with
            | `String path when path_like_key key && String.trim path <> "" ->
                path :: acc
            | other -> loop acc other)
          acc fields
    | `List values -> List.fold_left loop acc values
    | _ -> acc
  in
  loop [] json
  |> List.sort_uniq String.compare

let target_kind_of_input input target_path =
  match json_string_field "target_kind" input with
  | Some value -> value
  | None -> (
      match json_string_field "kind" input with
      | Some value -> value
      | None -> (
          match target_path with
          | Some _ -> "path"
          | None -> "tool"))

let action_radius_json ~tool_name ~input ~success ~duration_ms ?error
    ?sandbox_target () : Yojson.Safe.t =
  let action_key =
    first_string_field [ "action"; "action_key"; "op"; "cmd"; "command" ] input
    |> Option.value ~default:tool_name
  in
  let target_path =
    first_string_field
      [
        "target_path";
        "path";
        "file_path";
        "repo_path";
        "cwd";
      ]
      input
  in
  `Assoc
    [
      ("tool_name", `String tool_name);
      ("action_key", `String action_key);
      ("target_kind", `String (target_kind_of_input input target_path));
      ("target_path", string_opt_json target_path);
      ("sandbox_target", string_opt_json sandbox_target);
      ("observed_paths", Json_util.json_string_list (collect_observed_paths input));
      ("success", `Bool success);
      ("duration_ms", `Float duration_ms);
      ("error", string_opt_json error);
    ]

let runtime_contract_json ~(config : Workspace.config) (meta : keeper_meta) : Yojson.Safe.t =
  ignore config;
  `Assoc
    [ ("task_id", Json_util.string_opt_to_json (current_task_id_opt meta)) ]

let runtime_observability_contract_json ~(config : Workspace.config) (meta : keeper_meta) : Yojson.Safe.t =
  let sandbox_target = backend_of_meta meta in
  match runtime_contract_json ~config meta with
  | `Assoc fields ->
    `Assoc
      ([
         ("sandbox_profile", `String (sandbox_profile_to_string meta.sandbox_profile));
         ("network_mode", `String (network_mode_to_string meta.network_mode));
         ("backend", `String sandbox_target);
         ("sandbox_target", `String sandbox_target);
       ]
       @ fields)
  | json -> json
