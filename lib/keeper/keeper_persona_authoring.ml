(** Persona authoring tools.

    The existing persona loader is the source of truth for how profile.json
    turns into keeper defaults. This module exposes that shape explicitly and
    keeps writes constrained to the resolved personas root. *)

open Tool_args
module Archetypes = Keeper_persona_authoring_contract

type save_result =
  { handle : string
  ; personas_root : string
  ; profile_path : string
  ; profile : Yojson.Safe.t
  ; warnings : string list
  }

type archetype_axes =
  { alignment : string option
  ; operating_style : string option
  ; risk_posture : string option
  }

let string_list_to_json = Archetypes.string_list_to_json
let option_field = Archetypes.option_field

let assoc_without key fields =
  List.filter (fun (candidate, _) -> not (String.equal candidate key)) fields
;;

let assoc_set key value fields = (key, value) :: assoc_without key fields

let assoc_get key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let assoc_keys = function
  | `Assoc fields -> List.map fst fields
  | _ -> []
;;

let trim_nonempty_opt = function
  | Some raw ->
    let value = String.trim raw in
    if value = "" then None else Some value
  | None -> None
;;

let json_trimmed_string_opt key json =
  Safe_ops.json_string_opt key json |> trim_nonempty_opt
;;

let json_string_list_normalized key json =
  Safe_ops.json_string_list key json |> Keeper_types_profile.normalize_name_list
;;

let allowed_keeper_fields =
  [ "goal"
  ; "short_goal"
  ; "mid_goal"
  ; "long_goal"
  ; "will"
  ; "needs"
  ; "desires"
  ; "instructions"
  ; "policy_voice_enabled"
  ; "mention_targets"
  ; "proactive_enabled"
  ; "proactive_idle_sec"
  ; "proactive_cooldown_sec"
  ; "room_signal_prompt_enabled"
  ; "shards"
  ; "tool_preset"
  ; "tool_also_allow"
  ; "tool_denylist"
  ; "work_discovery_enabled"
  ; "work_discovery_sources"
  ; "work_discovery_interval_sec"
  ; "work_discovery_guidance"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "per_provider_timeout"
  ; "always_approve"
  ; "max_turns_per_call"
  ; "max_turns_per_call_scheduled_autonomous"
  ; "social_model"
  ; "cascade_name"
  ]
;;

let field_catalog_entry ?default ?choices ?(required = false) ~path ~typ ~field_effect () =
  `Assoc
    ([ "path", `String path
     ; "type", `String typ
     ; "required", `Bool required
     ; "effect", `String field_effect
     ]
     @ option_field "default" default
     @ option_field "choices" choices)
;;

let tool_preset_choices_json =
  string_list_to_json Keeper_types_profile.valid_tool_preset_raw_strings
;;

let social_model_choices_json =
  string_list_to_json Keeper_types_profile.valid_social_model_strings
;;

let alignment_choices = Archetypes.alignment_choices
let operating_style_choices = Archetypes.operating_style_choices
let risk_posture_choices = Archetypes.risk_posture_choices
let alignment_choice_effects = Archetypes.alignment_choice_effects
let operating_style_choice_effects = Archetypes.operating_style_choice_effects
let risk_posture_choice_effects = Archetypes.risk_posture_choice_effects
let choice_effect_fields = Archetypes.choice_effect_fields
let choice_effect_for = Archetypes.choice_effect_for
let archetype_axes_json = Archetypes.archetype_axes_json

