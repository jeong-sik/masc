module Declared = Masc.Keeper_microvm_declared_guests
module Inventory = Masc.Keeper_microvm_guest_inventory
module Backend = Masc.Keeper_microvm_backend
module Names = Masc.Keeper_sandbox_container_name
module Runtime = Masc.Keeper_sandbox_runtime
module Labels = Masc.Keeper_sandbox_runtime_setup
module Profile = Keeper_types_profile_sandbox

let write path content = Out_channel.with_open_bin path (fun out -> output_string out content)

let with_fixture use =
  let base_path = Filename.temp_dir "masc-declared-guests-" "" in
  let previous = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect ~finally:(fun () ->
    (match previous with Some value -> Unix.putenv "MASC_CONFIG_DIR" value
     | None -> Unix.unsetenv "MASC_CONFIG_DIR");
    Fs_compat.remove_tree base_path)
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" "declared-config";
      let config_dir = Filename.concat base_path "declared-config" in
      Unix.mkdir config_dir 0o700;
      let directory = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
      Alcotest.(check string) "canonical explicit config override is honored"
        (Filename.concat config_dir "keepers") directory;
      use ~base_path ~directory)
;;

let guest ~base_path keeper_name network_mode =
  Names.make (Names.Micro_vm_persistent {base_path; keeper_name; network_mode}) |> Names.to_string
;;

let row ~base_path ~name ~keeper : Inventory.row =
  {name; scoping_labels = Some
    {component = Labels.sandbox_component_label_value;
     base_path_hash = Runtime.base_path_hash base_path;
     kind = Masc.Keeper_sandbox_microvm.keeper_vm_container_kind; keeper}}
;;

let value = function
  | Ok value -> value
  | Error failure -> Alcotest.fail (Declared.unavailable_message failure)
;;

let expect_preserved expected = function
  | Declared.Preserve actual -> Alcotest.(check bool) "preservation reason" true (expected = actual)
  | Declared.Delete _ -> Alcotest.fail "uncertain or declared guest became a deletion candidate"
;;

let expect_deleted ~name ~keeper = function
  | Declared.Delete candidate ->
    Alcotest.(check string) "candidate retains exact guest name" name candidate.guest_name;
    Alcotest.(check string) "candidate retains actual Keeper label" keeper candidate.keeper_name
  | Declared.Preserve _ -> Alcotest.fail "positively scoped orphan was not nominated"
;;

let apple ?(name = "keeper") ?(network = "none") () = Printf.sprintf
  "[keeper]\nname = %S\nsandbox_profile = \"microvm\"\nsandbox_image = \"base\"\nmicrovm_backend = \"apple_container\"\nnetwork_mode = %S\n" name network
;;

let test_empty_differs_from_missing_unreadable_or_non_directory () =
  with_fixture (fun ~base_path ~directory ->
    let candidate = row ~base_path ~name:(guest ~base_path "orphan" Profile.Network_none) ~keeper:"orphan" in
    let missing = Declared.read ~base_path in
    (match missing with Error _ -> () | Ok _ -> Alcotest.fail "missing roster became empty authority");
    expect_preserved Declared.Roster_unavailable (Declared.select ~base_path ~declarations:missing candidate);
    write directory "not a directory";
    let unreadable = Declared.read ~base_path in
    (match unreadable with Error _ -> () | Ok _ -> Alcotest.fail "non-directory roster became empty authority");
    expect_preserved Declared.Roster_unavailable (Declared.select ~base_path ~declarations:unreadable candidate);
    Unix.unlink directory;
    Unix.mkdir directory 0o700;
    let declarations = Declared.read ~base_path in
    ignore (value declarations);
    expect_deleted ~name:candidate.name ~keeper:"orphan" (Declared.select ~base_path ~declarations candidate);
    Unix.chmod directory 0o777;
    let unsafe = Declared.read ~base_path in
    (match unsafe with Error _ -> () | Ok _ -> Alcotest.fail "writable-by-others roster authorized deletion");
    expect_preserved Declared.Roster_unavailable (Declared.select ~base_path ~declarations:unsafe candidate);
    Unix.chmod directory 0o700)
;;

