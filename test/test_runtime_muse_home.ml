open Alcotest
module Home = Runtime_muse_home

let ok = function Ok value -> value | Error error -> fail (Home.error_to_string error)
let write path body =
  let channel = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel body)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | _ -> Sys.remove path

let with_fixture f =
  let root = Filename.temp_dir "muse-home-test-" "" in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    Eio_main.run (fun _ -> f root))

let account root name =
  let home = Filename.concat root name in
  Unix.mkdir home 0o700;
  let config = Filename.concat home ".config" in
  Unix.mkdir config 0o700;
  Unix.mkdir (Filename.concat config "muse") 0o700;
  home

let auth home = Filename.concat home ".config/muse/auth.json"
let managed_auth home = Filename.concat (Home.config_home home) "muse/auth.json"
let synthetic_auth marker = Yojson.Safe.to_string (`Assoc [ "schema_version", `Int 1;
  "providers", `Assoc [ "meta", `Assoc [ "api_key", `String marker ] ] ])

let managed_settings home = Filename.concat (Home.config_home home) "muse/settings.json"

(* The capability ids the Muse host (1.4.3) names for its bundled observer
   agents; each one makes model calls on the account when enabled. *)
let observer_capability_ids =
  [ "plugin:tbh-reminders:reminder:memory"
  ; "plugin:tbh-reminders:reminder:skill-reminder"
  ; "plugin:tbh-reminders:reminder:verify-reminder"
  ; "plugin:tbh-reminders:reminder:goal-reminder"
  ; "plugin:tbh-reminders:reminder:todo-reminder"
  ; "plugin:tbh-reminders:reminder:scope-reminder" ]

let check_observers_off label config_home =
  let open Yojson.Safe.Util in
  let settings =
    Fs_compat.load_file (Filename.concat config_home "muse/settings.json")
    |> Yojson.Safe.from_string in
  check string (label ^ ": safe profile") ":ask-me"
    (settings |> member "permissions" |> member "default_profile" |> to_string);
  let capabilities = settings |> member "runtime_capabilities" |> to_assoc in
  check (list string) (label ^ ": exactly the bundled observers are named")
    (List.sort String.compare observer_capability_ids)
    (List.sort String.compare (List.map fst capabilities));
  List.iter (fun (id, value) ->
      check bool (label ^ ": " ^ id ^ " disabled") false (value |> member "enabled" |> to_bool))
    capabilities

let test_refresh_survives_and_source_relogin_gets_a_new_identity () = with_fixture (fun root ->
  let selected = account root "selected" in
  let original = synthetic_auth "synthetic-source-one" in
  write (auth selected) original;
  let first = ok (Home.prepare ~account_home:selected) in
  let refreshed = synthetic_auth "synthetic-vendor-refreshed" in
  write (managed_auth first) refreshed;
  let second = ok (Home.prepare ~account_home:selected) in
  check string "another keeper shares the same native credential generation"
    (Home.config_home first) (Home.config_home second);
  check string "unchanged source preserves vendor refresh" refreshed (Fs_compat.load_file (managed_auth second));
  check string "source credentials are untouched" original (Fs_compat.load_file (auth selected));
  let relogin = synthetic_auth "synthetic-source-two" in
  write (auth selected) relogin;
  let third = ok (Home.prepare ~account_home:selected) in
  check bool "external sign-in changes session binding identity" true
    (Home.account_revision second <> Home.account_revision third);
  check string "new credentials imported" relogin (Fs_compat.load_file (managed_auth third));
  check string "an already running generation keeps its refresh" refreshed (Fs_compat.load_file (managed_auth second)))

let test_accounts_settings_and_native_workspaces_are_separate () = with_fixture (fun root ->
  let one = account root "one" and two = account root "two" in
  write (auth one) (synthetic_auth "synthetic-one");
  write (auth two) (synthetic_auth "synthetic-two");
  write (Filename.concat one ".config/muse/settings.json")
    {|{"schema_version":1,"permissions":{"schema_version":1,"default_profile":":unrestricted"},"hooks":{"SessionStart":[]}}|};
  let first = ok (Home.prepare ~account_home:one) and second = ok (Home.prepare ~account_home:two) in
  check bool "accounts share no config root" true (Home.config_home first <> Home.config_home second);
  check bool "accounts share no vendor temp root" true (Home.private_tmpdir first <> Home.private_tmpdir second);
  check int "vendor temp root private" 0 ((Unix.stat (Home.private_tmpdir first)).Unix.st_perm land 0o077);
  let settings = Fs_compat.load_file (Filename.concat (Home.config_home first) "muse/settings.json") |> Yojson.Safe.from_string in
  check string "safe profile generated" ":ask-me" Yojson.Safe.Util.(settings |> member "permissions" |> member "default_profile" |> to_string);
  check bool "source hooks not imported" true (Yojson.Safe.Util.member "hooks" settings = `Null);
  check_observers_off "generated settings" (Home.config_home first);
  let workspace = ok (Home.prepare_native_workspace ~runtime_root:root ~keeper_name:"keeper/a" ~account_home:one) in
  let other = ok (Home.prepare_native_workspace ~runtime_root:root ~keeper_name:"keeper/a" ~account_home:two) in
  check bool "workspace follows account" true (workspace <> other);
  check bool "workspace independent of settings" true (workspace <> Home.config_home first);
  check int "workspace private" 0 ((Unix.stat workspace).Unix.st_perm land 0o077))