let field_catalog_json () =
  `List
    [ field_catalog_entry
        ~path:"name"
        ~typ:"string"
        ~default:(`String "<handle>")
        ~field_effect:
          "Display label in persona lists. It does not change keeper execution by itself."
        ()
    ; field_catalog_entry
        ~path:"role"
        ~typ:"string"
        ~field_effect:"Human-readable role metadata shown in discovery surfaces."
        ()
    ; field_catalog_entry
        ~path:"trait"
        ~typ:"string"
        ~field_effect:
          "Short personality or operating-style metadata shown in discovery surfaces."
        ()
    ; field_catalog_entry
        ~path:"keeper.goal"
        ~typ:"string"
        ~required:true
        ~field_effect:
          "Required keeper purpose. masc_keeper_create_from_persona refuses \
           materialization when this is empty."
        ()
    ; field_catalog_entry
        ~path:"keeper.short_goal"
        ~typ:"string"
        ~default:(`String "<keeper.goal>")
        ~field_effect:"Near-term goal horizon used when the keeper is created."
        ()
    ; field_catalog_entry
        ~path:"keeper.mid_goal"
        ~typ:"string"
        ~default:(`String "<keeper.goal>")
        ~field_effect:"Medium-term goal horizon used when the keeper is created."
        ()
    ; field_catalog_entry
        ~path:"keeper.long_goal"
        ~typ:"string"
        ~default:(`String "<keeper.goal>")
        ~field_effect:"Long-term goal horizon used when the keeper is created."
        ()
    ; field_catalog_entry
        ~path:"keeper.instructions"
        ~typ:"string"
        ~field_effect:"Additional instructions copied into the keeper creation args."
        ()
    ; field_catalog_entry
        ~path:"keeper.will"
        ~typ:"string"
        ~field_effect:
          "Self-model will statement. Overrides the keeper environment default."
        ()
    ; field_catalog_entry
        ~path:"keeper.needs"
        ~typ:"string"
        ~field_effect:
          "Self-model needs statement. Overrides the keeper environment default."
        ()
    ; field_catalog_entry
        ~path:"keeper.desires"
        ~typ:"string"
        ~field_effect:
          "Self-model desires statement. Overrides the keeper environment default."
        ()
    ; field_catalog_entry
        ~path:"keeper.mention_targets"
        ~typ:"string[]"
        ~default:(`String "[<handle>]")
        ~field_effect:"Names that wake or target this persona-backed keeper."
        ()
    ; field_catalog_entry
        ~path:"keeper.tool_preset"
        ~typ:"enum"
        ~default:(`String Archetypes.default_tool_preset)
        ~choices:tool_preset_choices_json
        ~field_effect:"Preset used to derive the keeper tool policy during creation."
        ()
    ; field_catalog_entry
        ~path:"keeper.tool_also_allow"
        ~typ:"string[]"
        ~field_effect:"Extra tools added on top of keeper.tool_preset."
        ()
    ; field_catalog_entry
        ~path:"keeper.tool_denylist"
        ~typ:"string[]"
        ~field_effect:"Tools removed from the derived keeper tool policy."
        ()
    ; field_catalog_entry
        ~path:"keeper.proactive_enabled"
        ~typ:"boolean"
        ~default:(`Bool false)
        ~field_effect:"Whether the created keeper should run proactive turns."
        ()
    ; field_catalog_entry
        ~path:"keeper.proactive_idle_sec"
        ~typ:"integer"
        ~field_effect:"Idle delay before proactive work becomes eligible."
        ()
    ; field_catalog_entry
        ~path:"keeper.proactive_cooldown_sec"
        ~typ:"integer"
        ~field_effect:"Cooldown between proactive turns."
        ()
    ; field_catalog_entry
        ~path:"keeper.room_signal_prompt_enabled"
        ~typ:"boolean"
        ~field_effect:"Whether room signal context is injected into keeper prompts."
        ()
    ; field_catalog_entry
        ~path:"keeper.shards"
        ~typ:"string[]"
        ~field_effect:"Persona-specific prompt shards applied after keeper creation."
        ()
    ; field_catalog_entry
        ~path:"keeper.work_discovery_enabled"
        ~typ:"boolean"
        ~field_effect:"Enables config-driven proactive work scanning for the keeper."
        ()
    ; field_catalog_entry
        ~path:"keeper.work_discovery_sources"
        ~typ:"string[]"
        ~field_effect:"Named work discovery sources considered by proactive scanning."
        ()
    ; field_catalog_entry
        ~path:"keeper.work_discovery_interval_sec"
        ~typ:"integer"
        ~field_effect:"Interval for proactive work discovery checks."
        ()
    ; field_catalog_entry
        ~path:"keeper.work_discovery_guidance"
        ~typ:"string"
        ~field_effect:"Additional guidance used during proactive work discovery."
        ()
    ; field_catalog_entry
        ~path:"keeper.telemetry_feedback_enabled"
        ~typ:"boolean"
        ~field_effect:"Injects recent keeper telemetry into future turns."
        ()
    ; field_catalog_entry
        ~path:"keeper.telemetry_feedback_window_hours"
        ~typ:"integer"
        ~field_effect:"Lookback window for telemetry feedback."
        ()
    ; field_catalog_entry
        ~path:"keeper.per_provider_timeout"
        ~typ:"number"
        ~field_effect:"Per-provider cascade timeout override for this keeper."
        ()
    ; field_catalog_entry
        ~path:"keeper.always_approve"
        ~typ:"boolean"
        ~field_effect:
          "Allows eligible keeper actions to auto-approve according to runtime policy."
        ()
    ; field_catalog_entry
        ~path:"keeper.max_turns_per_call"
        ~typ:"integer"
        ~field_effect:"Turn budget for direct keeper calls."
        ()
    ; field_catalog_entry
        ~path:"keeper.max_turns_per_call_scheduled_autonomous"
        ~typ:"integer"
        ~field_effect:"Turn budget for scheduled autonomous turns."
        ()
    ; field_catalog_entry
        ~path:"keeper.social_model"
        ~typ:"enum"
        ~choices:social_model_choices_json
        ~field_effect:"Optional social-model runtime for speech or ledger behavior."
        ()
    ; field_catalog_entry
        ~path:"keeper.cascade_name"
        ~typ:"string"
        ~field_effect:
          "Optional named cascade override. Must resolve to a known cascade at runtime."
        ()
    ]