let test_actual_loaded_name_and_network_determine_preservation () =
  with_fixture (fun ~base_path ~directory ->
    Unix.mkdir directory 0o700;
    write (Filename.concat directory "alias.toml") (apple ~name:"actual-keeper" ~network:"policy" ());
    let declarations = Declared.read ~base_path in
    ignore (value declarations);
    let current = guest ~base_path "actual-keeper" Profile.Network_policy in
    expect_preserved Declared.Declared_guest (Declared.select ~base_path ~declarations
      (row ~base_path ~name:current ~keeper:"actual-keeper"));
    List.iter (fun (keeper, mode) ->
      let name = guest ~base_path keeper mode in
      expect_deleted ~name ~keeper (Declared.select ~base_path ~declarations (row ~base_path ~name ~keeper)))
      ["actual-keeper", Profile.Network_none; "alias", Profile.Network_policy];
    value (Declared.revalidate (value declarations)))
;;

let test_unknown_declaration_names_preserve_otherwise_orphans () =
  with_fixture (fun ~base_path ~directory ->
    Unix.mkdir directory 0o700;
    write (Filename.concat directory "broken.toml") "[keeper\n";
    write (Filename.concat directory "unresolved-stem.toml") "[keeper]\nname = \"unresolved-name\"\n";
    write (Filename.concat directory "missing-image.toml")
      "[keeper]\nsandbox_profile = \"microvm\"\nmicrovm_backend = \"apple_container\"\n";
    let outside = Filename.concat base_path "outside.toml" in
    write outside (apple ~name:"outside-name" ());
    Unix.symlink outside (Filename.concat directory "unreadable.toml");
    let declarations = Declared.read ~base_path in
    ignore (value declarations);
    List.iter (fun keeper ->
      expect_preserved Declared.Invalid_declaration (Declared.select ~base_path ~declarations
        (row ~base_path ~name:(guest ~base_path keeper Profile.Network_none) ~keeper)))
      ["broken"; "unresolved-stem"; "unresolved-name"; "missing-image"; "unreadable"];
    let name = guest ~base_path "other" Profile.Network_none in
    expect_preserved Declared.Invalid_declaration
      (Declared.select ~base_path ~declarations (row ~base_path ~name ~keeper:"other")))
;;

let test_parseable_unresolved_alias_preserves_bound_names_only () =
  with_fixture (fun ~base_path ~directory ->
    Unix.mkdir directory 0o700;
    write (Filename.concat directory "alias.toml")
      "[keeper]\nname = \"actual-keeper\"\nsandbox_profile = \"microvm\"\nmicrovm_backend = \"apple_container\"\n";
    let declarations = Declared.read ~base_path in
    ignore (value declarations);
    List.iter (fun keeper -> expect_preserved Declared.Invalid_declaration
      (Declared.select ~base_path ~declarations
        (row ~base_path ~name:(guest ~base_path keeper Profile.Network_none) ~keeper)))
      ["alias"; "actual-keeper"];
    let name = guest ~base_path "unrelated-orphan" Profile.Network_none in
    expect_deleted ~name ~keeper:"unrelated-orphan" (Declared.select ~base_path ~declarations
      (row ~base_path ~name ~keeper:"unrelated-orphan")))
;;

let test_alias_corruption_or_unreadability_never_forgets_actual_guest () =
  with_fixture (fun ~base_path ~directory ->
    Unix.mkdir directory 0o700;
    let alias = Filename.concat directory "alias.toml" in
    write alias (apple ~name:"actual-keeper" ());
    let actual = row ~base_path ~name:(guest ~base_path "actual-keeper" Profile.Network_none)
        ~keeper:"actual-keeper" in
    let initial = Declared.read ~base_path in
    ignore (value initial);
    expect_preserved Declared.Declared_guest (Declared.select ~base_path ~declarations:initial actual);
    write alias "[keeper\n";
    let corrupted = Declared.read ~base_path in
    ignore (value corrupted);
    expect_preserved Declared.Invalid_declaration (Declared.select ~base_path ~declarations:corrupted actual);
    Unix.unlink alias;
    let outside = Filename.concat base_path "external-alias.toml" in
    write outside (apple ~name:"actual-keeper" ());
    Unix.symlink outside alias;
    let unreadable = Declared.read ~base_path in
    ignore (value unreadable);
    expect_preserved Declared.Invalid_declaration (Declared.select ~base_path ~declarations:unreadable actual);
    Unix.unlink alias;
    write alias (apple ~name:"actual-keeper" ());
    let repaired = Declared.read ~base_path in
    ignore (value repaired);
    expect_preserved Declared.Declared_guest (Declared.select ~base_path ~declarations:repaired actual);
    let name = guest ~base_path "unrelated-orphan" Profile.Network_none in
    expect_deleted ~name ~keeper:"unrelated-orphan" (Declared.select ~base_path ~declarations:repaired
      (row ~base_path ~name ~keeper:"unrelated-orphan")))
