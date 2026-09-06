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

type config_revision =
  { manifest : revision
  ; runtime_assignment : Runtime.keeper_assignment_revision
  }

type conflict =
  { expected : config_revision
  ; observed : config_revision
  }

type warning =
  | Manifest_parent_sync_unconfirmed of string
  | Runtime_config_parent_sync_unconfirmed of string
  | Lock_release_unconfirmed of string
  | Runtime_config_lock_release_unconfirmed of string

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

type runtime_reconciliation =
  { path : string option
  ; detail : string
  }

type composite_reconciliation =
  { manifest : reconciliation option
  ; runtime_assignment : runtime_reconciliation option
  }

type error =
  | Io_error of string
  | Revision_conflict of conflict
  | Reconciliation_required of reconciliation
  | Composite_reconciliation_required of composite_reconciliation
  | Publication_exception of
      { path : string
      ; detail : string
      }

type 'a publication =
  | Commit of 'a
  | Commit_with_warnings of 'a * warning list
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
    when String_util.is_lowercase_sha256_hex value ->
    Ok (Sha256 value)
  | `Assoc fields ->
    (match List.assoc_opt "state" fields with
     | Some (`String "missing") ->
       Error "config_revision.manifest missing state has unexpected fields"
     | Some (`String "sha256") ->
       Error "config_revision.manifest sha256 state requires only a lowercase SHA-256 value"
     | Some (`String state) ->
       Error (Printf.sprintf "unsupported config_revision.manifest.state: %S" state)
     | Some _ -> Error "config_revision.manifest.state must be a string"
     | None -> Error "config_revision.manifest.state is required")
  | _ -> Error "config_revision.manifest must be an object"