;;

let personas_root_candidate () =
  let resolution = Config_dir_resolver.resolve () in
  resolution.personas.path
;;

let persona_profile_path ~root ~handle =
  Filename.concat (Filename.concat root handle) "profile.json"
;;

let schema_json ?(include_examples = false) () =
  let root = personas_root_candidate () in
  let examples =
    if not include_examples
    then []
    else
      [ ( "examples"
        , `Assoc
            [ ( "minimal_profile"
              , `Assoc
                  [ "name", `String "Sharp Researcher"
                  ; "role", `String "skeptical research keeper"
                  ; "trait", `String "concise, evidence-first, mildly chaotic"
                  ; ( "keeper"
                    , `Assoc
                        [ ( "goal"
                          , `String
                              "Find weak assumptions and turn them into actionable tasks."
                          )
                        ; "tool_preset", `String Archetypes.default_tool_preset
                        ; "mention_targets", string_list_to_json [ "sharp-researcher" ]
                        ] )
                  ] )
            ] )
      ]
  in
  `Assoc
    ([ "personas_root", `String root
     ; ( "profile_path_pattern"
       , `String (Filename.concat (Filename.concat root "<handle>") "profile.json") )
     ; ( "handle_rules"
       , `String
           "Non-empty [A-Za-z0-9._-]+. The handle is the directory name and the default \
            keeper name." )
     ; "field_catalog", field_catalog_json ()
     ; ( "choice_sets"
       , `Assoc
           [ "tool_preset", tool_preset_choices_json
           ; "social_model", social_model_choices_json
           ; ( "proactive_enabled"
             , `Assoc
                 [ "false", `String "Keeper stays passive unless called."
                 ; "true", `String "Keeper may run proactive scheduled turns."
                 ] )
           ] )
     ; "archetype_axes", archetype_axes_json ()
     ; ( "authoring_flow"
       , `Assoc
           [ "draft_tool", `String "masc_persona_generate"
           ; "save_tool", `String "masc_persona_save"
           ; "dry_run_keeper_tool", `String "masc_keeper_create_from_persona"
           ; "start_keeper_tool", `String "masc_keeper_create_from_persona"
           ; ( "draft_args"
             , `Assoc
                 [ "concept", `String "<natural-language persona concept>"
                 ; "alignment", `String "<optional archetype axis>"
                 ; "operating_style", `String "<optional archetype axis>"
                 ; "risk_posture", `String "<optional archetype axis>"
                 ; "tool_preset", `String "<optional preset>"
                 ] )
           ; ( "save_args"
             , `Assoc
                 [ "handle", `String "<handle>"
                 ; "profile", `String "<profile JSON from draft or hand-authored>"
                 ; "dry_run", `Bool true
                 ] )
           ; ( "keeper_dry_run_args"
             , `Assoc [ "persona_name", `String "<handle>"; "dry_run", `Bool true ] )
           ] )
     ; ( "keeperization"
       , `Assoc
           [ "dry_run_tool", `String "masc_keeper_create_from_persona"
           ; "start_tool", `String "masc_keeper_create_from_persona"
           ; ( "dry_run_args"
             , `Assoc [ "persona_name", `String "<handle>"; "dry_run", `Bool true ] )
           ] )
     ]
     @ examples)
