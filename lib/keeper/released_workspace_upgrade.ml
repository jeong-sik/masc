let ( let* ) = Result.bind
let digest text = Digestif.SHA256.(digest_string text |> to_hex)

type plan =
  { path : string
  ; original : string
  ; updated : string
  ; mode : Keeper_activation_mode.t
  }

type assessment =
  | Compatible
  | Upgrade_available of plan
  | Manual_repair_required

let assess_keeper ~path original =
  match Keeper_types_profile.materialization_defaults_of_content ~path original with
  | Ok _ -> Compatible
  | Error _ ->
    let open Keeper_toml_loader in
    let converted =
      let* doc = parse_toml original in
      let* mode =
        match
          ( List.assoc_opt "keeper.autoboot_enabled" doc
          , List.assoc_opt "keeper.proactive_enabled" doc
          , List.assoc_opt "keeper.activation_mode" doc )
        with
        | Some (Toml_bool false), Some (Toml_bool false), None ->
          Ok Keeper_activation_mode.Manual
        | Some (Toml_bool true), Some (Toml_bool false), None ->
          Ok Keeper_activation_mode.On_demand
        | Some (Toml_bool true), Some (Toml_bool true), None ->
          Ok Keeper_activation_mode.Autonomous
        | _ -> Error "activation values have no unambiguous released mapping"
      in
      let* updated =
        edit_keeper_fields_in_content
          original
          [ "autoboot_enabled", Remove
          ; "proactive_enabled", Remove
          ; "activation_mode", Set (Toml_string (Keeper_activation_mode.to_string mode))
          ]
      in
      let* _ =
        Keeper_types_profile.materialization_defaults_of_content ~path updated
        |> Result.map_error (fun _ -> "other unsupported configuration")
      in
      let* after = parse_toml updated in
      let unrelated doc =
        List.filter
          (fun (key, _) ->
             not
               (List.mem
                  key
                  [ "keeper.autoboot_enabled"
                  ; "keeper.proactive_enabled"
                  ; "keeper.activation_mode"
                  ]))
          doc
        |> List.sort compare
      in
      if unrelated doc <> unrelated after
      then Error "unrelated fields changed"
      else Ok { path; original; updated; mode }
    in
    (match converted with
     | Ok plan -> Upgrade_available plan
     | Error _ -> Manual_repair_required)
;;

let source_sha256 plan = digest plan.original
let plan_to_json plan =
  `Assoc
    [ "schema", `String "masc.keeper_upgrade.v1"
    ; "source_schema", `String "v0.34.0_explicit_activation_booleans"
    ; "path", `String plan.path
    ; "source_sha256", `String (source_sha256 plan)
    ; "result_sha256", `String (digest plan.updated)
    ; "activation_mode", Keeper_activation_mode.to_yojson plan.mode
    ]
;;

type receipt =
  { plan : plan
  ; base_path : string
  ; backup_path : string
  ; durability_confirmed : bool
  ; lock_release_confirmed : bool
  }

type error =
  | Workspace_in_use
  | Unsafe_path
  | Source_changed
  | Backup_failed
  | Replacement_failed

let error_message = function
  | Workspace_in_use ->
    "Stop the workspace server before applying or restoring this upgrade."
  | Unsafe_path ->
    "The workspace or configuration path cannot be safely opened. No upgrade was applied."
  | Source_changed ->
    "The configuration changed since assessment. Assess it again before proceeding."
  | Backup_failed ->
    "The original configuration could not be backed up durably. It was not replaced."
  | Replacement_failed ->
    "The configuration replacement failed. Its original backup remains available."
;;

let receipt_to_json receipt =
  `Assoc
    [ "schema", `String "masc.keeper_upgrade_receipt.v1"
    ; "plan", plan_to_json receipt.plan
    ; "base_path", `String receipt.base_path
    ; "backup_path", `String receipt.backup_path
    ; "durability_confirmed", `Bool receipt.durability_confirmed
    ; "lock_release_confirmed", `Bool receipt.lock_release_confirmed
    ]
;;

(* Called in a blocking worker: the server lease stays owned across every
   filesystem operation and is released on exceptions as well as typed errors. *)
