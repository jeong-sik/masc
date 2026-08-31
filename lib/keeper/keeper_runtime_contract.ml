open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let current_task_id_opt (meta : keeper_meta) =
  Option.map Keeper_id.Task_id.to_string meta.current_task_id

let backend_of_meta (meta : keeper_meta) =
  match meta.sandbox_profile with
  | Docker -> "docker"
  | Micro_vm -> "microvm"
  | Remote_ssh -> "remote_ssh"

(* Closed set of claim-scope modes. Was a bare [string] (#20674): producers
   and consumers matched on free string literals, so the compiler could not
   force a consumer to handle a new mode, and a dropped producer left a dead
   [empty_goal_scope_fallback_all_tasks] arm frozen in the consumer. A closed
   variant makes every producer/consumer exhaustive at compile time. *)
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
           it is relative to the keeper sandbox/sandbox_roots. It does not inherit \
           Execute cwd implicitly." )
    ; ( "discover_before_read"
      , `String
          "When unsure, inspect visible paths with the currently exposed read/listing \
           tools before Read. For files inside a checkout, set cwd to that checkout \
           and pass file_path relative to it."
      )
    ; ( "execute_path_basis"
      , `String
          "Execute path arguments resolve against cwd. When cwd is set, pass paths \
           relative to it; do not repeat the cwd prefix in the path." )
    ; ( "masc_state_basis"
      , `String
          ".masc runtime state is not a sandbox filesystem target. Use keeper \
           task/context tools for .masc state instead of Read/Grep/Execute paths \
           under .masc." )
    ]

let runtime_observability_contract_json_from_fields ~keeper_name ?trace_id
    ?session_id ?generation ?keeper_turn_id ?task_id ?goal_ids
    ?sandbox_profile ?sandbox_root ?sandbox_roots ?network_mode
    ?runtime_profile () : Yojson.Safe.t =
  `Assoc
    [
      ("keeper_name", `String keeper_name);
      ("trace_id", string_opt_json trace_id);
      ("session_id", string_opt_json session_id);
      ("generation", int_opt_json generation);
      ("keeper_turn_id", int_opt_json keeper_turn_id);
      ("task_id", string_opt_json task_id);
      ("goal_ids", Json_util.json_string_list (nonempty_list goal_ids));
      ("sandbox_profile", string_opt_json sandbox_profile);
      ("sandbox_root", string_opt_json sandbox_root);
      ("sandbox_roots", Json_util.json_string_list (nonempty_list sandbox_roots));
      ("path_resolution", path_resolution_contract_json);
      ("network_mode", string_opt_json network_mode);
      ("runtime_profile", string_opt_json runtime_profile);
    ]

let runtime_contract_json_from_fields ~keeper_name ?trace_id
    ?session_id ?generation ?keeper_turn_id ?task_id ?goal_ids
    ?sandbox_profile ?sandbox_root ?sandbox_roots ?network_mode
    ?runtime_profile () : Yojson.Safe.t =
  runtime_observability_contract_json_from_fields
    ~keeper_name
    ?trace_id
    ?session_id
    ?generation
    ?keeper_turn_id
    ?task_id
    ?goal_ids
    ?sandbox_profile
    ?sandbox_root
    ?sandbox_roots
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

(* Which input key the target came from, in the order they are tried. A file
   target and a working directory are both strings and were both reported as
   [target_kind "path"], so a consumer reading "path" as "a file" opened a
   directory instead: on 2026-08-18, 1,094 of the day's 1,323 Execute rows
   carried a directory that way, and the dashboard held Execute back from Code
   links by name to work around it (#29013, #29010). *)
type target_source =
  | File_target
  | Directory_target

let target_candidates =
  [ "target_path", File_target
  ; "path", File_target
  ; "file_path", File_target
  ; "repo_path", Directory_target
  ; "cwd", Directory_target
  ]
;;

let first_target_field input =
  List.find_map
    (fun (name, source) ->
       json_string_field name input |> Option.map (fun value -> value, source))
    target_candidates
;;

let target_kind_of_input input target =
  match json_string_field "target_kind" input with
  | Some value -> value
  | None -> (
      match json_string_field "kind" input with
      | Some value -> value
      | None -> (
          match target with
          | Some (_, File_target) -> "path"
          | Some (_, Directory_target) -> "directory"
          | None -> "tool"))

let action_radius_json ~tool_name ~input ~success ~duration_ms ?error
    ?sandbox_target () : Yojson.Safe.t =
  let action_key =
    first_string_field [ "action"; "action_key"; "op"; "cmd"; "command" ] input
    |> Option.value ~default:tool_name
  in
  let target = first_target_field input in
  `Assoc
    [
      ("tool_name", `String tool_name);
      ("action_key", `String action_key);
      ("target_kind", `String (target_kind_of_input input target));
      ("target_path", string_opt_json (Option.map fst target));
      ("sandbox_target", string_opt_json sandbox_target);
      ("observed_paths", Json_util.json_string_list (collect_observed_paths input));
      ("success", `Bool success);
      ("duration_ms", `Float duration_ms);
      ("error", string_opt_json error);
    ]

let runtime_contract_json ~(config : Workspace.config) (meta : keeper_meta) : Yojson.Safe.t =
  ignore config;
  `Assoc [ ("task_id", Json_util.string_opt_to_json (current_task_id_opt meta)) ]

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
