open Alcotest
open Masc
module Accounts = Runtime_setup_accounts

let get = function Ok value -> value | Error error -> fail (Accounts.error_message error)
let write path contents = Auth.save_private_text_file path contents
let fixture f =
  let directory = Filename.temp_file "setup-account-reference" "" in
  Unix.unlink directory; Unix.mkdir directory 0o700;
  let previous = Sys.getenv_opt "XDG_CONFIG_HOME" in
  Fun.protect ~finally:(fun () ->
    Unix.putenv "XDG_CONFIG_HOME" (Option.value previous ~default:"");
    Fs_compat.remove_tree directory) (fun () ->
      Unix.putenv "XDG_CONFIG_HOME" directory;
      let workspace = Filename.concat directory "workspace" in
      Unix.mkdir workspace 0o700;
      Eio_main.run (fun _ -> f directory workspace))

let import ~base_path =
  let runtime_root=Common.masc_dir_from_base_path ~base_path in
  check int "native account requires private runtime root" 0o700 ((Unix.stat runtime_root).st_perm land 0o777);
  let credential_file = Filename.concat base_path "account.json" in
  write credential_file "fixture-selected-account";
  Ok {Accounts.credential_file; timeout_s=123.5; catalog=`Assoc ["models",`List []]}
let create workspace = Accounts.create ~workspace ~integration_id:"antigravity" ~cli_path:"agy" ~import |> get
let credential_file = function
  | Accounts.Antigravity_account account -> account.credential_file
  | Native_home _ -> fail "expected Antigravity account"
let resolve workspace reference = Accounts.resolve ~workspace ~integration_id:"antigravity" ~cli_path:"agy" reference

let persisted_scope () = fixture (fun directory workspace ->
  let reference,_ = create workspace in
  let serialized = Accounts.reference_to_string reference in
  check bool "opaque reference has no path" true (Auth.is_generated_token_shape serialized);
  let restored = Accounts.reference_of_string serialized |> get in
  let binding = resolve workspace restored |> get in
  check string "selected credential retained" "fixture-selected-account"
    (In_channel.with_open_bin (credential_file binding) In_channel.input_all);
  check int "private credential" 0o600 ((Unix.stat (credential_file binding)).st_perm land 0o777);
  let other = Filename.concat directory "other" in Unix.mkdir other 0o700;
  (match resolve other restored with Error Scope_mismatch -> () | _ -> fail "cross-workspace reference accepted");
  (match Accounts.resolve ~workspace ~integration_id:"other" ~cli_path:"agy" restored with
   | Error Scope_mismatch -> () | _ -> fail "cross-integration reference accepted");
  (match Accounts.resolve ~workspace ~integration_id:"antigravity" ~cli_path:"different-cli" restored with
   | Error Scope_mismatch -> () | _ -> fail "cross-CLI reference accepted");
  Unix.rmdir workspace; Unix.mkdir workspace 0o700;
  check bool "owner restart does not require in-memory account state" true (Result.is_ok (resolve workspace restored));
  let relocated = Filename.concat directory "relocated" in Unix.rename workspace relocated;
  (match resolve relocated restored with Error Scope_mismatch -> () | _ -> fail "relocation must request explicit import");
  check bool "saved global credential survives relocation" true (Sys.file_exists (credential_file binding)))

let private_manifest () = fixture (fun _ workspace ->
  let reference,_ = create workspace in
  let binding = resolve workspace reference |> get in
  let manifest = Filename.concat (Filename.dirname (credential_file binding)) "reference.json" in
  Unix.chmod manifest 0o644;
  (match resolve workspace reference with Error Private_storage_unavailable -> () | _ -> fail "public manifest accepted");
  Unix.chmod manifest 0o600;
  Unix.chmod (credential_file binding) 0o644;
  (match resolve workspace reference with Error Private_storage_unavailable -> () | _ -> fail "public OAuth file accepted");
  (match Accounts.reference_of_string "../account" with Error Invalid_reference -> () | _ -> fail "path reference accepted"))

let failed_import_cleanup () = fixture (fun directory workspace ->
  let source = Filename.concat directory "source-account.json" in write source "source-fixture";
  let allocated = ref None in
  let import ~base_path =
    allocated := Some base_path;
    Ok {Accounts.credential_file=source; timeout_s=30.; catalog=`Null} in
  (match Accounts.create ~workspace ~integration_id:"antigravity" ~cli_path:"agy" ~import with
   | Error Import_failed -> () | _ -> fail "source account outside managed home accepted");
  check string "source account unchanged" "source-fixture" (In_channel.with_open_bin source In_channel.input_all);
  check bool "failed import directory removed" false (Sys.file_exists (Option.get !allocated)))

let native_home_scope () = fixture (fun directory workspace ->
  let account_home = Filename.concat directory "selected-home" in
  Unix.mkdir account_home 0o700;
  let reference = Accounts.lease_home ~workspace ~integration_id:"muse-code"
    ~cli_path:"muse" ~account_home |> get in
  let retried = Accounts.lease_home ~workspace ~integration_id:"muse-code"
    ~cli_path:"muse" ~account_home |> get in
  check string "refresh and abandoned retry reuse one lease"
    (Accounts.reference_to_string reference) (Accounts.reference_to_string retried);
  (match Accounts.resolve ~workspace ~integration_id:"muse-code" ~cli_path:"muse" reference |> get with
   | Native_home selected -> check string "explicit selected home retained" account_home selected.account_home
   | Antigravity_account _ -> fail "native account changed transport");
  (match Accounts.resolve ~workspace ~integration_id:"codex" ~cli_path:"muse" reference with
   | Error Scope_mismatch -> () | _ -> fail "cross-client home reference accepted");
  check (list string) "lease does not write authentication or settings" []
    (Sys.readdir account_home |> Array.to_list);
  (match Accounts.release_native_home ~workspace ~integration_id:"codex" ~cli_path:"muse" reference with
   | Error Scope_mismatch -> () | _ -> fail "cross-client lease release accepted");
  check bool "wrong scope cannot consume the lease" true
    (Result.is_ok (Accounts.resolve ~workspace ~integration_id:"muse-code" ~cli_path:"muse" reference));
  Accounts.release_native_home ~workspace ~integration_id:"muse-code" ~cli_path:"muse" reference |> get;
  check bool "completed lease is no longer usable" true
    (Result.is_error (Accounts.resolve ~workspace ~integration_id:"muse-code" ~cli_path:"muse" reference));
  check bool "release preserves the selected account" true (Sys.is_directory account_home);
  let imported,_ = create workspace in
  let credential = resolve workspace imported |> get |> credential_file in
  check bool "durable imported credentials cannot be consumed as a lease" true
    (Result.is_error (Accounts.release_native_home ~workspace ~integration_id:"antigravity" ~cli_path:"agy" imported));
  check string "imported credential is preserved" "fixture-selected-account" (Fs_compat.load_file credential))

let () = run "setup account references" ["private account",[
  test_case "native home scoped reference" `Quick native_home_scope;
  test_case "persistent scoped reference" `Quick persisted_scope;
  test_case "private manifest and credential required" `Quick private_manifest;
  test_case "failed import preserves source and cleans destination" `Quick failed_import_cleanup]]
