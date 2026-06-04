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
  ; risk_posture : string option
  }

let string_list_to_json = Json_util.json_string_list
let option_field = Archetypes.option_field

let assoc_without key fields =
  List.filter (fun (candidate, _) -> not (String.equal candidate key)) fields
;;

let assoc_set key value fields = (key, value) :: assoc_without key fields

;;

let assoc_get = Json_util.assoc_member_opt
;;

let assoc_keys = function
  | `Assoc fields -> List.map fst fields
  | _ -> []
;;


let json_trimmed_string_opt key json =
  Safe_ops.json_string_opt key json |> String_util.option_trim
;;

let json_string_list_normalized key json =
  Safe_ops.json_string_list key json
  |> Keeper_types_profile_toml_normalizers.normalize_name_list
;;

type field_catalog_entry =
  { path : string
  ; typ : string
  ; required : bool
  ; default : Yojson.Safe.t option
  ; choices : Yojson.Safe.t option
  ; field_effect : string
  }

let field_catalog_entry ?default ?choices ?(required = false) ~path ~typ ~field_effect () =
  { path; typ; required; default; choices; field_effect }
;;

let field_catalog_entry_to_json entry =
  `Assoc
    ([ "path", `String entry.path
     ; "type", `String entry.typ
     ; "required", `Bool entry.required
     ; "effect", `String entry.field_effect
     ]
     @ option_field "default" entry.default
     @ option_field "choices" entry.choices)
;;

let social_model_choices_json =
  string_list_to_json Keeper_types_profile_toml_normalizers.valid_social_model_strings
;;

let alignment_choices = Archetypes.alignment_choices
let risk_posture_choices = Archetypes.risk_posture_choices
let alignment_choice_effects = Archetypes.alignment_choice_effects
let risk_posture_choice_effects = Archetypes.risk_posture_choice_effects
let choice_effect_fields = Archetypes.choice_effect_fields
let choice_effect_for = Archetypes.choice_effect_for
let archetype_axes_json = Archetypes.archetype_axes_json

let field_catalog_entries =
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
        ~path:"keeper.shards"
        ~typ:"string[]"
        ~field_effect:"Persona-specific prompt shards applied after keeper creation."
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
        ~field_effect:"Per-provider runtime timeout override for this keeper."
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
  ]
;;