;;

let handle_persona_schema _ctx args =
  let include_examples = get_bool args "include_examples" false in
  true, Yojson.Safe.to_string (schema_json ~include_examples ())
;;

let validate_unknown_keeper_fields keeper_json =
  assoc_keys keeper_json
  |> List.filter (fun key -> not (List.mem key allowed_keeper_fields))
;;

let normalize_tool_preset raw =
  match Keeper_types_profile.normalize_tool_preset_raw raw with
  | Some value -> Ok value
  | None ->
    Error
      (Printf.sprintf
         "invalid keeper.tool_preset '%s' (allowed: %s)"
         raw
         (String.concat ", " Keeper_types_profile.valid_tool_preset_raw_strings))
;;

let normalize_social_model raw =
  match Keeper_types_profile.normalize_social_model_opt (Some raw) with
  | Some value -> Ok value
  | None ->
    Error
      (Printf.sprintf
         "invalid keeper.social_model '%s' (allowed: %s)"
         raw
         (String.concat ", " Keeper_types_profile.valid_social_model_strings))
;;

let normalize_cascade_name raw =
  let normalized = Keeper_cascade_profile.normalize_declared_name raw in
  let catalog =
    try Keeper_cascade_profile.catalog_names () with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> []
  in
  let known =
    Keeper_cascade_profile.known_cascades
    @ Keeper_config.phase_routing_cascade_names
    @ catalog
  in
  if List.mem (String.lowercase_ascii normalized) known
  then Ok normalized
  else
    Error
      (Printf.sprintf
         "invalid keeper.cascade_name '%s' (known: %s)"
         raw
         (String.concat ", " known))
;;

let add_optional_string key fields keeper_json =
  match json_trimmed_string_opt key keeper_json with
  | Some value -> assoc_set key (`String value) fields
  | None -> assoc_without key fields
;;

let add_optional_bool key fields keeper_json =
  match Safe_ops.json_bool_opt key keeper_json with
  | Some value -> assoc_set key (`Bool value) fields
  | None -> assoc_without key fields
;;

let add_optional_int key fields keeper_json =
  match Safe_ops.json_int_opt key keeper_json with
  | Some value -> assoc_set key (`Int value) fields
  | None -> assoc_without key fields
;;

let add_optional_float key fields keeper_json =
  match Safe_ops.json_float_opt key keeper_json with
  | Some value -> assoc_set key (`Float value) fields
  | None -> assoc_without key fields
;;

let add_optional_string_list key fields keeper_json =
  match json_string_list_normalized key keeper_json with
  | [] -> assoc_without key fields
  | values -> assoc_set key (string_list_to_json values) fields
;;