let test_missing_signin_refuses () = with_fixture (fun root ->
  let selected = account root "missing" in
  match Home.prepare ~account_home:selected with
  | Error (Home.Sign_in_required Home.No_file_sign_in) -> ()
  | Error error -> fail (Home.error_to_string error)
  | Ok _ -> fail "missing selected account fell back to ambient credentials")

(* Settings that name the safe profile but leave the host's observers on. *)
let observers_left_on_settings =
  {|{"schema_version":1,"permissions":{"schema_version":1,"default_profile":":ask-me"}}|}

let test_other_settings_are_replaced_by_a_generation_carrying_the_sign_in () = with_fixture (fun root ->
  let selected = account root "policy-change" in
  let source = synthetic_auth "synthetic-source" in
  write (auth selected) source;
  let first = ok (Home.prepare ~account_home:selected) in
  let refreshed = synthetic_auth "synthetic-vendor-refreshed" in
  write (managed_auth first) refreshed;
  write (managed_settings first) observers_left_on_settings;
  let second = ok (Home.prepare ~account_home:selected) in
  check bool "settings with observers on are not admitted again" true
    (Home.account_revision first <> Home.account_revision second);
  check_observers_off "replacement generation" (Home.config_home second);
  check string "replacement keeps the vendor refresh, not the source copy" refreshed
    (Fs_compat.load_file (managed_auth second));
  check string "source credentials are untouched" source (Fs_compat.load_file (auth selected));
  check string "a running replaced generation is left as it was" observers_left_on_settings
    (Fs_compat.load_file (managed_settings first));
  let third = ok (Home.prepare ~account_home:selected) in
  check string "the replacement is reused while its settings stand"
    (Home.account_revision second) (Home.account_revision third);
  write (managed_settings third) "{}";
  let edited = ok (Home.prepare ~account_home:selected) in
  check bool "edited settings are replaced too" true
    (Home.account_revision third <> Home.account_revision edited);
  check_observers_off "after an edit" (Home.config_home edited);
  Sys.remove (managed_settings edited);
  let missing = ok (Home.prepare ~account_home:selected) in
  check bool "missing settings are replaced" true
    (Home.account_revision edited <> Home.account_revision missing);
  check string "every replacement carries the same sign-in" refreshed
    (Fs_compat.load_file (managed_auth missing));
  write (managed_settings missing) observers_left_on_settings;
  Sys.remove (managed_auth missing);
  match Home.prepare ~account_home:selected with
  | Error (Home.Sign_in_required Home.No_file_sign_in) -> ()
  | Error error -> fail (Home.error_to_string error)
  | Ok _ -> fail "a generation without its sign-in was replaced from the source copy")

let auth_with_storage storage = Yojson.Safe.to_string (`Assoc [ "schema_version", `Int 1;
  "providers", `Assoc [ "meta", `Assoc [ "mechanism", `String "oauth"; "storage", storage ] ] ])

let test_only_a_sign_in_held_in_auth_json_is_admitted () = with_fixture (fun root ->
  let file_backed = account root "file-backed" in
  write (auth file_backed) (auth_with_storage (`String "file"));
  ignore (ok (Home.prepare ~account_home:file_backed));
  let keychain = account root "keychain" in
  write (auth keychain) (auth_with_storage (`String "keychain"));
  (match Home.prepare ~account_home:keychain with
   | Error (Home.Sign_in_required Home.Keychain_sign_in) -> ()
   | Error error -> fail (Home.error_to_string error)
   | Ok _ -> fail "a Keychain-held sign-in was imported as if auth.json held it");
  check bool "a refused sign-in publishes no generation" false
    (Sys.file_exists (Filename.concat keychain ".local/state/masc/muse-config/current.json"));
  let unknown = account root "unknown" in
  write (auth unknown) (auth_with_storage (`String "vault"));
  (match Home.prepare ~account_home:unknown with
   | Error (Home.Sign_in_required (Home.Unsupported_credential_storage "vault")) -> ()
   | Error error -> fail (Home.error_to_string error)
   | Ok _ -> fail "an unknown credential storage was admitted");
  let malformed = account root "malformed" in
  write (auth malformed) (auth_with_storage (`Int 1));
  (match Home.prepare ~account_home:malformed with
   | Error (Home.State_unavailable _) -> ()
   | Error error -> fail (Home.error_to_string error)
   | Ok _ -> fail "a non-string credential storage was admitted");
  let relogin = account root "relogin" in
  write (auth relogin) (synthetic_auth "synthetic-inline");
  ignore (ok (Home.prepare ~account_home:relogin));
  write (auth relogin) (auth_with_storage (`String "keychain"));
  match Home.prepare ~account_home:relogin with
  | Error (Home.Sign_in_required Home.Keychain_sign_in) -> ()
  | Error error -> fail (Home.error_to_string error)
  | Ok _ -> fail "a later Keychain sign-in kept the earlier file generation")

