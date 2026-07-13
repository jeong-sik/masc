(** Keeper_tool_persona_runtime — persona-backed keeper argument resolution helpers. *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory

let persona_summary_to_json (persona : persona_summary) : Yojson.Safe.t =
  `Assoc
    [
      ("persona_name", `String persona.persona_name);
      ("display_name", `String persona.display_name);
      ("role", Json_util.string_opt_to_json persona.role);
      ("trait", Json_util.string_opt_to_json persona.trait);
      ("profile_path", `String persona.profile_path);
      ("has_keeper_defaults", `Bool persona.has_keeper_defaults);
    ]


let read_tail_lines_or_empty ~site path ~max_bytes ~max_lines =
  match read_file_tail_lines_result path ~max_bytes ~max_lines with
  | Ok lines -> lines
  | Error exn_class ->
      record_memory_recall_read_error ~site path exn_class;
      []

let read_jsonl_rows path ~max_bytes ~max_lines : Yojson.Safe.t list =
  if not (Fs_compat.file_exists path) then
    []
  else
    read_tail_lines_or_empty ~site:"persona_metrics" path ~max_bytes ~max_lines
    |> Fs_compat.parse_jsonl_lines ~source:"persona_metrics"
    |> fst

let find_jsonl_row_by_action_id rows action_id =
  rows
  |> List.find_map (fun json ->
         match Safe_ops.json_string_opt "action_id" json with
         | Some candidate when candidate = action_id -> Some json
         | _ -> None)

let resolved_keeper_args_to_json
    ~name ~persona_name ~goal
    ~instructions
    ~mention_targets
    ~allowed_paths_opt
    ~autoboot_enabled_opt
    ~proactive_enabled ~shards
    ~auto_handoff ~handoff_threshold ~handoff_cooldown_sec =
  let base =
    [
      ("name", `String name);
      ("persona_name", `String persona_name);
      ("goal", `String goal);
      ("instructions", `String instructions);
      ("mention_targets", Json_util.json_string_list mention_targets);
      ("proactive_enabled", `Bool proactive_enabled);
      ("auto_handoff", `Bool auto_handoff);
      ("handoff_threshold", `Float handoff_threshold);
      ("handoff_cooldown_sec", `Int handoff_cooldown_sec);
    ]
  in
  let allowed_paths_field =
    match allowed_paths_opt with
    | Some paths -> [("allowed_paths", Json_util.json_string_list paths)]
    | None -> []
  in
  let autoboot_field =
    match autoboot_enabled_opt with
    | Some value -> [ ("autoboot_enabled", `Bool value) ]
    | None -> []
  in
  let shards_field =
    match shards with
    | Some xs -> [("shards", Json_util.json_string_list xs)]
    | None -> []
  in
  `Assoc
    (base @ allowed_paths_field @ autoboot_field @ shards_field)

let validate_resolved_keeper_create_json (json : Yojson.Safe.t) : string list =
  let errors = ref [] in
  let name = Safe_ops.json_string ~default:"" "name" json in
  let goal = Safe_ops.json_string ~default:"" "goal" json |> String.trim in
  let mention_targets = Safe_ops.json_string_list "mention_targets" json in
  if not (validate_name name) then
    errors :=
      Printf.sprintf
        "invalid keeper name %S (must be non-empty and match \
         [A-Za-z0-9._-]+; see Keeper_config.validate_name)"
        name
      :: !errors;
  if goal = "" then errors := "goal is required" :: !errors;
  if mention_targets = [] then
    errors := "mention_targets is required" :: !errors;
  List.rev !errors

let toml_escape_string value =
  let buf = Buffer.create (String.length value + 8) in
  String.iter
    (function
      | '\\' -> Buffer.add_string buf "\\\\"
      | '"' -> Buffer.add_string buf "\\\""
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c -> Buffer.add_char buf c)
    value;
  Buffer.contents buf

let toml_string value = "\"" ^ toml_escape_string value ^ "\""

let toml_string_array values =
  values |> List.map toml_string |> String.concat ", " |> Printf.sprintf "[%s]"

let toml_float value =
  if Float.is_finite value then Ok (Printf.sprintf "%.17g" value)
  else Error "non-finite float cannot be persisted to keeper TOML"

let required_resolved_string key json =
  match Safe_ops.json_string_opt key json with
  | Some value when String.trim value <> "" -> Ok value
  | _ -> Error (Printf.sprintf "resolved_args.%s is required" key)

let optional_resolved_string key json =
  match Safe_ops.json_string_opt key json with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

let append_string_field acc key value =
  (Printf.sprintf "%s = %s" key (toml_string value)) :: acc

let append_optional_string_field acc key json =
  match optional_resolved_string key json with
  | Some value -> append_string_field acc key value
  | None -> acc

let append_bool_field acc key value =
  (Printf.sprintf "%s = %s" key (if value then "true" else "false")) :: acc

let append_optional_bool_field acc key json =
  match Safe_ops.json_bool_opt key json with
  | Some value -> append_bool_field acc key value
  | None -> acc

let append_int_field acc key value =
  (Printf.sprintf "%s = %d" key value) :: acc

let append_optional_int_field acc key json =
  match Safe_ops.json_int_opt key json with
  | Some value -> append_int_field acc key value
  | None -> acc

let append_string_list_field acc key values =
  (Printf.sprintf "%s = %s" key (toml_string_array values)) :: acc

let append_present_string_list_field acc key json =
  match Safe_ops.json_member_opt key json with
  | Some (`List _) ->
      append_string_list_field acc key (Safe_ops.json_string_list key json)
  | Some _ | None -> acc