let normalize_keeper_json ~handle keeper_json =
  match keeper_json with
  | `Assoc _ ->
    let unknown = validate_unknown_keeper_fields keeper_json in
    if unknown <> []
    then
      Error
        (Printf.sprintf
           "unknown keeper fields: %s. Call masc_persona_schema for supported fields."
           (String.concat ", " unknown))
    else (
      let goal = json_trimmed_string_opt "goal" keeper_json in
      let result =
        match goal with
        | None -> Error "keeper.goal is required"
        | Some goal -> Ok goal
      in
      Result.bind result (fun goal ->
        let tool_preset_result =
          match json_trimmed_string_opt "tool_preset" keeper_json with
          | None -> Ok Archetypes.default_tool_preset
          | Some raw -> normalize_tool_preset raw
        in
        Result.bind tool_preset_result (fun tool_preset ->
          let social_model_result =
            match json_trimmed_string_opt "social_model" keeper_json with
            | None -> Ok None
            | Some raw ->
              Result.map (fun value -> Some value) (normalize_social_model raw)
          in
          Result.bind social_model_result (fun social_model ->
            let cascade_name_result =
              match json_trimmed_string_opt "cascade_name" keeper_json with
              | None -> Ok None
              | Some raw ->
                Result.map (fun value -> Some value) (normalize_cascade_name raw)
            in
            Result.map
              (fun cascade_name ->
                 let mention_targets =
                   match json_string_list_normalized "mention_targets" keeper_json with
                   | [] -> [ handle ]
                   | xs -> xs
                 in
                 let get_goal_horizon key =
                   json_trimmed_string_opt key keeper_json |> Option.value ~default:goal
                 in
                 let fields =
                   [ "goal", `String goal
                   ; "short_goal", `String (get_goal_horizon "short_goal")
                   ; "mid_goal", `String (get_goal_horizon "mid_goal")
                   ; "long_goal", `String (get_goal_horizon "long_goal")
                   ; "mention_targets", string_list_to_json mention_targets
                   ; "tool_preset", `String tool_preset
                   ; ( "proactive_enabled"
                     , `Bool
                         (Safe_ops.json_bool
                            ~default:false
                            "proactive_enabled"
                            keeper_json) )
                   ]
                 in
                 let fields =
                   [ "will"
                   ; "needs"
                   ; "desires"
                   ; "instructions"
                   ; "work_discovery_guidance"
                   ]
                   |> List.fold_left
                        (fun acc key -> add_optional_string key acc keeper_json)
                        fields
                 in
                 let fields =
                   [ "policy_voice_enabled"
                   ; "room_signal_prompt_enabled"
                   ; "work_discovery_enabled"
                   ; "telemetry_feedback_enabled"
                   ; "always_approve"
                   ]
                   |> List.fold_left
                        (fun acc key -> add_optional_bool key acc keeper_json)
                        fields
                 in
                 let fields =
                   [ "proactive_idle_sec"
                   ; "proactive_cooldown_sec"
                   ; "work_discovery_interval_sec"
                   ; "telemetry_feedback_window_hours"
                   ; "max_turns_per_call"
                   ; "max_turns_per_call_scheduled_autonomous"
                   ]
                   |> List.fold_left
                        (fun acc key -> add_optional_int key acc keeper_json)
                        fields
                 in
                 let fields =
                   add_optional_float "per_provider_timeout" fields keeper_json
                 in
                 let fields =
                   [ "tool_also_allow"
                   ; "tool_denylist"
                   ; "shards"
                   ; "work_discovery_sources"
                   ]
                   |> List.fold_left
                        (fun acc key -> add_optional_string_list key acc keeper_json)
                        fields
                 in
                 let fields =
                   match social_model with
                   | Some value -> assoc_set "social_model" (`String value) fields
                   | None -> assoc_without "social_model" fields
                 in
                 let fields =
                   match cascade_name with
                   | Some value -> assoc_set "cascade_name" (`String value) fields
                   | None -> assoc_without "cascade_name" fields
                 in
                 `Assoc (List.rev fields))
              cascade_name_result))))
  | _ -> Error "profile.keeper must be an object"
;;