let test_corrupt_auth_and_missing_generation_do_not_reimport () = with_fixture (fun root ->
  let selected = account root "selected" in
  write (auth selected) "not JSON";
  (match Home.prepare ~account_home:selected with
   | Error (Home.State_unavailable _) -> ()
   | _ -> fail "malformed authentication imported");
  write (auth selected) (synthetic_auth "synthetic-source");
  let first = ok (Home.prepare ~account_home:selected) in
  remove (Home.config_home first);
  (match Home.prepare ~account_home:selected with
   | Error (Home.State_unavailable _) | Error (Home.Sign_in_required _) -> ()
   | _ -> fail "missing generation silently reimported source credentials");
  check bool "missing generation is not recreated" false (Sys.file_exists (Home.config_home first));
  Sys.rename (auth selected) (auth selected ^ ".original");
  Unix.symlink (auth selected ^ ".original") (auth selected);
  match Home.prepare ~account_home:selected with
  | Error (Home.State_unavailable _) -> ()
  | _ -> fail "symlink credential source accepted")

let test_symlink_home_preserves_identity_and_owned_descendant_checks () = with_fixture (fun root ->
  let selected = account root "selected" in
  let alias = Filename.concat root "selected-alias" in
  Unix.symlink selected alias;
  write (auth selected) (synthetic_auth "synthetic-source");
  let prepared = ok (Home.prepare ~account_home:alias) in
  let refreshed = synthetic_auth "synthetic-refreshed" in
  write (managed_auth prepared) refreshed;
  let again = ok (Home.prepare ~account_home:alias) in
  check string "symlink HOME preserves managed refresh" refreshed
    (Fs_compat.load_file (managed_auth again));
  check string "same account reuses its generation" (Home.account_revision prepared)
    (Home.account_revision again);
  (match Runtime_account_home.of_string alias with
   | Ok value -> check string "configured account spelling remains identity" alias value
   | Error detail -> fail detail);
  let workspace account_home = ok (Home.prepare_native_workspace
    ~runtime_root:root ~keeper_name:"selected-keeper" ~account_home) in
  check bool "workspace identity retains configured account spelling" true
    (workspace selected <> workspace alias);
  Sys.rename (auth selected) (auth selected ^ ".original");
  Unix.symlink (auth selected ^ ".original") (auth selected);
  (match Home.prepare ~account_home:alias with
   | Error (Home.State_unavailable _) -> ()
   | _ -> fail "symlink HOME bypassed credential descendant protection");
  Unix.unlink (auth selected);
  Sys.rename (auth selected ^ ".original") (auth selected);
  let config_alias = account root "config-alias" in
  Unix.rmdir (Filename.concat config_alias ".config/muse");
  Unix.rmdir (Filename.concat config_alias ".config");
  Unix.symlink (Filename.concat selected ".config") (Filename.concat config_alias ".config");
  match Home.prepare ~account_home:config_alias with
  | Error (Home.State_unavailable _) -> ()
  | _ -> fail "symlink configuration directory accepted")