let with_workspace ~run_dir ~base_path f =
  try
    let base_path = Unix.realpath base_path in
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Base_path_already_owned _ -> Error Workspace_in_use
    | Base_path_rejected _ -> Error Unsafe_path
    | Base_path_acquired lease ->
      Fun.protect
        ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
        (fun () -> f base_path)
  with
  | Unix.Unix_error _ | Sys_error _ -> Error Unsafe_path
;;

let blocking f =
  match Eio_context.get_switch_opt () with
  | Some _ -> Eio_unix.run_in_systhread f
  | None -> f ()
;;

let read_plan_file ~base_path plan =
  let root = Filename.concat base_path Common.masc_dirname in
  let expected_parent = Filename.concat root "config/keepers" in
  if Filename.is_relative plan.path || Filename.dirname plan.path <> expected_parent
  then Error Unsafe_path
  else (
    match
      Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:root plan.path
    with
    | Ok (Some current) when current.snapshot.owner_uid = Unix.geteuid () -> Ok current
    | Ok None | Ok (Some _) | Error _ -> Error Unsafe_path)
;;

let write ~mode path content =
  Fs_compat.write_file_atomic_strict_staged path ~write:(fun out ->
    Unix.fchmod (Unix.descr_of_out_channel out) mode;
    output_string out content)
;;

