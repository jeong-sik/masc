open Keeper_meta_contract
open Keeper_types_profile

type outcome =
  { path : string
  ; created : bool
  ; revision : revision
  }

and revision =
  | Missing
  | Sha256 of string

type conflict =
  { expected : revision
  ; observed : revision
  }

type warning =
  | Manifest_parent_sync_unconfirmed of string
  | Lock_release_unconfirmed of string

type 'a receipt =
  { value : 'a
  ; warnings : warning list
  }

type reconciliation_observation =
  | Observed_revision of revision
  | Unreadable_manifest of string

type reconciliation =
  { path : string
  ; detail : string
  ; observed : reconciliation_observation
  }

type error =
  | Io_error of string
  | Revision_conflict of conflict
  | Reconciliation_required of reconciliation

type 'a publication =
  | Commit of 'a
  | Rollback of 'a

let revision_to_yojson = function
  | Missing -> `Assoc [ "state", `String "missing" ]
  | Sha256 value ->
    `Assoc [ "state", `String "sha256"; "value", `String value ]

let revision_of_yojson = function
  | `Assoc [ ("state", `String "missing") ] -> Ok Missing
  | `Assoc
      ([ ("state", `String "sha256"); ("value", `String value) ]
      | [ ("value", `String value); ("state", `String "sha256") ])
    when String.length value = 64
         && String.equal value (String.lowercase_ascii value) ->
    (match Digestif.SHA256.of_hex_opt value with
     | Some _ -> Ok (Sha256 value)
     | None -> Error "expected_manifest_revision.value must be lowercase SHA-256 hex")
  | `Assoc fields ->
    (match List.assoc_opt "state" fields with
     | Some (`String "missing") ->
       Error "expected_manifest_revision missing state has unexpected fields"
     | Some (`String "sha256") ->
       Error "expected_manifest_revision sha256 state requires only a lowercase SHA-256 value"
     | Some (`String state) ->
       Error (Printf.sprintf "unsupported expected_manifest_revision.state: %S" state)
     | Some _ -> Error "expected_manifest_revision.state must be a string"
     | None -> Error "expected_manifest_revision.state is required")
  | _ -> Error "expected_manifest_revision must be an object"

let revision_display = function
  | Missing -> "missing"
  | Sha256 value -> "sha256:" ^ value

let error_to_string = function
  | Io_error detail -> detail
  | Revision_conflict { expected; observed } ->
    Printf.sprintf
      "keeper manifest revision conflict (expected %s, observed %s)"
      (revision_display expected)
      (revision_display observed)
  | Reconciliation_required { path; detail; observed } ->
    let observed =
      match observed with
      | Observed_revision revision -> revision_display revision
      | Unreadable_manifest error -> "unreadable:" ^ error
    in
    Printf.sprintf
      "keeper manifest requires reconciliation (path %s, observed %s): %s"
      path
      observed
      detail

let warning_to_yojson = function
  | Manifest_parent_sync_unconfirmed detail ->
    `Assoc
      [ "code", `String "keeper_manifest_parent_sync_unconfirmed"
      ; "detail", `String detail
      ]
  | Lock_release_unconfirmed detail ->
    `Assoc
      [ "code", `String "keeper_manifest_lock_release_unconfirmed"
      ; "detail", `String detail
      ]

type manifest_snapshot =
  | Absent
  | Present of string

let read_snapshot_unlocked path =
  if not (Fs_compat.file_exists path)
  then Ok Absent
  else Safe_ops.read_file_safe path |> Result.map (fun bytes -> Present bytes)

let revision_of_snapshot = function
  | Absent -> Missing
  | Present bytes ->
    Sha256 Digestif.SHA256.(digest_string bytes |> to_hex)

let revision_of_path_unlocked path =
  read_snapshot_unlocked path |> Result.map revision_of_snapshot

let observed_revision_after_failure path =
  match revision_of_path_unlocked path with
  | Ok revision -> Observed_revision revision
  | Error detail -> Unreadable_manifest detail

let reconciliation_required path detail =
  Reconciliation_required
    { path; detail; observed = observed_revision_after_failure path }