;;

let test_roster_root_symlink_is_not_deletion_authority () =
  with_fixture (fun ~base_path ~directory ->
    let target = Filename.concat base_path "external-roster" in
    Unix.mkdir target 0o700;
    Unix.symlink target directory;
    let declarations = Declared.read ~base_path in
    (match declarations with Error _ -> () | Ok _ -> Alcotest.fail "original roster symlink was followed");
    expect_preserved Declared.Roster_unavailable (Declared.select ~base_path ~declarations
      (row ~base_path ~name:"scoped-orphan" ~keeper:"orphan"));
    Alcotest.(check bool) "roster symlink retained" true ((Unix.lstat directory).st_kind = Unix.S_LNK);
    Alcotest.(check (list string)) "external roster is untouched" [] (Sys.readdir target |> Array.to_list))
;;

let test_non_apple_profiles_do_not_keep_old_apple_guests () =
  with_fixture (fun ~base_path ~directory ->
    Unix.mkdir directory 0o700;
    write (Filename.concat directory "docker.toml")
      "[keeper]\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n";
    write (Filename.concat directory "kata.toml")
      "[keeper]\nsandbox_profile = \"microvm\"\nsandbox_image = \"base\"\nmicrovm_backend = \"nerdctl_kata\"\n";
    write (Filename.concat directory "remote.toml")
      "[keeper]\nsandbox_profile = \"remote_ssh\"\nremote_endpoint = \"endpoint\"\n";
    let declarations = Declared.read ~base_path in
    ignore (value declarations);
    List.iter (fun keeper ->
      let name = guest ~base_path keeper Profile.Network_none in
      expect_deleted ~name ~keeper (Declared.select ~base_path ~declarations (row ~base_path ~name ~keeper)))
      ["docker"; "kata"; "remote"])
;;

let test_canonical_host_backend_and_network_defaults () =
  with_fixture (fun ~base_path ~directory ->
    Unix.mkdir directory 0o700;
    write (Filename.concat directory "defaulted.toml")
      "[keeper]\nsandbox_profile = \"microvm\"\nsandbox_image = \"base\"\n";
    let declarations = Declared.read ~base_path in
    ignore (value declarations);
    let name = guest ~base_path "defaulted" Profile.Network_none in
    let selected = Declared.select ~base_path ~declarations (row ~base_path ~name ~keeper:"defaulted") in
    match Backend.default_for_host () with
    | Some Backend.Apple_container -> expect_preserved Declared.Declared_guest selected
    | Some (Backend.Microsandbox | Backend.Nerdctl_kata) -> expect_deleted ~name ~keeper:"defaulted" selected
    | None -> expect_preserved Declared.Invalid_declaration selected)
;;

let test_scope_mismatch_and_malformed_labels_preserve () =
  with_fixture (fun ~base_path ~directory ->
    Unix.mkdir directory 0o700;
    let declarations = Declared.read ~base_path in
    ignore (value declarations);
    let original = row ~base_path ~name:"positively-scoped-orphan" ~keeper:"orphan" in
    let labels = match original.scoping_labels with Some labels -> labels | None -> Alcotest.fail "fixture scope" in
    List.iter (fun labels -> expect_preserved Declared.Foreign_scope
      (Declared.select ~base_path ~declarations {original with scoping_labels=Some labels}))
      [{labels with component="foreign"}; {labels with base_path_hash="foreign"}; {labels with kind="foreign"}];
    expect_preserved Declared.Unscoped_guest
      (Declared.select ~base_path ~declarations {original with scoping_labels=None});
    expect_preserved Declared.Invalid_keeper_label
      (Declared.select ~base_path ~declarations {original with scoping_labels=Some {labels with keeper="../unsafe"}});
    expect_preserved Declared.Other_workspace
      (Declared.select ~base_path:(base_path ^ "-other") ~declarations original);
    expect_deleted ~name:original.name ~keeper:"orphan" (Declared.select ~base_path ~declarations original))