let private_directory path =
  (try Unix.mkdir path 0o700 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let stat = Unix.lstat path in
  if
    stat.st_kind <> Unix.S_DIR
    || stat.st_uid <> Unix.geteuid ()
    || stat.st_perm land 0o077 <> 0
  then Error Unsafe_path
  else Ok ()
;;

let sync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
;;

let with_manifest_lock path ~unconfirmed f =
  match File_lock_eio.with_durable_lock_observed ~lock_path:(path ^ ".lock") f with
  | Lock_not_acquired _ -> Error Unsafe_path
  | Body_completed { value; release_error = None } -> value
  | Body_completed { value; release_error = Some _ } -> Result.map unconfirmed value
;;

let apply ~run_dir ~base_path plan =
  blocking (fun () ->
    with_workspace ~run_dir ~base_path (fun base_path ->
      let* _ = read_plan_file ~base_path plan in
      with_manifest_lock
        plan.path
        ~unconfirmed:(fun receipt -> { receipt with lock_release_confirmed = false })
        (fun () ->
           let* current = read_plan_file ~base_path plan in
           if current.content <> plan.original
           then Error Source_changed
           else (
             let directory =
               Filename.concat (Filename.concat base_path Common.masc_dirname) "upgrades"
             in
             let* () = private_directory directory in
             sync_directory (Filename.dirname directory);
             let transaction = Filename.concat directory (Random_id.hex ~bytes:16) in
             Unix.mkdir transaction 0o700;
             sync_directory directory;
             let backup_path = Filename.concat transaction "original.toml" in
             match write ~mode:0o600 backup_path plan.original with
             | Error _ -> Error Backup_failed
             | Ok () ->
               let manifest = Yojson.Safe.to_string (plan_to_json plan) in
               (match
                  write ~mode:0o600 (Filename.concat transaction "manifest.json") manifest
                with
                | Error _ -> Error Backup_failed
                | Ok () ->
                  (* Re-read after backup; external configuration editors do not own the
           server lease. A detected change must never be overwritten. *)
                  let* after = read_plan_file ~base_path plan in
                  if
                    (not
                       (Fs_compat.equal_owned_regular_file_snapshot
                          current.snapshot
                          after.snapshot))
                    || after.content <> plan.original
                  then Error Source_changed
                  else (
                    match
                      write ~mode:current.snapshot.permissions plan.path plan.updated
                    with
                    | Ok () ->
                      Ok
                        { plan
                        ; base_path
                        ; backup_path
                        ; durability_confirmed = true
                        ; lock_release_confirmed = true
                        }
                    | Error { stage = Fs_compat.After_rename; _ } ->
                      Ok
                        { plan
                        ; base_path
                        ; backup_path
                        ; durability_confirmed = false
                        ; lock_release_confirmed = true
                        }
                    | Error { stage = Fs_compat.Before_rename; _ } ->
                      Error Replacement_failed))))))
;;

type restoration =
  { durability_confirmed : bool
  ; lock_release_confirmed : bool
  }

let restore_using ~write ~run_dir ~base_path receipt =
  blocking (fun () ->
    with_workspace ~run_dir ~base_path (fun base_path ->
      if base_path <> receipt.base_path
      then Error Unsafe_path
      else
        let* _ = read_plan_file ~base_path receipt.plan in
        with_manifest_lock
          receipt.plan.path
          ~unconfirmed:(fun restored -> { restored with lock_release_confirmed = false })
          (fun () ->
             let* current = read_plan_file ~base_path receipt.plan in
             if current.content <> receipt.plan.updated
             then Error Source_changed
             else (
               match
                 Fs_compat.load_owned_regular_file
                   ~ownership_root:(Filename.concat base_path Common.masc_dirname)
                   receipt.backup_path
               with
               | Ok (Some original) when original = receipt.plan.original ->
                 let* after = read_plan_file ~base_path receipt.plan in
                 if
                   (not
                      (Fs_compat.equal_owned_regular_file_snapshot
                         current.snapshot
                         after.snapshot))
                   || after.content <> receipt.plan.updated
                 then Error Source_changed
                 else (
                   match
                     write ~mode:current.snapshot.permissions receipt.plan.path original
                   with
                   | Ok () ->
                     Ok { durability_confirmed = true; lock_release_confirmed = true }
                   | Error { stage = Fs_compat.After_rename; _ } ->
                     Ok { durability_confirmed = false; lock_release_confirmed = true }
                   | Error { stage = Fs_compat.Before_rename; _ } ->
                     Error Replacement_failed)
               | Ok _ | Error _ -> Error Backup_failed))))
;;

let restore ~run_dir ~base_path receipt = restore_using ~write ~run_dir ~base_path receipt

module For_testing = struct
  let restore_with_parent_sync ~sync_parent ~run_dir ~base_path receipt =
    let write ~mode path content =
      Fs_compat.Atomic_replace_for_testing.write_file_atomic_strict_staged
        ~sync_parent
        path
        ~write:(fun out ->
          Unix.fchmod (Unix.descr_of_out_channel out) mode;
          output_string out content)
    in
    restore_using ~write ~run_dir ~base_path receipt
  ;;
end

let load_recovery ~base_path ~backup_id =
  blocking (fun () ->
    if
      String.length backup_id <> 32
      || not
           (String.for_all
              (function
                | '0' .. '9' | 'a' .. 'f' -> true
                | _ -> false)
              backup_id)
    then Error Unsafe_path
    else (
      try
        let base_path = Unix.realpath base_path in
        let root = Filename.concat base_path Common.masc_dirname in
        let directory = Filename.concat (Filename.concat root "upgrades") backup_id in
        let backup_path = Filename.concat directory "original.toml" in
        let read path =
          match
            Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:root path
          with
          | Ok (Some file)
            when file.snapshot.owner_uid = Unix.geteuid ()
                 && file.snapshot.permissions land 0o077 = 0 -> Ok file.content
          | Ok _ | Error _ -> Error Backup_failed
        in
        let* original = read backup_path in
        let* manifest = read (Filename.concat directory "manifest.json") in
        let json = Yojson.Safe.from_string manifest in
        let* path =
          match json with
          | `Assoc fields ->
            (match List.assoc_opt "path" fields with
             | Some (`String path) -> Ok path
             | _ -> Error Backup_failed)
          | _ -> Error Backup_failed
        in
        match assess_keeper ~path original with
        | Compatible | Manual_repair_required -> Error Backup_failed
        | Upgrade_available plan ->
          if
            plan_to_json plan <> json
            || Filename.dirname path <> Filename.concat root "config/keepers"
          then Error Backup_failed
          else
            Ok
              { plan
              ; base_path
              ; backup_path
              ; durability_confirmed = false
              ; lock_release_confirmed = true
              }
      with
      | Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _ -> Error Backup_failed))
;;