let restore_snapshot_unlocked path = function
  | Present bytes ->
    (match Fs_compat.save_file_atomic_strict_staged path bytes with
     | Ok () -> Ok ()
     | Error failure ->
       Error
         (reconciliation_required
            path
            (Fs_compat.atomic_replace_failure_to_string failure)))
  | Absent ->
    if not (Fs_compat.file_exists path)
    then Ok ()
    else
      (try
         Sys.remove path;
         Keeper_fs_durable_directory.fsync_directory (Filename.dirname path);
         Ok ()
       with exn ->
         Error
           (reconciliation_required
              path
              (Printf.sprintf
                 "cannot durably roll back created keeper manifest: %s"
                 (Printexc.to_string exn))))

let manifest_path ~(config : Workspace.config) ~keeper_name =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
  in
  Filename.concat keepers_dir (keeper_name ^ ".toml")

let with_manifest_lock_using observe path f =
  Fs_compat.mkdir_p (Filename.dirname path);
  let lock_path = path ^ ".lock" in
  match observe ~lock_path f with
  | File_lock_eio.Lock_not_acquired error ->
    Error (File_lock_eio.durable_lock_error_to_string error)
  | File_lock_eio.Body_completed { value; release_error = None } ->
    Ok { value; warnings = [] }
  | File_lock_eio.Body_completed { value; release_error = Some error } ->
    Ok
      { value
      ; warnings =
          [ Lock_release_unconfirmed
              (File_lock_eio.durable_lock_error_to_string error)
          ]
      }

let with_manifest_lock path f =
  with_manifest_lock_using File_lock_eio.with_durable_lock_observed path f

let with_current_revision ~config ~keeper_name project =
  let path = manifest_path ~config ~keeper_name in
  match
    with_manifest_lock path (fun () ->
      revision_of_path_unlocked path |> Result.map project)
  with
  | Error _ as error -> error
  | Ok { value = Error detail; _ } -> Error detail
  | Ok { value = Ok value; warnings } -> Ok { value; warnings }