let test_invalid_home_is_refused_before_filesystem_access () = with_fixture (fun root ->
  List.iter (fun suffix ->
    match Home.prepare ~account_home:(Filename.concat root suffix) with
    | Error (Home.Invalid_account_home _) -> ()
    | Error error -> fail (Home.error_to_string error)
    | Ok _ -> fail "invalid account home accepted")
    [ "account\000suffix"; "account\255suffix" ];
  check int "invalid paths create no account state" 0 (Array.length (Sys.readdir root)))

let test_foreign_ownership_is_refused () = with_fixture (fun root ->
  let selected = account root "owned" in
  write (auth selected) (synthetic_auth "synthetic-owned");
  let stat = Unix.lstat (Filename.concat selected ".config") in
  check bool "owned source parent admitted" true
    (Result.is_ok (Home.For_testing.check_directory_stat ~private_:false stat));
  let foreign_uid = if stat.Unix.st_uid = 0 then 1 else 0 in
  check bool "readable foreign parent refused" true
    (Result.is_error (Home.For_testing.check_directory_stat ~private_:false
      {stat with Unix.st_uid = foreign_uid}));
  check bool "owned but group/other-writable parent refused" true
    (Result.is_error (Home.For_testing.check_directory_stat ~private_:false
      {stat with Unix.st_perm = 0o777}));
  Unix.chmod (Filename.concat selected ".config") 0o777;
  (match Home.prepare ~account_home:selected with
   | Error (Home.State_unavailable _) -> ()
   | Error error -> fail (Home.error_to_string error)
   | Ok _ -> fail "writable credential parent admitted");
  Unix.chmod (Filename.concat selected ".config") 0o700;
  let file = match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:selected (auth selected) with
    | Ok (Some file) -> file | _ -> fail "owned source fixture missing" in
  check bool "owned private source admitted" true
    (Result.is_ok (Home.For_testing.check_file_snapshot file.snapshot));
  check bool "foreign 0600 credential refused" true
    (Result.is_error (Home.For_testing.check_file_snapshot
      {file.snapshot with owner_uid=foreign_uid})))

let test_directory_creation_syncs_each_parent () = with_fixture (fun root ->
  let synced = ref [] in
  let sync path = synced := !synced @ [path] in
  let _ = List.fold_left (fun parent leaf ->
    let path = Filename.concat parent leaf in
    ok (Home.For_testing.ensure_directory_with_sync ~sync ~private_:true path);
    check (list string) "each new directory publishes its parent" [parent] !synced;
    synced := [];
    ok (Home.For_testing.ensure_directory_with_sync ~sync ~private_:true path);
    check (list string) "existing directory publication is reconfirmed" [parent] !synced;
    synced := [];
    path) root [".local"; "state"; "masc"; "muse-config"; "generation"; "muse"] in
  ())