let normalize_profile ~handle profile =
  if not (Keeper_config.validate_name handle)
  then Error "handle must match [A-Za-z0-9._-]+"
  else (
    match profile with
    | `Assoc top_fields ->
      let keeper_json = assoc_get "keeper" profile |> Option.value ~default:`Null in
      (match normalize_keeper_json ~handle keeper_json with
       | Error msg -> Error msg
       | Ok keeper ->
         let display_name =
           json_trimmed_string_opt "name" profile |> Option.value ~default:handle
         in
         let top_fields =
           top_fields
           |> assoc_without "keeper"
           |> assoc_set "handle" (`String handle)
           |> assoc_set "name" (`String display_name)
           |> assoc_set "keeper" keeper
         in
         Ok (`Assoc (List.rev top_fields)))
    | _ -> Error "profile must be a JSON object")
;;

let ensure_personas_root root =
  try
    ignore (Keeper_fs.ensure_dir root);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let save_persona ?(overwrite = false) ?(dry_run = false) ~handle profile
  : (save_result, string) result
  =
  Result.bind (normalize_profile ~handle profile) (fun normalized ->
    let root = personas_root_candidate () in
    let profile_path = persona_profile_path ~root ~handle in
    let exists = Fs_compat.file_exists profile_path in
    if exists && not overwrite
    then
      Error
        (Printf.sprintf
           "persona '%s' already exists at %s (set overwrite=true to replace)"
           handle
           profile_path)
    else if dry_run
    then
      Ok
        { handle
        ; personas_root = root
        ; profile_path
        ; profile = normalized
        ; warnings = []
        }
    else
      Result.bind (ensure_personas_root root) (fun () ->
        match Keeper_fs.save_json_atomic profile_path normalized with
        | Error msg -> Error msg
        | Ok () ->
          Config_dir_resolver.reset ();
          Ok
            { handle
            ; personas_root = root
            ; profile_path
            ; profile = normalized
            ; warnings = []
            }))
;;

let save_result_to_json ?(dry_run = false) result =
  `Assoc
    [ "handle", `String result.handle
    ; "personas_root", `String result.personas_root
    ; "profile_path", `String result.profile_path
    ; "dry_run", `Bool dry_run
    ; "saved", `Bool (not dry_run)
    ; "profile", result.profile
    ; "warnings", string_list_to_json result.warnings
    ; ( "keeper_create_preview_args"
      , `Assoc [ "persona_name", `String result.handle; "dry_run", `Bool true ] )
    ]
;;

let handle_persona_save _ctx args =
  let handle = get_string args "handle" "" |> String.trim in
  let overwrite = get_bool args "overwrite" false in
  let dry_run = get_bool args "dry_run" false in
  match assoc_get "profile" args with
  | None -> false, error_response_typed ~code:Validation_error "profile is required"
  | Some profile ->
    (match save_persona ~overwrite ~dry_run ~handle profile with
     | Error msg -> false, error_response_typed ~code:Validation_error msg
     | Ok result -> true, Yojson.Safe.to_string (save_result_to_json ~dry_run result))
;;

let ascii_slug_char = function
  | 'A' .. 'Z' as c -> Some (Char.lowercase_ascii c)
  | 'a' .. 'z' as c -> Some c
  | '0' .. '9' as c -> Some c
  | ('.' | '_' | '-') as c -> Some c
  | ' ' | '\t' | '\n' | '\r' -> Some '-'
  | _ -> None
;;

let collapse_dashes raw =
  let b = Buffer.create (String.length raw) in
  let last_dash = ref false in
  String.iter
    (fun c ->
       if Char.equal c '-'
       then (
         if not !last_dash then Buffer.add_char b c;
         last_dash := true)
       else (
         Buffer.add_char b c;
         last_dash := false))
    raw;
  Buffer.contents b
;;

let trim_dashes raw =
  let len = String.length raw in
  let rec left i =
    if i >= len then len else if Char.equal raw.[i] '-' then left (i + 1) else i
  in
  let rec right i =
    if i < 0 then -1 else if Char.equal raw.[i] '-' then right (i - 1) else i
  in
  let l = left 0 in
  let r = right (len - 1) in
  if l > r then "" else String.sub raw l (r - l + 1)
;;

let handle_from_concept concept =
  let b = Buffer.create (String.length concept) in
  String.iter
    (fun c ->
       match ascii_slug_char c with
       | Some normalized -> Buffer.add_char b normalized
       | None -> ())
    concept;
  let candidate = Buffer.contents b |> collapse_dashes |> trim_dashes in
  let candidate =
    if String.length candidate > 48
    then String.sub candidate 0 48 |> trim_dashes
    else candidate
  in
  if Keeper_config.validate_name candidate
  then candidate
  else "persona-" ^ String.sub (Digest.to_hex (Digest.string concept)) 0 8
;;

let normalize_choice_arg ~field ~choices raw =
  let normalized = String.trim raw |> String.lowercase_ascii in
  if List.mem normalized choices
  then Ok normalized
  else
    Error
      (Printf.sprintf
         "invalid %s '%s' (allowed: %s)"
         field
         raw
         (String.concat ", " choices))
;;

let optional_choice_arg ~field ~choices args =
  match get_string_opt args field |> trim_nonempty_opt with
  | None -> Ok None
  | Some raw ->
    Result.map
      (fun normalized -> Some normalized)
      (normalize_choice_arg ~field ~choices raw)
;;

let selected_archetype_axes_from_args args =
  Result.bind
    (optional_choice_arg ~field:"alignment" ~choices:alignment_choices args)
    (fun alignment ->
       Result.bind
         (optional_choice_arg
            ~field:"operating_style"
            ~choices:operating_style_choices
            args)
         (fun operating_style ->
            Result.map
              (fun risk_posture -> { alignment; operating_style; risk_posture })
              (optional_choice_arg
                 ~field:"risk_posture"
                 ~choices:risk_posture_choices
                 args)))
;;

let archetype_axes_to_json axes =
  `Assoc
    ([]
     @ option_field "alignment" (Option.map (fun value -> `String value) axes.alignment)
     @ option_field
         "operating_style"
         (Option.map (fun value -> `String value) axes.operating_style)
     @ option_field
         "risk_posture"
         (Option.map (fun value -> `String value) axes.risk_posture))