let current_revision ~config ~keeper_name =
  with_current_revision ~config ~keeper_name Fun.id
  |> Result.map (fun receipt -> receipt.value)

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
    ; "instructions", Keeper_toml_loader.Toml_string meta.instructions
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
  let fields =
    match meta.tool_groups with
    | Some groups ->
      ("tools.groups", Keeper_toml_loader.Toml_string_array groups) :: fields
    | None -> fields
  in
  let fields =
    match
      if parsed.skill_names_present
      then parsed.skill_names_opt
      else parsed.profile_defaults.skill_names
    with
    | Some names -> ("skills.names", Keeper_toml_loader.Toml_string_array names) :: fields
    | None -> fields
  in
  let fields =
    match
      if parsed.native_tool_posture_present
      then parsed.native_tool_posture_opt
      else parsed.profile_defaults.native_tool_posture
    with
    | Some posture ->
      ( "tools.native"
      , Keeper_toml_loader.Toml_string
          (Runtime_native_tools.to_string posture) )
      :: fields
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
  |> append_optional "instructions" set_string parsed.instructions_arg
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
  (if not parsed.tool_groups_present
   then fields
   else
     ( "tools.groups"
     , match parsed.tool_groups_opt with
       | Some groups -> set_strings groups
       | None -> Keeper_toml_loader.Remove )
     :: fields)
  |> fun fields ->
  (if not parsed.skill_names_present
   then fields
   else
     ( "skills.names"
     , match parsed.skill_names_opt with
       | Some names -> set_strings names
       | None -> Keeper_toml_loader.Remove )
     :: fields)
  |> fun fields ->
  (if not parsed.native_tool_posture_present
   then fields
   else
     ( "tools.native"
     , match parsed.native_tool_posture_opt with
       | Some posture ->
         set_string (Runtime_native_tools.to_string posture)
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

let strict_write_result = function
  | Ok () -> Ok []
  | Error
      (({ stage = Fs_compat.Before_rename; _ } :
          Fs_compat.atomic_replace_failure) as failure) ->
    Error (Io_error (Fs_compat.atomic_replace_failure_to_string failure))
  | Error
      (({ stage = Fs_compat.After_rename; _ } :
          Fs_compat.atomic_replace_failure) as failure) ->
    Ok
      [ Manifest_parent_sync_unconfirmed
          (Fs_compat.atomic_replace_failure_to_string failure)
      ]

let persist_with_publication_using ~with_lock ~restore_snapshot ~expected_revision
    ~(config : Workspace.config)
    ~(parsed : Keeper_turn_up_args.parsed_args) ~(meta : keeper_meta) ~publish () =
  let path = manifest_path ~config ~keeper_name:meta.name in
  let instructions_result =
    if String.trim meta.instructions = ""
    then Error "keeper instructions are required"
    else Ok ()
  in
  match with_lock path (fun () ->
      let ( let* ) = Result.bind in
      let* () = instructions_result |> Result.map_error (fun error -> Io_error error) in
      let* snapshot =
        read_snapshot_unlocked path |> Result.map_error (fun error -> Io_error error)
      in
      let observed = revision_of_snapshot snapshot in
      let* () =
        if expected_revision <> observed
        then Error (Revision_conflict { expected = expected_revision; observed })
        else Ok ()
      in
      let created = observed = Missing in
      let* write_warnings =
        (if created
         then
           Keeper_toml_loader.create_keeper_toml_file_strict_staged
             ~path
             (full_fields parsed meta)
         else
           let edits = explicit_edits parsed in
           if edits = []
           then Ok ()
           else Keeper_toml_loader.edit_keeper_toml_fields_strict_staged ~path edits)
        |> strict_write_result
      in
      let* revision =
        revision_of_path_unlocked path |> Result.map_error (fun error -> Io_error error)
      in
      let outcome = { path; created; revision } in
      (match publish outcome with
       | Commit value ->
         Keeper_types_profile.invalidate_keeper_profile_defaults_cache meta.name;
         Ok { value; warnings = write_warnings }
       | Rollback value ->
         Keeper_types_profile.invalidate_keeper_profile_defaults_cache meta.name;
         let* () = restore_snapshot path snapshot in
         Ok { value; warnings = [] }))
  with
  | Error error -> Error (Io_error error)
  | Ok { value = Error error; _ } -> Error error
  | Ok
      { value = Ok { value; warnings = write_warnings }
      ; warnings = lock_warnings
      } ->
    Ok { value; warnings = write_warnings @ lock_warnings }

let persist_with_publication ~expected_revision ~config ~parsed ~meta ~publish () =
  persist_with_publication_using
    ~with_lock:with_manifest_lock
    ~restore_snapshot:restore_snapshot_unlocked
    ~expected_revision
    ~config
    ~parsed
    ~meta
    ~publish
    ()

let persist ~expected_revision ~config ~parsed ~meta () =
  persist_with_publication ~expected_revision ~config ~parsed ~meta
    ~publish:(fun outcome -> Commit outcome) ()

module For_testing = struct
  let persist_with_release_failure ~release_failure ~expected_revision ~config
      ~parsed ~meta () =
    let with_lock path f =
      let observe ~lock_path body =
        File_lock_eio.For_testing.with_durable_lock_observed_with_release_failure
          ~release_failure
          ~lock_path
          body
      in
      with_manifest_lock_using observe path f
    in
    persist_with_publication_using
      ~with_lock
      ~restore_snapshot:restore_snapshot_unlocked
      ~expected_revision
      ~config
      ~parsed
      ~meta
      ~publish:(fun outcome -> Commit outcome)
      ()
  ;;

  let persist_with_rollback_parent_sync_failure ~expected_revision ~config
      ~parsed ~meta () =
    let restore_snapshot path = function
      | Absent -> restore_snapshot_unlocked path Absent
      | Present bytes ->
        (match
           Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
             ~sync_parent:(fun _ -> raise (Failure "injected rollback parent sync"))
             path
             bytes
         with
         | Ok () -> failwith "rollback parent sync injection was not observed"
         | Error failure ->
           Error
             (reconciliation_required
                path
                (Fs_compat.atomic_replace_failure_to_string failure)))
    in
    persist_with_publication_using
      ~with_lock:with_manifest_lock
      ~restore_snapshot
      ~expected_revision
      ~config
      ~parsed
      ~meta
      ~publish:(fun _ -> Rollback ())
      ()
  ;;
end