;;

let test_owner_pid_never_controls_declared_guest_survival () =
  with_fixture (fun ~base_path ~directory ->
    Unix.mkdir directory 0o700;
    write (Filename.concat directory "keeper.toml") (apple ());
    let declarations = Declared.read ~base_path in
    ignore (value declarations);
    let name = guest ~base_path "keeper" Profile.Network_none in
    List.iter (fun pid ->
      let json = Yojson.Safe.to_string (`List [`Assoc
        ["id", `String name; "configuration", `Assoc ["labels", `Assoc
          [Labels.sandbox_component_label_key, `String Labels.sandbox_component_label_value;
           Labels.sandbox_base_path_hash_label_key, `String (Runtime.base_path_hash base_path);
           Labels.sandbox_kind_label_key, `String Masc.Keeper_sandbox_microvm.keeper_vm_container_kind;
           Labels.sandbox_keeper_label_key, `String "keeper";
           Labels.sandbox_owner_pid_label_key, `String pid]]]]) in
      let inventory = match Inventory.For_testing.inventory_of_apple_json json with
        | Ok inventory -> inventory | Error failure -> Alcotest.fail (Inventory.error_message failure) in
      List.iter (fun row -> expect_preserved Declared.Declared_guest
        (Declared.select ~base_path ~declarations row)) (Inventory.rows inventory)) ["1"; "2147483647"])
;;

let test_revalidation_refuses_changed_bytes_identity_and_config_resolution () =
  with_fixture (fun ~base_path ~directory ->
    Unix.mkdir directory 0o700;
    let file = Filename.concat directory "keeper.toml" in
    write file (apple ());
    let first = value (Declared.read ~base_path) in
    write file (apple ~network:"policy" ());
    (match Declared.revalidate first with Error _ -> () | Ok () -> Alcotest.fail "changed declaration accepted");
    let second = value (Declared.read ~base_path) in
    Unix.rename directory (directory ^ "-old"); Unix.mkdir directory 0o700;
    (match Declared.revalidate second with Error _ -> () | Ok () -> Alcotest.fail "replaced roster accepted");
    let third = value (Declared.read ~base_path) in
    Unix.putenv "MASC_CONFIG_DIR" "other-config";
    (match Declared.revalidate third with Error _ -> () | Ok () -> Alcotest.fail "changed config resolution accepted"))
;;

let () = Alcotest.run "keeper_microvm_declared_guests"
  ["actual declaration roster", [
    Alcotest.test_case "empty differs from missing or unreadable" `Quick test_empty_differs_from_missing_unreadable_or_non_directory;
    Alcotest.test_case "loaded name and network govern preservation" `Quick test_actual_loaded_name_and_network_determine_preservation;
    Alcotest.test_case "unknown declaration names protect otherwise-orphans" `Quick test_unknown_declaration_names_preserve_otherwise_orphans;
    Alcotest.test_case "parseable unresolved alias protects its bound names" `Quick test_parseable_unresolved_alias_preserves_bound_names_only;
    Alcotest.test_case "corrupt or unreadable alias preserves actual guest" `Quick test_alias_corruption_or_unreadability_never_forgets_actual_guest;
    Alcotest.test_case "original roster symlink refuses deletion authority" `Quick test_roster_root_symlink_is_not_deletion_authority;
    Alcotest.test_case "non-Apple declarations release old Apple guests" `Quick test_non_apple_profiles_do_not_keep_old_apple_guests;
    Alcotest.test_case "canonical backend and network defaults" `Quick test_canonical_host_backend_and_network_defaults;
    Alcotest.test_case "foreign and malformed scope preserves" `Quick test_scope_mismatch_and_malformed_labels_preserve;
    Alcotest.test_case "former owner PID is irrelevant" `Quick test_owner_pid_never_controls_declared_guest_survival;
    Alcotest.test_case "stale observations cannot authorize deletion" `Quick test_revalidation_refuses_changed_bytes_identity_and_config_resolution]]