;;

let selected_axis_effect_to_json ~axis value effects =
  match choice_effect_for value effects with
  | Some choice -> Some (`Assoc (("axis", `String axis) :: choice_effect_fields choice))
  | None -> None
;;

let selected_archetype_effects_to_json axes =
  let selected =
    [ Option.bind
        axes.alignment
        (fun value ->
           selected_axis_effect_to_json
             ~axis:"alignment"
             value
             alignment_choice_effects)
    ; Option.bind
        axes.operating_style
        (fun value ->
           selected_axis_effect_to_json
             ~axis:"operating_style"
             value
             operating_style_choice_effects)
    ; Option.bind
        axes.risk_posture
        (fun value ->
           selected_axis_effect_to_json
             ~axis:"risk_posture"
             value
             risk_posture_choice_effects)
    ]
    |> List.filter_map (fun x -> x)
  in
  `List selected
;;

let archetype_axes_prompt axes =
  let value = Option.value ~default:"(unspecified)" in
  Printf.sprintf
    "- alignment: %s\n- operating_style: %s\n- risk_posture: %s"
    (value axes.alignment)
    (value axes.operating_style)
    (value axes.risk_posture)
;;

let generation_tool_preset args axes =
  match get_string_opt args "tool_preset" |> trim_nonempty_opt with
  | Some raw -> normalize_tool_preset raw
  | None ->
    (match axes.operating_style with
     | Some style -> normalize_tool_preset style
     | None -> Ok Archetypes.default_tool_preset)
;;

let generation_prompt
      ~concept
      ~handle
      ~display_name_opt
      ~archetype_axes
      ~tool_preset
      ~proactive_enabled
      ~language
  =
  Printf.sprintf
    {|
You are drafting a MASC persona profile.json.

Return one JSON object only. Do not wrap it in markdown.
The JSON shape must be:
{
  "handle": "%s",
  "profile": {
    "name": "...",
    "role": "...",
    "trait": "...",
    "keeper": {
      "goal": "...",
      "short_goal": "...",
      "mid_goal": "...",
      "long_goal": "...",
      "instructions": "...",
      "will": "...",
      "needs": "...",
      "desires": "...",
      "mention_targets": ["%s"],
      "tool_preset": "%s",
      "proactive_enabled": %b
    }
  },
  "field_explanations": [
    {"path": "keeper.goal", "value": "...", "effect": "..."}
  ]
}

Concept:
%s

Selected archetype axes:
%s

Selected archetype effects:
%s

Preferred display name: %s
Output language: %s

Supported field catalog:
%s

Supported archetype axes:
%s

Constraints:
- keeper.goal is required and must be concrete enough to create a keeper.
- Do not include unsupported keeper fields.
- Keep the result useful for a real long-running keeper, not a marketing character sheet.
- Apply the selected archetype axes concretely through role, trait, keeper.goal, and keeper.instructions.
- Give field_explanations for every non-empty keeper.* field you set.
|}
    handle
    handle
    tool_preset
    proactive_enabled
    concept
    (archetype_axes_prompt archetype_axes)
    (Yojson.Safe.pretty_to_string (selected_archetype_effects_to_json archetype_axes))
    (Option.value ~default:"(choose one)" display_name_opt)
    language
    (Yojson.Safe.pretty_to_string (field_catalog_json ()))
    (Yojson.Safe.pretty_to_string (archetype_axes_json ()))
;;

let parsed_profile_payload json =
  match assoc_get "profile" json with
  | Some (`Assoc _ as profile) -> profile
  | _ -> json
;;

