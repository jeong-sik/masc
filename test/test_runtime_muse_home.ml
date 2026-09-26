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
  let workspace = ok (Home.prepare_native_workspace ~runtime_root:root ~keeper_name:"keeper/a" ~account_home:one) in
  let other = ok (Home.prepare_native_workspace ~runtime_root:root ~keeper_name:"keeper/a" ~account_home:two) in
  check bool "workspace follows account" true (workspace <> other);
  check bool "workspace independent of settings" true (workspace <> Home.config_home first);
  check int "workspace private" 0 ((Unix.stat workspace).Unix.st_perm land 0o077))

let test_missing_signin_and_changed_managed_policy_refuse () = with_fixture (fun root ->
  let selected = account root "missing" in
  (match Home.prepare ~account_home:selected with
   | Error Home.Sign_in_required -> ()
   | Error error -> fail (Home.error_to_string error)
   | Ok _ -> fail "missing selected account fell back to ambient credentials");
  write (auth selected) (synthetic_auth "synthetic-source");
  let prepared = ok (Home.prepare ~account_home:selected) in
  write (Filename.concat (Home.config_home prepared) "muse/settings.json") "{}";
  match Home.prepare ~account_home:selected with
  | Error (Home.State_unavailable _) -> ()
  | Error error -> fail (Home.error_to_string error)
  | Ok _ -> fail "changed managed permission settings admitted")

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
   | Error (Home.State_unavailable _) | Error Home.Sign_in_required -> ()
   | _ -> fail "missing generation silently reimported source credentials");
  check bool "missing generation is not recreated" false (Sys.file_exists (Home.config_home first));
  Sys.rename (auth selected) (auth selected ^ ".original");
  Unix.symlink (auth selected ^ ".original") (auth selected);
  match Home.prepare ~account_home:selected with
  | Error (Home.State_unavailable _) -> ()
  | _ -> fail "symlink credential source accepted")

let test_invalid_home_is_refused_before_filesystem_access () = with_fixture (fun root ->
  List.iter (fun suffix ->
    match Home.prepare ~account_home:(Filename.concat root suffix) with
    | Error (Home.Invalid_account_home _) -> ()
    | Error error -> fail (Home.error_to_string error)
    | Ok _ -> fail "invalid account home accepted")
    [ "account\000suffix"; "account\255suffix" ];
  check int "invalid paths create no account state" 0 (Array.length (Sys.readdir root)))

let () = run "Muse managed account home"
  [ "selected account", [
      test_case "vendor refresh and external re-login" `Quick test_refresh_survives_and_source_relogin_gets_a_new_identity;
      test_case "accounts, settings and workspaces" `Quick test_accounts_settings_and_native_workspaces_are_separate;
      test_case "missing auth and changed policy refuse" `Quick test_missing_signin_and_changed_managed_policy_refuse;
      test_case "corrupt auth and missing generation refuse" `Quick test_corrupt_auth_and_missing_generation_do_not_reimport;
      test_case "invalid home refuses before filesystem access" `Quick test_invalid_home_is_refused_before_filesystem_access ] ]
