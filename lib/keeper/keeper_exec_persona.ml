(** Keeper_exec_persona — persona-backed keeper argument resolution helpers. *)

open Tool_args
open Keeper_types
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

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)

let read_jsonl_rows path ~max_bytes ~max_lines : Yojson.Safe.t list =
  if not (Fs_compat.file_exists path) then
    []
  else
    read_file_tail_lines path ~max_bytes ~max_lines
    |> Fs_compat.parse_jsonl_lines ~source:"persona_metrics"
    |> fst

let find_jsonl_row_by_action_id rows action_id =
  rows
  |> List.find_map (fun json ->
         match Safe_ops.json_string_opt "action_id" json with
         | Some candidate when candidate = action_id -> Some json
         | _ -> None)

let resolved_keeper_args_to_json
    ~name ~persona_name ~goal ~short_goal ~mid_goal ~long_goal
    ~instructions ~will ~needs ~desires ~policy_voice_enabled
    ~mention_targets
    ~allowed_paths_opt
    ~autoboot_enabled_opt
    ~tool_access_opt
    ~tool_preset ~tool_also_allow ~tool_denylist
    ~proactive_enabled ~shards
    ~auto_handoff ~handoff_threshold ~handoff_cooldown_sec =
  let base =
    [
      ("name", `String name);
      ("persona_name", `String persona_name);
      ("goal", `String goal);
      ("short_goal", `String short_goal);
      ("mid_goal", `String mid_goal);
      ("long_goal", `String long_goal);
      ("instructions", `String instructions);
      ("will", `String will);
      ("needs", `String needs);
      ("desires", `String desires);
      ("policy_voice_enabled", `Bool policy_voice_enabled);
      ("mention_targets", string_list_to_json mention_targets);
      ("tool_denylist", string_list_to_json tool_denylist);
      ("proactive_enabled", `Bool proactive_enabled);
      ("auto_handoff", `Bool auto_handoff);
      ("handoff_threshold", `Float handoff_threshold);
      ("handoff_cooldown_sec", `Int handoff_cooldown_sec);
    ]
  in
  let allowed_paths_field =
    match allowed_paths_opt with
    | Some paths -> [("allowed_paths", string_list_to_json paths)]
    | None -> []
  in
  let autoboot_field =
    match autoboot_enabled_opt with
    | Some value -> [ ("autoboot_enabled", `Bool value) ]
    | None -> []
  in
  let tool_policy_field =
    match tool_access_opt with
    | Some tool_access -> [("tool_access", tool_access_to_json tool_access)]
    | None ->
        [
          ("tool_preset", `String (tool_preset_to_string tool_preset));
          ("tool_also_allow", string_list_to_json tool_also_allow);
        ]
  in
  let shards_field =
    match shards with
    | Some xs -> [("shards", string_list_to_json xs)]
    | None -> []
  in
  `Assoc
    ( base @ allowed_paths_field @ autoboot_field
    @ tool_policy_field @ shards_field )

let validate_resolved_keeper_create_json (json : Yojson.Safe.t) : string list =
  let errors = ref [] in
  let name = Safe_ops.json_string ~default:"" "name" json in
  let goal = Safe_ops.json_string ~default:"" "goal" json |> String.trim in
  let _policy_voice_enabled =
    Safe_ops.json_bool ~default:false "policy_voice_enabled" json
  in
  let mention_targets = Safe_ops.json_string_list "mention_targets" json in
  if not (validate_name name) then errors := "invalid keeper name" :: !errors;
  if goal = "" then errors := "goal is required" :: !errors;
  if mention_targets = [] then
    errors := "mention_targets is required" :: !errors;
  List.rev !errors

let resolved_keeper_args_from_persona args :
    ((persona_summary * Yojson.Safe.t), string) result =
  let persona_name = get_string args "persona_name" "" |> String.trim in
  if not (validate_name persona_name) then
    Error "persona_name is required"
  else
    match reject_legacy_model_args ~tool_name:"masc_keeper_create_from_persona" args with
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
        let defaults = load_keeper_profile_defaults persona_name in
        let name =
          get_string_opt args "name" |> Option.value ~default:persona_name
        in
        let goal =
          get_string_opt args "goal"
          |> first_some defaults.goal
          |> Option.value ~default:""
          |> normalize_goal_horizon_text
        in
        let short_goal =
          parse_goal_horizon_opt args "short_goal"
          |> first_some defaults.short_goal
          |> Option.value ~default:goal
          |> normalize_goal_horizon_text
        in
        let mid_goal =
          parse_goal_horizon_opt args "mid_goal"
          |> first_some defaults.mid_goal
          |> Option.value ~default:goal
          |> normalize_goal_horizon_text
        in
        let long_goal =
          parse_goal_horizon_opt args "long_goal"
          |> first_some defaults.long_goal
          |> Option.value ~default:goal
          |> normalize_goal_horizon_text
        in
        let instructions =
          get_string_opt args "instructions"
          |> first_some defaults.instructions
          |> Option.value ~default:""
        in
        let will =
          parse_self_model_opt args "will"
          |> first_some defaults.will
          |> Option.value ~default:(Env_config_core.keeper_will ())
        in
        let needs =
          parse_self_model_opt args "needs"
          |> first_some defaults.needs
          |> Option.value ~default:(Env_config_core.keeper_needs ())
        in
        let desires =
          parse_self_model_opt args "desires"
          |> first_some defaults.desires
          |> Option.value ~default:(Env_config_core.keeper_desires ())
        in
            let policy_voice_enabled =
              first_some
                (get_bool_opt args "policy_voice_enabled")
              defaults.policy_voice_enabled
              |> Option.value ~default:false
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
              |> first_some defaults.proactive_enabled
              |> Option.value ~default:false
            in
            let autoboot_enabled = get_bool_opt args "autoboot_enabled" in
            (match
               Keeper_turn_up_args.parse_tool_access_input args,
               Keeper_turn_up_args.parse_present_string_list_opt args "allowed_paths"
             with
            | Error err, _ | _, Error err -> Error err
            | Ok (tool_access_opt, tool_preset_opt, tool_also_allow_opt), Ok allowed_paths_opt ->
                 (* #8605 family: warn-and-default via shared helper
                    [Keeper_preset_defaults.preset_of_defaults_warn].
                    Lifted from this file + keeper_turn_up_create to a
                    single SSOT (#8923) so a future third preset-source
                    path cannot diverge. *)
                 let tool_preset =
                   match tool_preset_opt with
                   | Some preset -> preset
                   | None -> (
                       match tool_access_opt with
                       | Some _ -> Research
                       | None ->
                           Keeper_preset_defaults.preset_of_defaults_warn
                             ~call_site:"keeper_exec_persona"
                             ~defaults_tool_preset:defaults.tool_preset
                           |> Option.value ~default:Research)
                 in
                 let tool_also_allow =
                   match tool_also_allow_opt with
                   | Some xs -> xs
                   | None -> Option.value ~default:[] defaults.tool_also_allow
                 in
                 let tool_denylist =
                   match get_string_list args "tool_denylist" with
                   | _ :: _ as xs -> xs
                   | [] -> Option.value ~default:[] defaults.tool_denylist
                 in
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
                     ~goal ~short_goal ~mid_goal ~long_goal
                     ~instructions  ~will ~needs ~desires
                     ~policy_voice_enabled
                     ~mention_targets
                     ~allowed_paths_opt:allowed_paths
                     ~autoboot_enabled_opt:autoboot_enabled
                     ~tool_access_opt
                     ~tool_preset ~tool_also_allow ~tool_denylist
                     ~proactive_enabled ~shards
                     ~auto_handoff ~handoff_threshold
                     ~handoff_cooldown_sec
                 in
                 Ok (persona, resolved))
