(** Keeper_exec_persona — persona-backed keeper argument resolution helpers. *)

open Tool_args
open Keeper_types
open Keeper_memory

let persona_summary_to_json (persona : persona_summary) : Yojson.Safe.t =
  `Assoc
    [
      ("persona_name", `String persona.persona_name);
      ("display_name", `String persona.display_name);
      ("role", match persona.role with Some value -> `String value | None -> `Null);
      ("trait", match persona.trait with Some value -> `String value | None -> `Null);
      ("profile_path", `String persona.profile_path);
      ("has_keeper_defaults", `Bool persona.has_keeper_defaults);
    ]

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)

let read_jsonl_rows path ~max_bytes ~max_lines : Yojson.Safe.t list =
  if not (Sys.file_exists path) then
    []
  else
    read_file_tail_lines path ~max_bytes ~max_lines
    |> List.filter_map (fun line ->
           try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)

let find_jsonl_row_by_action_id rows action_id =
  rows
  |> List.find_map (fun json ->
         match Safe_ops.json_string_opt "action_id" json with
         | Some candidate when candidate = action_id -> Some json
         | _ -> None)

let resolved_keeper_args_to_json
    ~name ~persona_name ~persona_profile_path ~goal ~short_goal ~mid_goal ~long_goal
    ~instructions ~soul_profile ~will ~needs ~desires ~models ~allowed_models
    ~active_model ~policy_mode
    ~policy_voice_enabled ~policy_shell_mode
    ~room_scope ~scope_kind ~trigger_mode ~mention_targets
    ~presence_keepalive ~presence_keepalive_sec ~proactive_enabled
    ~auto_handoff ~handoff_threshold ~handoff_cooldown_sec =
  `Assoc
    [
      ("name", `String name);
      ("persona_name", `String persona_name);
      ("persona_profile_path", `String persona_profile_path);
      ("goal", `String goal);
      ("short_goal", `String short_goal);
      ("mid_goal", `String mid_goal);
      ("long_goal", `String long_goal);
      ("instructions", `String instructions);
      ("soul_profile", `String soul_profile);
      ("will", `String will);
      ("needs", `String needs);
      ("desires", `String desires);
      ("models", string_list_to_json models);
      ("allowed_models", string_list_to_json allowed_models);
      ("active_model", `String active_model);
      ("policy_mode", `String policy_mode);
      ("policy_voice_enabled", `Bool policy_voice_enabled);
      ("policy_shell_mode", `String policy_shell_mode);
      ("room_scope", `String room_scope);
      ("scope_kind", `String scope_kind);
      ("trigger_mode", `String trigger_mode);
      ("mention_targets", string_list_to_json mention_targets);
      ("presence_keepalive", `Bool presence_keepalive);
      ("presence_keepalive_sec", `Int presence_keepalive_sec);
      ("proactive_enabled", `Bool proactive_enabled);
      ("auto_handoff", `Bool auto_handoff);
      ("handoff_threshold", `Float handoff_threshold);
      ("handoff_cooldown_sec", `Int handoff_cooldown_sec);
    ]

let validate_resolved_keeper_create_json (json : Yojson.Safe.t) : string list =
  let errors = ref [] in
  let name = Safe_ops.json_string ~default:"" "name" json in
  let goal = Safe_ops.json_string ~default:"" "goal" json |> String.trim in
  let models = Safe_ops.json_string_list "models" json in
  let allowed_models = Safe_ops.json_string_list "allowed_models" json in
  let active_model =
    Safe_ops.json_string ~default:"" "active_model" json |> String.trim
  in
  let policy_mode =
    Safe_ops.json_string ~default:"heuristic" "policy_mode" json
    |> canonical_policy_mode
  in
  let policy_voice_enabled =
    Safe_ops.json_bool ~default:false "policy_voice_enabled" json
  in
  let policy_shell_mode =
    Safe_ops.json_string ~default:"disabled" "policy_shell_mode" json
    |> canonical_policy_shell_mode
  in
  let _initiative_enabled =
    Safe_ops.json_bool ~default:false "initiative_enabled" json
  in
  let mention_targets = Safe_ops.json_string_list "mention_targets" json in
  if not (validate_name name) then errors := "invalid keeper name" :: !errors;
  if goal = "" then errors := "goal is required" :: !errors;
  if models = [] then errors := "models is required" :: !errors;
  if active_model <> "" && not (List.mem active_model (allowed_models @ models)) then
    errors := "active_model must be included in models or allowed_models" :: !errors;
  if policy_voice_enabled && policy_mode <> "learned_offline_v1" then
    errors := "policy_voice_enabled=true requires learned_offline_v1" :: !errors;
  if policy_shell_mode = "readonly" && policy_mode <> "learned_offline_v1" then
    errors := "policy_shell_mode=readonly requires learned_offline_v1" :: !errors;
  if
    (Safe_ops.json_string ~default:"legacy" "trigger_mode" json
     |> Keeper_contract.trigger_mode_of_string
     |> Keeper_contract.trigger_mode_is_explicit_only)
    && mention_targets = []
  then errors := "mention_targets is required for explicit_only trigger_mode" :: !errors;
  List.rev !errors

let resolved_keeper_args_from_persona args :
    ((persona_summary * Yojson.Safe.t), string) result =
  let persona_name = get_string args "persona_name" "" |> String.trim in
  let soul_profile_opt_res = parse_soul_profile_opt args "soul_profile" in
  match soul_profile_opt_res with
  | Error err -> Error err
  | Ok soul_profile_opt ->
      if not (validate_name persona_name) then
        Error "persona_name is required"
      else
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
            let soul_profile =
              soul_profile_opt
              |> first_some defaults.soul_profile
              |> Option.value ~default:default_soul_profile
            in
            let will =
              parse_self_model_opt args "will"
              |> first_some defaults.will
              |> Option.value ~default:default_keeper_will
            in
            let needs =
              parse_self_model_opt args "needs"
              |> first_some defaults.needs
              |> Option.value ~default:default_keeper_needs
            in
            let desires =
              parse_self_model_opt args "desires"
              |> first_some defaults.desires
              |> Option.value ~default:default_keeper_desires
            in
            let explicit_models = get_string_list args "models" in
            let explicit_allowed_models = get_string_list args "allowed_models" in
            let active_model_opt = get_string_opt args "active_model" in
            let base_models =
              if explicit_models <> [] then explicit_models
              else if defaults.models <> [] then defaults.models
              else
                match active_model_opt |> first_some defaults.active_model with
                | Some model -> [ model ]
                | None -> []
            in
            let allowed_models =
              resolve_allowed_models
                ~explicit_allowed_models
                ~seed_allowed_models:defaults.allowed_models
                ~models:base_models
            in
            let active_model =
              active_model_opt
              |> first_some defaults.active_model
              |> Option.value
                   ~default:
                     (match base_models with
                     | model :: _ -> model
                     | [] -> "")
            in
            let policy_mode =
              first_some (get_string_opt args "policy_mode") defaults.policy_mode
              |> Option.value ~default:"heuristic"
              |> canonical_policy_mode
            in
            let policy_voice_enabled =
              first_some
                (get_bool_opt args "policy_voice_enabled")
                defaults.policy_voice_enabled
              |> Option.value ~default:false
            in
            let policy_shell_mode =
              first_some
                (get_string_opt args "policy_shell_mode")
                defaults.policy_shell_mode
              |> Option.value ~default:"disabled"
              |> canonical_policy_shell_mode
            in
            let room_scope =
              get_string_opt args "room_scope"
              |> first_some defaults.room_scope
              |> Option.value ~default:"current"
              |> canonical_room_scope
            in
            let scope_kind =
              get_string_opt args "scope_kind"
              |> first_some defaults.scope_kind
              |> Option.value
                   ~default:(if room_scope = "all" then "global" else "local")
              |> canonical_scope_kind
            in
            let trigger_mode =
              get_string_opt args "trigger_mode"
              |> first_some defaults.trigger_mode
              |> Option.value ~default:"legacy"
              |> canonical_trigger_mode
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
            let presence_keepalive =
              get_bool_opt args "presence_keepalive"
              |> first_some defaults.presence_keepalive
              |> Option.value ~default:true
            in
            let presence_keepalive_sec =
              Safe_ops.json_int_opt "presence_keepalive_sec" args
              |> first_some defaults.presence_keepalive_sec
              |> Option.value ~default:30
            in
            let proactive_enabled =
              get_bool_opt args "proactive_enabled"
              |> first_some defaults.proactive_enabled
              |> Option.value
                   ~default:
                     (if trigger_mode = "explicit_only" then false
                      else default_proactive_enabled)
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
                ~persona_profile_path:persona.profile_path
                ~goal ~short_goal ~mid_goal ~long_goal
                ~instructions ~soul_profile ~will ~needs ~desires
                ~models:base_models ~allowed_models ~active_model
                ~policy_mode
                ~policy_voice_enabled ~policy_shell_mode
                ~room_scope ~scope_kind ~trigger_mode ~mention_targets
                ~presence_keepalive ~presence_keepalive_sec ~proactive_enabled
                ~auto_handoff ~handoff_threshold
                ~handoff_cooldown_sec
            in
            Ok (persona, resolved)