let render_keeper_toml_from_resolved_args (json : Yojson.Safe.t) :
    (string, string) result =
  match required_resolved_string "name" json with
  | Error _ as err -> err
  | Ok name ->
      if not (validate_name name) then
        Error "resolved_args.name is not a valid keeper name"
      else
        match required_resolved_string "persona_name" json with
        | Error _ as err -> err
        | Ok persona_name ->
            if not (validate_name persona_name) then
              Error "resolved_args.persona_name is not a valid persona name"
            else
              let fields = [] in
              let fields = append_string_field fields "name" name in
              let fields = append_string_field fields "persona_name" persona_name in
              let fields = append_optional_string_field fields "goal" json in
              let fields = append_optional_string_field fields "instructions" json in
              let fields =
                append_optional_bool_field fields "autoboot_enabled" json
              in
              let fields =
                append_present_string_list_field fields "mention_targets" json
              in
              let fields =
                append_optional_bool_field fields "proactive_enabled" json
              in
              let fields = append_present_string_list_field fields "shards" json in
              let fields =
                append_present_string_list_field fields "allowed_paths" json
              in
              let fields =
                append_present_string_list_field fields "active_goal_ids" json
              in
              let timeout_fields =
                match Safe_ops.json_float_opt "per_provider_timeout" json with
                | None -> Ok fields
                | Some value -> (
                    match toml_float value with
                    | Error _ as err -> err
                    | Ok rendered ->
                        Ok
                          ((Printf.sprintf "per_provider_timeout = %s" rendered)
                           :: fields))
              in
              Result.map
                (fun fields ->
                  String.concat "\n"
                    ([
                       "# Generated by masc_keeper_create_from_persona.";
                       "[keeper]";
                     ]
                     @ List.rev fields)
                  ^ "\n")
                timeout_fields