let test_parent_sync_failure_is_retried_on_existing_directory () = with_fixture (fun root ->
  let path = Filename.concat root "interrupted-publication" in
  let attempts = ref [] in
  let sync parent =
    attempts := parent :: !attempts;
    if List.length !attempts = 1 then raise (Unix.Unix_error (Unix.EIO, "fsync", parent)) in
  (match Home.For_testing.ensure_directory_with_sync ~sync ~private_:true path with
   | exception Unix.Unix_error (Unix.EIO, "fsync", _) -> ()
   | Ok () -> fail "failed parent sync was reported as successful publication"
   | Error error -> fail (Home.error_to_string error));
  check bool "interrupted attempt leaves a visible directory" true (Sys.is_directory path);
  ok (Home.For_testing.ensure_directory_with_sync ~sync ~private_:true path);
  check (list string) "retry confirms the parent despite EEXIST" [root; root] (List.rev !attempts))

let test_visible_generation_pointer_requires_successful_store_sync () = with_fixture (fun root ->
  let selected = account root "pointer-retry" in
  write (auth selected) (synthetic_auth "synthetic-account-a");
  let first = ok (Home.prepare ~account_home:selected) in
  let store = Filename.dirname (Home.config_home first) in
  let record_path = Filename.concat store "current.json" in
  let old_record = Fs_compat.load_file record_path in
  write (auth selected) (synthetic_auth "synthetic-account-b");
  let second = ok (Home.prepare ~account_home:selected) in
  let new_record = Fs_compat.load_file record_path in
  let refreshed = synthetic_auth "synthetic-refreshed-b" in
  write (managed_auth second) refreshed;
  (match Fs_compat.save_file_atomic_strict record_path old_record with
   | Ok () -> () | Error detail -> fail detail);
  (match Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
      ~sync_parent:(fun parent -> raise (Unix.Unix_error (Unix.EIO, "fsync", parent)))
      record_path new_record with
   | Error {stage=Fs_compat.After_rename; _} -> ()
   | Error failure -> fail (Fs_compat.atomic_replace_failure_to_string failure)
   | Ok () -> fail "injected pointer publication failure was ignored");
  check string "failed pointer publication is still visible" new_record (Fs_compat.load_file record_path);
  let attempts = ref [] in
  (match Home.For_testing.prepare_with_store_sync ~account_home:selected
      ~sync_store:(fun parent -> attempts := parent :: !attempts;
        raise (Unix.Unix_error (Unix.EIO, "fsync", parent))) with
   | Error (Home.State_unavailable _) -> ()
   | Error error -> fail (Home.error_to_string error)
   | Ok _ -> fail "visible pointer was admitted without a successful parent sync");
  check (list string) "retry syncs the store, not only its parent" [store] !attempts;
  let recovered = ok (Home.prepare ~account_home:selected) in
  check string "successful retry retains the exact generation" (Home.account_revision second)
    (Home.account_revision recovered);
  check string "retry preserves native refresh" refreshed (Fs_compat.load_file (managed_auth recovered)))

let () = run "Muse managed account home"
  [ "selected account", [
      test_case "visible pointer requires a successful store sync" `Quick test_visible_generation_pointer_requires_successful_store_sync;
      test_case "foreign file and parent ownership refuse" `Quick test_foreign_ownership_is_refused;
      test_case "interrupted parent publication is retried" `Quick test_parent_sync_failure_is_retried_on_existing_directory;
      test_case "every accepted directory syncs its parent" `Quick test_directory_creation_syncs_each_parent;
      test_case "vendor refresh and external re-login" `Quick test_refresh_survives_and_source_relogin_gets_a_new_identity;
      test_case "accounts, settings and workspaces" `Quick test_accounts_settings_and_native_workspaces_are_separate;
      test_case "missing auth refuses" `Quick test_missing_signin_refuses;
      test_case "other settings get a generation carrying the sign-in" `Quick test_other_settings_are_replaced_by_a_generation_carrying_the_sign_in;
      test_case "only a sign-in held in auth.json is admitted" `Quick test_only_a_sign_in_held_in_auth_json_is_admitted;
      test_case "corrupt auth and missing generation refuse" `Quick test_corrupt_auth_and_missing_generation_do_not_reimport;
      test_case "symlink HOME retains identity and descendant protection" `Quick test_symlink_home_preserves_identity_and_owned_descendant_checks;
      test_case "invalid home refuses before filesystem access" `Quick test_invalid_home_is_refused_before_filesystem_access ] ]
