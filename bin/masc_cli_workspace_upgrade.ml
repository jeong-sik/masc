module Upgrade = Released_workspace_upgrade
type action = Inspect | Apply of { keeper_name : string; source_sha256 : string }
  | Restore of { backup_id : string }
  | Inspect_journal of string
  | Prepare_journal of { keeper_name : string; source_sha256 : string }
  | Inspect_journal_bundle of string
  | Inspect_journal_input of { bundle_id : string; trace_id : string }
  | Adopt_journal_input of { bundle_id : string; trace_id : string; checkpoint_sha256 : string }
  | Inspect_journal_adoption of string
  | Assess_journal_installation of string
  | Install_journal of { adoption_id : string; source_sha256 : string; adopted_sha256 : string }
  | Inspect_journal_installation of string
  | List_journal_installations
  | Restore_journal_installation of string
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
  | Ok (None) | Error _ | Ok (Some _) -> Error "The configuration must be an owned regular file."
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
let journal base_path action =
  let module Journal = Keeper_journal_preparation in
  let result = match action with
    | Inspect_journal keeper_name -> Journal.assess ~base_path ~keeper_name |> Result.map Journal.plan_to_json
    | Prepare_journal {keeper_name;source_sha256} ->
      let* plan = Journal.assess ~base_path ~keeper_name in
      if Journal.source_sha256 plan <> source_sha256 then
        Error {Journal.bundle_id=None;failure=Source_changed}
      else let* outcome = Journal.prepare ~run_dir:(Host_config.host ()).base_path_lease_dir plan in
        let receipt,confirmed = match outcome with
          | Journal.Published receipt -> receipt,true
          | Publication_unconfirmed receipt -> receipt,false in
        Ok (`Assoc ["schema",`String "masc.keeper_journal_publication.v1";
          "bundle",Journal.receipt_to_json receipt;"durability_confirmed",`Bool confirmed;
          "ready_to_install",`Bool false])
    | Inspect_journal_bundle bundle_id ->
      Journal.load_recovery ~base_path ~bundle_id |> Result.map (fun receipt ->
        `Assoc ["schema",`String "masc.keeper_journal_bundle_observation.v1";
          "bundle",Journal.receipt_to_json receipt;"read_only",`Bool true;
          "ready_to_install",`Bool false])
    | Inspect_journal_input {bundle_id;trace_id} ->
      Journal.assess_input ~base_path ~bundle_id ~trace_id |> Result.map Journal.input_plan_to_json
    | Adopt_journal_input {bundle_id;trace_id;checkpoint_sha256} ->
      let* plan = Journal.assess_input ~base_path ~bundle_id ~trace_id in
      let* outcome = Journal.adopt_input ~run_dir:(Host_config.host ()).base_path_lease_dir
        ~expected_checkpoint_sha256:checkpoint_sha256 plan in
      let receipt,confirmed = match outcome with
        | Journal.Input_adopted receipt -> receipt,true
        | Input_adoption_unconfirmed receipt -> receipt,false in
      Ok (`Assoc ["schema",`String "masc.keeper_journal_input_publication.v1";
        "adoption",Journal.input_adoption_to_json receipt;
        "durability_confirmed",`Bool confirmed;"ready_to_install",`Bool false])
    | Inspect_journal_adoption adoption_id ->
      Journal.load_input_adoption ~base_path ~adoption_id |> Result.map (fun receipt ->
        `Assoc ["schema",`String "masc.keeper_journal_input_observation.v1";
          "adoption",Journal.input_adoption_to_json receipt;
          "read_only",`Bool true;"ready_to_install",`Bool false])
    | Assess_journal_installation adoption_id ->
      Journal.assess_installation ~base_path ~adoption_id |> Result.map Journal.installation_plan_to_json
    | Install_journal {adoption_id;source_sha256;adopted_sha256} ->
      let* plan = Journal.assess_installation ~base_path ~adoption_id in
      let* result = Journal.install ~run_dir:(Host_config.host ()).base_path_lease_dir
        ~expected_source_sha256:source_sha256 ~expected_adopted_sha256:adopted_sha256 plan in
      let record,confirmed = match result with
        | Journal.Replaced record -> record,true | Replacement_unconfirmed record -> record,false in
      Ok (`Assoc ["schema",`String "masc.keeper_journal_installed.v1";
        "installed",`Bool true;"durability_confirmed",`Bool confirmed;
        "record",Journal.installation_record_to_json record])
    | Inspect_journal_installation installation_id ->
      let* record,observed = Journal.inspect_installation ~base_path ~installation_id in
      Ok (`Assoc ["schema",`String "masc.keeper_journal_installation_observation.v1";
        "record",Journal.installation_record_to_json record;
        "journal",`String (Journal.installed_journal_to_string observed);
        "read_only",`Bool true;"snapshot_only",`Bool true])
    | List_journal_installations ->
      let* entries = Journal.list_installations ~base_path in
      let entries = List.map (fun (id,result) -> match result with
        | Ok (record,observed) -> `Assoc ["installation_id",`String id;
            "record",Journal.installation_record_to_json record;
            "journal",`String (Journal.installed_journal_to_string observed)]
        | Error cause -> `Assoc ["installation_id",`String id;"error",`String (Journal.error_message cause)]) entries in
      Ok (`Assoc ["schema",`String "masc.keeper_journal_installations.v1";
        "entries",`List entries;"read_only",`Bool true;"snapshot_only",`Bool true])
    | Restore_journal_installation installation_id ->
      let* record = Journal.load_installation ~base_path ~installation_id in
      let* result = Journal.restore_installation ~run_dir:(Host_config.host ()).base_path_lease_dir record in
      let record,confirmed = match result with
        | Journal.Replaced record -> record,true | Replacement_unconfirmed record -> record,false in
      Ok (`Assoc ["schema",`String "masc.keeper_journal_restored.v1";
        "restored",`Bool true;"durability_confirmed",`Bool confirmed;
        "record",Journal.installation_record_to_json record])
    | Inspect | Apply _ | Restore _ -> Error {Journal.bundle_id=None;failure=Invalid_bundle} in
  Result.map_error Journal.error_message result
let run ~base_path ~action =
  let result = try
    let base_path = Unix.realpath (Env_config.normalize_masc_base_path_input base_path) in
    match action with Inspect -> inspect base_path
    | Apply {keeper_name; source_sha256} -> apply base_path keeper_name source_sha256
    | Restore {backup_id} -> restore base_path backup_id
    | (Inspect_journal _ | Prepare_journal _ | Inspect_journal_bundle _
       | Inspect_journal_input _ | Adopt_journal_input _ | Inspect_journal_adoption _
       | Assess_journal_installation _ | Install_journal _ | Inspect_journal_installation _
       | Restore_journal_installation _ | List_journal_installations) as action -> journal base_path action
    with Unix.Unix_error _ | Sys_error _ -> Error "The selected workspace cannot be read. No upgrade was completed." in
  match result with Ok value -> emit value; 0
  | Error message -> emit (`Assoc ["schema", `String "masc.workspace_upgrade_error.v1";
    "error", `String message]); 1