let parsed_handle_payload fallback json =
  let candidate =
    match assoc_get "handle" json with
    | Some (`String s) -> Some (String.trim s)
    | _ -> None
  in
  match candidate with
  | Some value when Keeper_config.validate_name value -> value
  | _ -> fallback
;;

let field_explanations_payload json =
  match assoc_get "field_explanations" json with
  | Some (`List _ as xs) -> xs
  | _ -> `List []
;;

let handle_persona_generate ctx args =
  match get_string_required args "concept" with
  | Error error_json -> false, error_json
  | Ok concept ->
    let requested_handle =
      match get_string_opt args "handle" with
      | Some raw ->
        let value = String.trim raw in
        if value = "" then None else Some value
      | None -> None
    in
    let fallback_handle =
      requested_handle |> Option.value ~default:(handle_from_concept concept)
    in
    if not (Keeper_config.validate_name fallback_handle)
    then
      ( false
      , error_response_typed ~code:Validation_error "handle must match [A-Za-z0-9._-]+" )
    else (
      match selected_archetype_axes_from_args args with
      | Error msg -> false, error_response_typed ~code:Validation_error msg
      | Ok archetype_axes ->
        (match generation_tool_preset args archetype_axes with
         | Error msg -> false, error_response_typed ~code:Validation_error msg
         | Ok tool_preset ->
           let cascade_name =
             get_string args "cascade_name" Archetypes.default_generation_cascade_name
             |> String.trim
           in
           let cascade_name =
             if cascade_name = ""
             then Archetypes.default_generation_cascade_name
             else cascade_name
           in
           let temperature =
             get_float_opt args "temperature"
             |> Option.value ~default:Archetypes.default_temperature
           in
           let max_tokens =
             get_int_opt args "max_tokens"
             |> Option.value ~default:Archetypes.default_max_tokens
           in
           let proactive_enabled =
             get_bool args "proactive_enabled" Archetypes.default_proactive_enabled
           in
           let language =
             get_string args "language" Archetypes.default_generation_language
             |> String.trim
           in
           let display_name_opt = get_string_opt args "display_name" in
           let prompt =
             generation_prompt
               ~concept
               ~handle:fallback_handle
               ~display_name_opt
               ~archetype_axes
               ~tool_preset
               ~proactive_enabled
               ~language
           in
           match
             Masc_oas_bridge.run_with_caller
               ~caller:Env_config_oas_bridge.Keeper_persona_authoring
               (fun () ->
                 Oas_worker.run_named
                   ~cascade_name
                   ~goal:prompt
                   ~max_turns:1
                   ~temperature
                   ~max_tokens
                   ~approval:Approval_callbacks.auto_approve
                   ~sw:ctx.Keeper_types.sw
                   ?net:ctx.Keeper_types.net
                   ())
           with
           | Error err ->
             ( false
             , error_response_typed
                 ~code:Internal_error
                 (Printf.sprintf
                    "persona generation failed: %s"
                    (Oas.Error.to_string err)) )
           | Ok result ->
             let raw_text = Oas_response.text_of_response result.Oas_worker.response in
             (try
                let parsed = Llm_provider.Lenient_json.parse raw_text in
                let handle = parsed_handle_payload fallback_handle parsed in
                let profile = parsed_profile_payload parsed in
                match normalize_profile ~handle profile with
                | Error msg ->
                  ( false
                  , error_response_typed
                      ~code:Validation_error
                      (Printf.sprintf "generated profile is invalid: %s" msg) )
                | Ok normalized ->
                  let json =
                    `Assoc
                      [ "handle", `String handle
                      ; "selected_archetype_axes", archetype_axes_to_json archetype_axes
                      ; ( "selected_archetype_effects"
                        , selected_archetype_effects_to_json archetype_axes )
                      ; "profile", normalized
                      ; "field_explanations", field_explanations_payload parsed
                      ; "raw_model", `String raw_text
                      ; ( "save_args"
                        , `Assoc
                            [ "handle", `String handle
                            ; "profile", normalized
                            ; "overwrite", `Bool false
                            ; "dry_run", `Bool false
                            ] )
                      ; ( "keeper_create_preview_args"
                        , `Assoc [ "persona_name", `String handle; "dry_run", `Bool true ] )
                      ]
                  in
                  true, Yojson.Safe.to_string json
              with
              | Yojson.Json_error msg ->
                ( false
                , error_response_typed
                    ~code:Validation_error
                    (Printf.sprintf "generation did not return parseable JSON: %s" msg) ))))
;;