let config_revision_to_yojson (revision : config_revision) =
  `Assoc
    [ "manifest", revision_to_yojson revision.manifest
    ; ( "runtime_assignment"
      , Runtime.keeper_assignment_revision_to_yojson revision.runtime_assignment )
    ]
;;

let config_revision_of_yojson = function
  | `Assoc fields when List.length fields = 2 ->
    let ( let* ) = Result.bind in
    let* manifest =
      match List.assoc_opt "manifest" fields with
      | Some value -> revision_of_yojson value
      | None -> Error "expected_config_revision.manifest is required"
    in
    let* runtime_assignment =
      match List.assoc_opt "runtime_assignment" fields with
      | Some value -> Runtime.keeper_assignment_revision_of_yojson value
      | None -> Error "expected_config_revision.runtime_assignment is required"
    in
    Ok ({ manifest; runtime_assignment } : config_revision)
  | `Assoc _ -> Error "expected_config_revision has unexpected fields"
  | _ -> Error "expected_config_revision must be an object"
;;

let revision_display = function
  | Missing -> "missing"
  | Sha256 value -> "sha256:" ^ value

let error_to_string = function
  | Io_error detail -> detail
  | Revision_conflict { expected; observed } ->
    Printf.sprintf
      "keeper config revision conflict (expected %s, observed %s)"
      (Yojson.Safe.to_string (config_revision_to_yojson expected))
      (Yojson.Safe.to_string (config_revision_to_yojson observed))
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
  | Composite_reconciliation_required { manifest; runtime_assignment } ->
    let manifest_detail =
      match manifest with
      | None -> []
      | Some state ->
        [ Printf.sprintf "manifest path %s: %s" state.path state.detail ]
    in
    let runtime_detail =
      match runtime_assignment with
      | None -> []
      | Some state ->
        [ Printf.sprintf
            "runtime path %s: %s"
            (Option.value ~default:"unavailable" state.path)
            state.detail
        ]
    in
    "keeper config requires composite reconciliation ("
    ^ String.concat "; " (manifest_detail @ runtime_detail)
    ^ ")"
  | Publication_exception { path; detail } ->
    Printf.sprintf "keeper manifest publication raised (path %s): %s" path detail

let warning_to_yojson = function
  | Manifest_parent_sync_unconfirmed detail ->
    `Assoc
      [ "code", `String "keeper_manifest_parent_sync_unconfirmed"
      ; "detail", `String detail
      ]
  | Runtime_config_parent_sync_unconfirmed detail ->
    `Assoc
      [ "code", `String "runtime_config_parent_sync_unconfirmed"
      ; "detail", `String detail
      ]
  | Lock_release_unconfirmed detail ->
    `Assoc
      [ "code", `String "keeper_manifest_lock_release_unconfirmed"
      ; "detail", `String detail
      ]
  | Runtime_config_lock_release_unconfirmed detail ->
    `Assoc
      [ "code", `String "runtime_config_lock_release_unconfirmed"
      ; "detail", `String detail
      ]

let warnings_of_runtime_assignment_write = function
  | Runtime.Assignment_unchanged _ -> []
  | Runtime.Assignment_committed { receipt; _ } ->
    (match receipt.Runtime.durability with
     | Runtime.Durable -> []
     | Runtime.Durability_unconfirmed { detail } ->
       [ Runtime_config_parent_sync_unconfirmed detail ])

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
       with
       (* The rollback did not fail; it was stopped. Reporting it as a
          reconciliation the operator must perform sends them after a manifest
          that may still be exactly where the next attempt expects it. *)
       | Eio.Cancel.Cancelled _ as error -> raise error
       | exn ->
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

let validate_keeper_name keeper_name =
  if Keeper_config.validate_name keeper_name
  then Ok ()
  else Error (Printf.sprintf "invalid keeper name: %S" keeper_name)

let with_manifest_lock_using observe path f =
  Printf.printf "DIAG14 manifest-lock-enter %s\n%!" path;
  Fs_compat.mkdir_p (Filename.dirname path);
  let lock_path = path ^ ".lock" in
  let r = observe ~lock_path f in
  Printf.printf "DIAG14 manifest-lock-exit\n%!";
  match r with
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

let runtime_lock_warning = function
  | Runtime.Config_lock_release_unconfirmed detail ->
    Runtime_config_lock_release_unconfirmed detail
;;

let with_current_config_revision ~config ~keeper_name project =
  let ( let* ) = Result.bind in
  let* () = validate_keeper_name keeper_name in
  let path = manifest_path ~config ~keeper_name in
  match
    with_manifest_lock path (fun () ->
      let ( let* ) = Result.bind in
      let* manifest = revision_of_path_unlocked path in
      let runtime_config_path =
        Config_dir_resolver.runtime_toml_path_for_base_path
          ~base_path:config.base_path
      in
      let* runtime =
        Runtime.observe_keeper_assignment ~runtime_config_path ~keeper_name ()
      in
      Ok
        ( project
            ({ manifest; runtime_assignment = runtime.value } : config_revision)
        , List.map runtime_lock_warning runtime.warnings ))
  with
  | Error _ as error -> error
  | Ok { value = Error detail; _ } -> Error detail
  | Ok { value = Ok (value, runtime_warnings); warnings } ->
    Ok { value; warnings = warnings @ runtime_warnings }

let current_config_revision ~config ~keeper_name =
  with_current_config_revision ~config ~keeper_name Fun.id
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
    match
      if parsed.remote_endpoint_present
      then parsed.remote_endpoint_opt
      else parsed.profile_defaults.remote_endpoint
    with
    | Some endpoint ->
      ("remote_endpoint", Keeper_toml_loader.Toml_string endpoint) :: fields
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
  (* RFC-0403. Carried straight from the profile: this axis has no
     [masc_keeper_up] argument, so the file is its only source. Leaving it out
     of this list would delete an operator's selection the next time anything
     called keeper_up on this Keeper, with nothing said. *)
  let fields =
    match parsed.profile_defaults.attached_tool_allow with
    | Some names ->
      ("tools.attached_allow", Keeper_toml_loader.Toml_string_array names) :: fields
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
  fields

let explicit_edits
      (parsed : Keeper_turn_up_args.parsed_args)
  =
  []
  |> append_optional "instructions" set_string parsed.instructions_arg
  |> append_optional "sandbox_profile" set_string parsed.sandbox_profile_opt
  |> append_optional "network_mode" set_string parsed.network_mode_opt
  |> append_optional "mention_targets" set_strings parsed.mention_targets_opt
  |> append_optional "proactive_enabled" set_bool parsed.proactive_enabled_opt
  |> append_optional "autoboot_enabled" set_bool parsed.autoboot_enabled_opt
  |> fun fields ->
  (if not parsed.remote_endpoint_present
   then fields
   else
     ( "remote_endpoint"
     , match parsed.remote_endpoint_opt with
       | Some endpoint -> set_string endpoint
       | None -> Keeper_toml_loader.Remove )
     :: fields)
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

let persist_with_publication_using ~with_lock ~restore_snapshot ~restore_runtime
    ~read_revision
    ~expected_revision ~(config : Workspace.config)
    ~(parsed : Keeper_turn_up_args.parsed_args) ~(meta : keeper_meta) ~publish () =
  let path = manifest_path ~config ~keeper_name:meta.name in
  let instructions_result =
    if String.trim meta.instructions = ""
    then Error "keeper instructions are required"
    else Ok ()
  in
  let transaction () =
    Printf.printf "DIAG14 tx-enter\n%!";
    match with_lock path (fun () ->
    Printf.printf "DIAG14 tx-inside-manifest-lock\n%!";
    match
      Runtime.with_keeper_assignment_transaction
        ~runtime_config_path:
          (Config_dir_resolver.runtime_toml_path_for_base_path
             ~base_path:config.base_path)
        ~keeper_name:meta.name
        (fun runtime_transaction ->
      Printf.printf "DIAG14 tx-inside-runtime-transaction\n%!";
      let ( let* ) = Result.bind in
      let* () = instructions_result |> Result.map_error (fun error -> Io_error error) in
      let* snapshot =
        read_snapshot_unlocked path |> Result.map_error (fun error -> Io_error error)
      in
      let observed_manifest = revision_of_snapshot snapshot in
      let observed : config_revision =
        { manifest = observed_manifest
        ; runtime_assignment =
            Runtime.keeper_assignment_revision runtime_transaction
        }
      in
      let* () =
        if expected_revision <> observed
        then Error (Revision_conflict { expected = expected_revision; observed })
        else Ok ()
      in
      let created = observed_manifest = Missing in
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
      let restore_publication_state () =
        Keeper_types_profile.invalidate_keeper_profile_defaults_cache meta.name;
        let runtime_restore =
          match restore_runtime runtime_transaction with
          | Ok
              (Runtime.Assignment_committed
                { receipt = { durability = Runtime.Durability_unconfirmed { detail }; _ }
                ; _
                }) ->
            Error ("runtime assignment restore durability unconfirmed: " ^ detail)
          | Ok _ -> Ok ()
          | Error detail -> Error detail
        in
        let manifest_restore = restore_snapshot path snapshot in
        match manifest_restore, runtime_restore with
        | Ok (), Ok _ -> Ok ()
        | manifest_result, runtime_result ->
          let manifest =
            match manifest_result with
            | Ok () -> None
            | Error (Reconciliation_required state) -> Some state
            | Error error ->
              Some
                { path
                ; detail = error_to_string error
                ; observed = observed_revision_after_failure path
                }
          in
          let runtime_assignment =
            match runtime_result with
            | Ok _ -> None
            | Error detail ->
              Some
                { path = Runtime.keeper_assignment_transaction_path runtime_transaction
                ; detail
                }
          in
          Error
            (Composite_reconciliation_required { manifest; runtime_assignment })
      in
      let rollback error =
        match restore_publication_state () with
        | Ok () -> Error error
        | Error reconciliation -> Error reconciliation
      in
      (match read_revision path with
       | Error detail ->
         rollback
           (Io_error
              (Printf.sprintf
                 "cannot read keeper manifest revision after replacement: %s"
                 detail))
       | Ok revision ->
         let outcome = { path; created; revision } in
         let publication =
           match publish runtime_transaction outcome with
           | decision -> Ok decision
           | exception (Eio.Cancel.Cancelled _ as exn) ->
             let backtrace = Printexc.get_raw_backtrace () in
             (match rollback (Io_error "publication cancelled") with
              | Error
                  ((Reconciliation_required _ | Composite_reconciliation_required _)
                    as error) ->
                Log.Keeper.error
                  "keeper manifest rollback failed during cancellation: %s"
                  (error_to_string error)
              | Error _ | Ok _ -> ());
             Printexc.raise_with_backtrace exn backtrace
           | exception exn ->
             let backtrace = Printexc.get_raw_backtrace () in
             Error
               (Publication_exception
                  { path
                  ; detail =
                      Printexc.to_string exn
                      ^ "\n"
                      ^ Printexc.raw_backtrace_to_string backtrace
                  })
         in
         (match publication with
          | Error error -> rollback error
          | Ok (Commit value) ->
            Keeper_types_profile.invalidate_keeper_profile_defaults_cache meta.name;
            Ok { value; warnings = write_warnings }
          | Ok (Commit_with_warnings (value, publication_warnings)) ->
            Keeper_types_profile.invalidate_keeper_profile_defaults_cache meta.name;
            Ok
              { value
              ; warnings = write_warnings @ publication_warnings
              }
          | Ok (Rollback value) ->
            let* () = restore_publication_state () in
            Ok { value; warnings = [] })))
    with
    | Error detail -> Error (Io_error detail)
    | Ok { value = Error error; _ } -> Error error
    | Ok { value = Ok receipt; warnings } ->
      Ok
        { receipt with
          warnings = receipt.warnings @ List.map runtime_lock_warning warnings
        })
  with
  | Error error -> Error (Io_error error)
  | Ok { value = Error error; _ } -> Error error
  | Ok
      { value = Ok { value; warnings = write_warnings }
      ; warnings = lock_warnings
      } ->
    Ok { value; warnings = write_warnings @ lock_warnings }
  in
  match validate_keeper_name meta.name with
  | Error detail -> Error (Io_error detail)
  | Ok () -> transaction ()

let persist_with_publication ~expected_revision ~config ~parsed ~meta ~publish () =
  persist_with_publication_using
    ~with_lock:with_manifest_lock
    ~restore_snapshot:restore_snapshot_unlocked
    ~restore_runtime:Runtime.restore_keeper_assignment_transaction
    ~read_revision:revision_of_path_unlocked
    ~expected_revision
    ~config
    ~parsed
    ~meta
    ~publish
    ()

let persist ~expected_revision ~config ~parsed ~meta () =
  persist_with_publication ~expected_revision ~config ~parsed ~meta
    ~publish:(fun _runtime_transaction outcome -> Commit outcome) ()

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
      ~restore_runtime:Runtime.restore_keeper_assignment_transaction
      ~read_revision:revision_of_path_unlocked
      ~expected_revision
      ~config
      ~parsed
      ~meta
      ~publish:(fun _runtime_transaction outcome -> Commit outcome)
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
      ~restore_runtime:Runtime.restore_keeper_assignment_transaction
      ~read_revision:revision_of_path_unlocked
      ~expected_revision
      ~config
      ~parsed
      ~meta
      ~publish:(fun _runtime_transaction _ -> Rollback ())
      ()
  ;;

  let persist_with_post_write_revision_failure ~expected_revision ~config
      ~parsed ~meta () =
    persist_with_publication_using
      ~with_lock:with_manifest_lock
      ~restore_snapshot:restore_snapshot_unlocked
      ~restore_runtime:Runtime.restore_keeper_assignment_transaction
      ~read_revision:(fun _ -> Error "injected post-write revision read failure")
      ~expected_revision
      ~config
      ~parsed
      ~meta
      ~publish:(fun _runtime_transaction outcome -> Commit outcome)
      ()
  ;;

  let persist_with_runtime_restore_replace_file ~replace_file
      ~expected_revision ~config ~parsed ~meta ~publish () =
    persist_with_publication_using
      ~with_lock:with_manifest_lock
      ~restore_snapshot:restore_snapshot_unlocked
      ~restore_runtime:
        (Runtime.Assignment_for_testing.restore_with_replace_file ~replace_file)
      ~read_revision:revision_of_path_unlocked
      ~expected_revision
      ~config
      ~parsed
      ~meta
      ~publish
      ()
  ;;
end