let field_catalog_json () =
  `List (List.map field_catalog_entry_to_json field_catalog_entries)
;;

let keeper_field_prefix = "keeper."

let keeper_field_name_of_catalog_path path =
  if String.starts_with ~prefix:keeper_field_prefix path
  then
    Some
      (String.sub
         path
         (String.length keeper_field_prefix)
         (String.length path - String.length keeper_field_prefix))
  else None
;;

let allowed_keeper_fields =
  field_catalog_entries
  |> List.filter_map (fun entry -> keeper_field_name_of_catalog_path entry.path)
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
           [ "social_model", social_model_choices_json
           ; ( "proactive_enabled"
             , `Assoc
                 [ "false", `String "Keeper stays passive unless called."
                 ; "true", `String "Keeper may run proactive scheduled turns."
                 ] )
           ] )
     ; "archetype_axes", archetype_axes_json ()
     ; ( "authoring_flow"
       , `Assoc
           [ "schema_tool", `String "masc_persona_schema"
           ; "save_tool", `String "masc_persona_save"
           ; "dry_run_keeper_tool", `String "masc_keeper_create_from_persona"
           ; "start_keeper_tool", `String "masc_keeper_create_from_persona"
           ; ( "save_args"
             , `Assoc
                 [ "handle", `String "<handle>"
                 ; "profile", `String "<hand-authored profile JSON>"
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

let handle_persona_schema_no_ctx args =
  let include_examples = get_bool args "include_examples" false in
  Tool_result.ok
    ~tool_name:""
    ~start_time:(Time_compat.now ())
    (Yojson.Safe.to_string (schema_json ~include_examples ()))
;;

let handle_persona_schema _ctx args = handle_persona_schema_no_ctx args

let validate_unknown_keeper_fields keeper_json =
  assoc_keys keeper_json
  |> List.filter (fun key -> not (List.mem key allowed_keeper_fields))
;;

let normalize_social_model raw =
  match Keeper_types_profile_toml_normalizers.normalize_social_model_opt (Some raw) with
  | Some value -> Ok value
  | None ->
    Error
      (Printf.sprintf
         "invalid keeper.social_model '%s' (allowed: %s)"
         raw
         (String.concat
            ", "
            Keeper_types_profile_toml_normalizers.valid_social_model_strings))
;;

let removed_runtime_selection_fields = [ "runtime_id"; "model" ]

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
    let removed_runtime_fields =
      assoc_keys keeper_json
      |> List.filter (fun key -> List.mem key removed_runtime_selection_fields)
    in
    if removed_runtime_fields <> []
    then
      Error
        (Printf.sprintf
           "keeper.%s %s removed. Assign keeper runtime in runtime.toml \
            [[runtime.assignments]] keyed by keeper name."
           (String.concat " / keeper." removed_runtime_fields)
           (if List.length removed_runtime_fields = 1 then "is" else "are"))
    else
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
          let social_model_result =
            match json_trimmed_string_opt "social_model" keeper_json with
            | None -> Ok None
            | Some raw ->
              Result.map (fun value -> Some value) (normalize_social_model raw)
          in
          Result.bind social_model_result (fun social_model ->
            let mention_targets =
              match json_string_list_normalized "mention_targets" keeper_json with
              | [] -> [ handle ]
              | xs -> xs
            in
            let get_goal_horizon key =
              match json_trimmed_string_opt key keeper_json with
              | Some value -> value
              | None -> goal
            in
            let fields =
              [ "goal", `String goal
              ; "short_goal", `String (get_goal_horizon "short_goal")
              ; "mid_goal", `String (get_goal_horizon "mid_goal")
              ; "long_goal", `String (get_goal_horizon "long_goal")
              ; "mention_targets", string_list_to_json mention_targets
              ; ( "proactive_enabled"
                , `Bool
                    (Safe_ops.json_bool
                       ~default:false
                       "proactive_enabled"
                       keeper_json) )
              ]
            in
            let fields =
              [ "will"; "needs"; "desires"; "instructions" ]
              |> List.fold_left
                   (fun acc key -> add_optional_string key acc keeper_json)
                   fields
            in
            let fields =
              [ "telemetry_feedback_enabled"; "always_approve" ]
              |> List.fold_left
                   (fun acc key -> add_optional_bool key acc keeper_json)
                   fields
            in
            let fields =
              [ "proactive_idle_sec"
              ; "proactive_cooldown_sec"
              ; "telemetry_feedback_window_hours"
              ; "max_turns_per_call"
              ; "max_turns_per_call_scheduled_autonomous"
              ]
              |> List.fold_left
                   (fun acc key -> add_optional_int key acc keeper_json)
                   fields
            in
            let fields = add_optional_float "per_provider_timeout" fields keeper_json in
            let fields =
              [ "tool_denylist"; "shards" ]
              |> List.fold_left
                   (fun acc key -> add_optional_string_list key acc keeper_json)
                   fields
            in
            let fields =
              match social_model with
              | Some value -> assoc_set "social_model" (`String value) fields
              | None -> assoc_without "social_model" fields
            in
            Ok (`Assoc (List.rev fields)))))
  | other ->
    Error
      (Printf.sprintf
         "profile.keeper must be an object (received %s)"
         (Json_util.kind_name other))
;;

let normalize_profile ~handle profile =
  if not (Ids.Keeper_id.Name.validate handle)
  then Error "handle must match [A-Za-z0-9._-]+"
  else if Keeper_types_profile_persona.json_has_operator_todo_placeholder profile
  then
    Error
      "profile contains OPERATOR_TODO placeholder text; replace placeholders before saving"
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
    | other ->
      Error
        (Printf.sprintf
           "profile must be a JSON object (received %s)"
           (Json_util.kind_name other)))
;;

let ensure_persona_profile_dir profile_path =
  try
    Fs_compat.mkdir_p (Filename.dirname profile_path);
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
      Result.bind (ensure_persona_profile_dir profile_path) (fun () ->
        match
          Fs_compat.save_file_atomic
            profile_path
            (Yojson.Safe.pretty_to_string normalized)
        with
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

let handle_persona_save_no_ctx args =
  let handle = get_string args "handle" "" |> String.trim in
  let overwrite = get_bool args "overwrite" false in
  let dry_run = get_bool args "dry_run" false in
  match assoc_get "profile" args with
  | None ->
    Tool_result.error
      ~tool_name:""
      ~start_time:(Time_compat.now ())
      (error_response_typed ~code:Validation_error "profile is required")
  | Some profile ->
    (match save_persona ~overwrite ~dry_run ~handle profile with
     | Error msg ->
       Tool_result.error
         ~tool_name:""
         ~start_time:(Time_compat.now ())
         (error_response_typed ~code:Validation_error msg)
     | Ok result ->
       Tool_result.ok
         ~tool_name:""
         ~start_time:(Time_compat.now ())
         (Yojson.Safe.to_string (save_result_to_json ~dry_run result)))
;;

let handle_persona_save _ctx args = handle_persona_save_no_ctx args

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
  match get_string_opt args field |> String_util.option_trim with
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
       Result.map
         (fun risk_posture -> { alignment; risk_posture })
         (optional_choice_arg
            ~field:"risk_posture"
            ~choices:risk_posture_choices
            args))
;;

let archetype_axes_to_json axes =
  `Assoc
    ([]
     @ option_field "alignment" (Option.map (fun value -> `String value) axes.alignment)
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
