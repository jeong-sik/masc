open Masc

let rec mkdir_p path =
  if not (Sys.file_exists path) then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_fixture f =
  let base = Filename.temp_file "keeper-build-maintenance-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  let config_dir = Filename.concat base ".masc/config" in
  let keepers = Filename.concat config_dir "keepers" in
  mkdir_p keepers;
  let previous = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect ~finally:(fun () ->
    Unix.putenv "MASC_CONFIG_DIR" (Option.value previous ~default:"");
    Config_dir_resolver.reset ();
    remove_tree base)
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      let config = Workspace.default_config base in
      let profile name contents =
        let path = Filename.concat keepers (name ^ ".toml") in
        Out_channel.with_open_text path (fun out -> output_string out contents)
      in
      let seed ~owner ~payload_name =
        let meta = match Masc_test_deps.meta_of_json_fixture
            (`Assoc ["name", `String payload_name]) with
          | Ok meta -> meta | Error detail -> Alcotest.fail detail in
        let path = Keeper_types_profile.keeper_meta_path config owner in
        mkdir_p (Filename.dirname path);
        Yojson.Safe.to_file path (Keeper_meta_json.meta_to_json meta)
      in
      f config profile seed)

let microvm_profile =
  "[keeper]\ninstructions = \"fixture instructions for keeper build maintenance\"\nsandbox_profile = \"microvm\"\nmicrovm_backend = \"apple_container\"\nsandbox_image = \"fixture-image\"\n"

let test_cleanup_reads_toml_owned_backend () =
  with_fixture (fun config profile seed ->
    profile "cleanup-owner" microvm_profile;
    seed ~owner:"cleanup-owner" ~payload_name:"cleanup-owner";
    (match Keeper_meta_store.read_meta config "cleanup-owner" with
     | Ok (Some raw) -> Alcotest.(check bool) "disk does not own backend" true
                         (Option.is_none raw.microvm_backend)
     | _ -> Alcotest.fail "fixture disk meta missing");
    match Server_keeper_build_maintenance.read_cleanup_meta ~config
            ~keeper_name:"cleanup-owner" with
    | Ok (Some meta) ->
      Alcotest.(check bool) "cleanup resolves declared profile" true
        (meta.sandbox_profile = Keeper_types_profile_sandbox.Micro_vm);
      Alcotest.(check bool) "cleanup resolves declared backend" true
        (meta.microvm_backend = Some Keeper_microvm_backend.Apple_container)
    | _ -> Alcotest.fail "cleanup did not read effective metadata")

let test_cleanup_rejects_other_owner () =
  with_fixture (fun config profile seed ->
    profile "cleanup-owner" microvm_profile;
    profile "other-owner" microvm_profile;
    seed ~owner:"cleanup-owner" ~payload_name:"other-owner";
    match Server_keeper_build_maintenance.read_cleanup_meta ~config
            ~keeper_name:"cleanup-owner" with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "another Keeper was admitted as the cleanup target")

let test_cleanup_rejects_invalid_profile () =
  with_fixture (fun config profile seed ->
    profile "cleanup-owner" "[keeper]\ninstructions = \"fixture instructions\"\nsandbox_profile = \"invalid-profile\"\n";
    seed ~owner:"cleanup-owner" ~payload_name:"cleanup-owner";
    match Server_keeper_build_maintenance.read_cleanup_meta ~config
            ~keeper_name:"cleanup-owner" with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "cleanup accepted an invalid profile")

let () =
  Alcotest.run "Keeper build maintenance admission"
    [ "metadata", [
      Alcotest.test_case "TOML resolves disk placeholders" `Quick test_cleanup_reads_toml_owned_backend;
      Alcotest.test_case "Owner identity must match" `Quick test_cleanup_rejects_other_owner;
      Alcotest.test_case "Profile errors refuse cleanup" `Quick test_cleanup_rejects_invalid_profile;
    ] ]
