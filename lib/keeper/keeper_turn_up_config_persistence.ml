open Keeper_meta_contract
open Keeper_types_profile

type outcome =
  { path : string
  ; created : bool
  }

let set_string value =
  Keeper_toml_loader.Set (Keeper_toml_loader.Toml_string value)

let set_bool value =
  Keeper_toml_loader.Set (Keeper_toml_loader.Toml_bool value)

let set_int value =
  Keeper_toml_loader.Set (Keeper_toml_loader.Toml_int value)

let set_strings values =
  Keeper_toml_loader.Set (Keeper_toml_loader.Toml_string_array values)

let append_optional key make value fields =
  match value with
  | Some value -> (key, make value) :: fields
  | None -> fields

let full_fields
      (parsed : Keeper_turn_up_args.parsed_args)
      (meta : keeper_meta)
  =
  let fields =
    [ "name", Keeper_toml_loader.Toml_string meta.name
    ; ( "sandbox_profile"
      , Keeper_toml_loader.Toml_string
          (sandbox_profile_to_string meta.sandbox_profile) )
    ; ( "network_mode"
      , Keeper_toml_loader.Toml_string
          (network_mode_to_string meta.network_mode) )
    ; "allowed_paths", Keeper_toml_loader.Toml_string_array meta.allowed_paths
    ; "mention_targets", Keeper_toml_loader.Toml_string_array meta.mention_targets
    ; "proactive_enabled", Keeper_toml_loader.Toml_bool meta.proactive.enabled
    ; "autoboot_enabled", Keeper_toml_loader.Toml_bool meta.autoboot_enabled
    ]
  in
  let fields =
    match meta.max_context_override with
    | Some value ->
      ("max_context_override", Keeper_toml_loader.Toml_int value) :: fields
    | None -> fields
  in
  (* Not a meta field: the per-keeper wake prompt lives only in the keeper
     TOML (profile-defaults layer, #28456), so the creation snapshot takes it
     from the parsed args rather than from [meta]. *)
  match parsed.Keeper_turn_up_args.autonomous_wake_prompt_opt with
  | Some value ->
    ("autonomous_wake_prompt", Keeper_toml_loader.Toml_string value) :: fields
  | None -> fields

let explicit_edits
      (parsed : Keeper_turn_up_args.parsed_args)
  =
  []
  |> append_optional "sandbox_profile" set_string parsed.sandbox_profile_opt
  |> append_optional "network_mode" set_string parsed.network_mode_opt
  |> append_optional "allowed_paths" set_strings parsed.allowed_paths_opt
  |> append_optional "mention_targets" set_strings parsed.mention_targets_opt
  |> append_optional "proactive_enabled" set_bool parsed.proactive_enabled_opt
  |> append_optional "autoboot_enabled" set_bool parsed.autoboot_enabled_opt
  |> fun fields ->
  (if not parsed.max_context_override_present
   then fields
   else
     ( "max_context_override"
     , match parsed.max_context_override_opt with
       | Some value -> set_int value
       | None -> Keeper_toml_loader.Remove )
     :: fields)
  |> fun fields ->
  if not parsed.autonomous_wake_prompt_present
  then fields
  else
    ( "autonomous_wake_prompt"
    , match parsed.autonomous_wake_prompt_opt with
      | Some value -> set_string value
      | None -> Keeper_toml_loader.Remove )
    :: fields

let persist ~(config : Workspace.config)
    ~(parsed : Keeper_turn_up_args.parsed_args) ~(meta : keeper_meta) =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  let path = Filename.concat keepers_dir (meta.name ^ ".toml") in
  let prompt_path =
    Filename.concat (Filename.concat keepers_dir meta.name) "AGENT.md"
  in
  let prompt_result =
    match parsed.instructions_arg with
    | Some instructions ->
      Fs_compat.mkdir_p (Filename.dirname prompt_path);
      Fs_compat.save_file_atomic prompt_path (String.trim instructions ^ "\n")
    | None when Fs_compat.file_exists prompt_path -> Ok ()
    | None ->
      let instructions = String.trim meta.instructions in
      if instructions = "" then Error "keeper instructions are required"
      else (
        Fs_compat.mkdir_p (Filename.dirname prompt_path);
        Fs_compat.save_file_atomic prompt_path (instructions ^ "\n"))
  in
  let result = Result.bind prompt_result (fun () ->
    if Fs_compat.file_exists path
    then
      let edits = explicit_edits parsed in
      if edits = []
      then Ok { path; created = false }
      else
        Keeper_toml_loader.edit_keeper_toml_fields ~path edits
        |> Result.map (fun () -> { path; created = false })
    else
      Keeper_toml_loader.create_keeper_toml_file
        ~path
        (full_fields parsed meta)
      |> Result.map (fun () -> { path; created = true }))
  in
  Result.map
    (fun outcome ->
      Keeper_types_profile.invalidate_keeper_profile_defaults_cache meta.name;
      outcome)
    result
