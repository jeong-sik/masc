module Upgrade = Released_workspace_upgrade
type action = Inspect | Apply of { keeper_name : string; source_sha256 : string }
  | Restore of { backup_id : string }
let ( let* ) = Result.bind
let root base_path = Filename.concat base_path Common.masc_dirname
let directory base_path = Filename.concat (root base_path) "config/keepers"
let names path = try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare)
  with Sys_error _ ->
    if Sys.file_exists path then Error "The workspace directory cannot be read."
    else Ok []
let read base_path path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:(root base_path) path with
  | Ok (Some snapshot) when snapshot.snapshot.owner_uid = Unix.geteuid () -> Ok snapshot.content
  | _ -> Error "The configuration must be an owned regular file."
let emit json = print_endline (Yojson.Safe.to_string json)
let inspect base_path =
  let* files = names (directory base_path) in
  let keepers = files |> List.filter (fun name -> Filename.check_suffix name ".toml")
    |> List.map (fun name ->
      let path = Filename.concat (directory base_path) name in
      let status, plan = match read base_path path with
        | Error _ -> "unreadable", `Null
        | Ok content -> (match Upgrade.assess_keeper ~path content with
          | Compatible -> "compatible", `Null
          | Manual_repair_required -> "manual_repair_required", `Null
          | Upgrade_available plan -> "upgrade_available", Upgrade.plan_to_json plan) in
      `Assoc ["keeper_name", `String (Filename.remove_extension name);
              "status", `String status; "plan", plan]) in
  let* backups = names (Filename.concat (root base_path) "upgrades") in
  let backups = List.filter_map (fun backup_id ->
    match Upgrade.load_recovery ~base_path ~backup_id with
    | Error _ -> None
    | Ok receipt -> Some (`Assoc ["backup_id", `String backup_id;
      "receipt", Upgrade.receipt_to_json receipt])) backups in
  Ok (`Assoc ["schema", `String "masc.workspace_upgrades.v1";
    "read_only", `Bool true; "keepers", `List keepers; "backups", `List backups])
let apply base_path keeper_name source_sha256 =
  let* () = if Masc.Keeper_config.validate_name keeper_name then Ok ()
    else Error (Masc.Keeper_config.invalid_name_error keeper_name) in
  let path = Filename.concat (directory base_path) (keeper_name ^ ".toml") in
  let* content = read base_path path in
  match Upgrade.assess_keeper ~path content with
  | Compatible -> Error "This Keeper already uses the current configuration. Refresh setup."
  | Manual_repair_required -> Error "This configuration has no verified automatic upgrade. Keep its original version or review it manually."
  | Upgrade_available plan ->
    if not (String.equal (Upgrade.source_sha256 plan) source_sha256) then
      Error "This configuration changed after you reviewed it. Refresh setup before upgrading."
    else Upgrade.apply ~run_dir:(Host_config.host ()).base_path_lease_dir ~base_path plan
      |> Result.map Upgrade.receipt_to_json |> Result.map_error Upgrade.error_message
let restore base_path backup_id =
  let* receipt = Upgrade.load_recovery ~base_path ~backup_id |> Result.map_error Upgrade.error_message in
  let* result = Upgrade.restore ~run_dir:(Host_config.host ()).base_path_lease_dir ~base_path receipt
    |> Result.map_error Upgrade.error_message in
  Ok (`Assoc ["schema", `String "masc.workspace_restore.v1";
    "restored", `Bool true; "backup_id", `String backup_id;
    "durability_confirmed", `Bool result.durability_confirmed;
    "lock_release_confirmed", `Bool result.lock_release_confirmed])
let run ~base_path ~action =
  let result = try
    let base_path = Unix.realpath (Env_config.normalize_masc_base_path_input base_path) in
    match action with Inspect -> inspect base_path
    | Apply {keeper_name; source_sha256} -> apply base_path keeper_name source_sha256
    | Restore {backup_id} -> restore base_path backup_id
    with Unix.Unix_error _ | Sys_error _ -> Error "The selected workspace cannot be read. No upgrade was completed." in
  match result with Ok value -> emit value; 0
  | Error message -> emit (`Assoc ["schema", `String "masc.workspace_upgrade_error.v1";
    "error", `String message]); 1