let persist_keeper_toml_from_resolved_args (json : Yojson.Safe.t) :
    (Yojson.Safe.t, string) result =
  match required_resolved_string "name" json with
  | Error _ as err -> err
  | Ok name ->
      if not (validate_name name) then
        Error "resolved_args.name is not a valid keeper name"
      else
        let path =
          Filename.concat (Config_dir_resolver.keepers_dir ()) (name ^ ".toml")
        in
        match Config_dir_resolver.keeper_toml_path_opt name with
        | Some existing_path ->
            Ok
              (`Assoc
                [
                  ("path", `String existing_path);
                  ("created", `Bool false);
                  ("reason", `String "already_exists");
                ])
        | None -> (
            match render_keeper_toml_from_resolved_args json with
            | Error _ as err -> err
            | Ok content -> (
                Fs_compat.mkdir_p (Filename.dirname path);
                match Fs_compat.save_file_atomic path content with
                | Error msg -> Error msg
                | Ok () ->
                    Ok
                      (`Assoc
                        [
                          ("path", `String path);
                          ("created", `Bool true);
                        ])))

let resolved_keeper_args_from_persona args :
    ((persona_summary * Yojson.Safe.t), string) result =
  let persona_name = get_string args "persona_name" "" |> String.trim in
  if not (validate_name persona_name) then
    Error "persona_name is required"
  else
    match Keeper_meta_contract.reject_removed_model_args ~tool_name:"masc_keeper_create_from_persona" args with
    | Error err -> Error err
    | Ok () ->
    match reject_removed_keeper_input_keys
            ~tool_name:"masc_keeper_create_from_persona" args with
    | Error err -> Error err
    | Ok () ->
    match load_persona_summary persona_name with
    | None ->
        Error
          (Printf.sprintf
             "persona not found or missing profile.json: %s"
             persona_name)
    | Some persona ->
      (match load_keeper_profile_defaults_result persona_name with
       | Error error -> Error (keeper_toml_load_error_to_string error)
       | Ok defaults ->
        let defaults_source =
          Option.value defaults.manifest_path ~default:persona.profile_path
        in
        (match persona_operator_todo_placeholder_fields persona defaults with
        | _ :: _ as fields ->
            Error
              (Printf.sprintf
                 "keeper defaults at %s contain OPERATOR_TODO placeholder(s): %s; \
                  replace placeholders before masc_keeper_create_from_persona"
                 defaults_source
                 (String.concat ", " fields))
        | [] ->
        let name =
          get_string_opt args "name" |> Option.value ~default:persona_name
        in
        let goal =
          get_string_opt args "goal"
          |> Dashboard_utils.first_some defaults.goal
          |> Option.value ~default:""
          |> normalize_goal_text
        in
        let instructions =
          get_string_opt args "instructions"
          |> Dashboard_utils.first_some defaults.instructions
          |> Option.value ~default:""
        in
            let mention_targets =
              let explicit = get_string_list args "mention_targets" in
              let raw =
                if explicit <> [] then explicit
                else if defaults.mention_targets <> [] then defaults.mention_targets
                else [ persona_name ]
              in
              raw
              |> List.filter (fun value -> String.trim value <> "")
              |> dedupe_keep_order
            in
            let proactive_enabled =
              get_bool_opt args "proactive_enabled"
              |> Dashboard_utils.first_some defaults.proactive_enabled
              |> Option.value ~default:false
            in
            let autoboot_enabled = get_bool_opt args "autoboot_enabled" in
            (match Keeper_turn_up_args.parse_present_string_list_opt args "allowed_paths" with
            | Error err -> Error err
            | Ok allowed_paths_opt ->
                 let allowed_paths =
                   match allowed_paths_opt with
                   | Some _ as paths -> paths
                   | None -> defaults.allowed_paths
                 in
                 let shards =
                   match get_string_list args "shards" with
                   | _ :: _ as xs -> Some xs
                   | [] -> defaults.shards
                 in
                 let auto_handoff = get_bool args "auto_handoff" true in
                 let handoff_threshold =
                   Safe_ops.json_float_opt "handoff_threshold" args
                   |> Option.value ~default:0.85
                 in
                 let handoff_cooldown_sec =
                   Safe_ops.json_int_opt "handoff_cooldown_sec" args
                   |> Option.value ~default:300
                 in
                 let resolved =
                   resolved_keeper_args_to_json
                     ~name
                     ~persona_name
                     ~goal
                     ~instructions
                     ~mention_targets
                     ~allowed_paths_opt:allowed_paths
                     ~autoboot_enabled_opt:autoboot_enabled
                     ~proactive_enabled ~shards
                     ~auto_handoff ~handoff_threshold
                     ~handoff_cooldown_sec
                 in
                 (match json_operator_todo_placeholder_paths resolved with
                  | _ :: _ as fields ->
                    Error
                      (Printf.sprintf
                         "resolved keeper args from %s contain OPERATOR_TODO \
                          placeholder(s): %s; replace placeholders before \
                          masc_keeper_create_from_persona"
                         defaults_source
                         (String.concat ", " fields))
                  | [] -> Ok (persona, resolved)))))
