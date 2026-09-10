open Alcotest
open Masc

let with_home f =
  let home = Filename.temp_file "setup-private-key" "" in
  Unix.unlink home; Unix.mkdir home 0o700;
  let previous = Sys.getenv_opt "XDG_CONFIG_HOME" in
  let rec cleanup path =
    match Unix.lstat path with
    | { st_kind = Unix.S_DIR; _ } -> Array.iter (fun n -> cleanup (Filename.concat path n)) (Sys.readdir path); Unix.rmdir path
    | _ -> Unix.unlink path
  in
  Fun.protect ~finally:(fun () -> Unix.putenv "XDG_CONFIG_HOME" (Option.value previous ~default:""); cleanup home)
    (fun () -> Unix.putenv "XDG_CONFIG_HOME" home; f home)

let test_private_key_lifecycle () =
  with_home (fun _ ->
    let pending = match Runtime_setup_credentials.save ~secret:"fixture-api-key" () with
      | Ok pending -> pending | Error error -> fail (Runtime_setup_credentials.error_message error) in
    let path = Runtime_setup_credentials.reference_path pending in
    check bool "absolute file reference" false (Filename.is_relative path);
    check int "private leaf" 0o600 ((Unix.stat path).st_perm land 0o777);
    check int "private parent" 0o700 ((Unix.stat (Filename.dirname path)).st_perm land 0o777);
    check string "raw key materialization" "fixture-api-key" (In_channel.with_open_text path In_channel.input_all);
    Runtime_setup_credentials.remove_uncommitted pending;
    check bool "failed/discarded setup removes only owned new key" false (Sys.file_exists path);
    let pending = match Runtime_setup_credentials.save ~secret:"fixture-retained-key" () with
      | Ok pending -> pending | Error error -> fail (Runtime_setup_credentials.error_message error) in
    Runtime_setup_credentials.retain pending;
    Runtime_setup_credentials.remove_uncommitted pending;
    check bool "committed key is retained" true (Sys.file_exists (Runtime_setup_credentials.reference_path pending)))

let test_document_rejected_without_storage () =
  with_home (fun home ->
    (match Runtime_setup_credentials.save ~secret:{|{"access_token":"fixture-secret"}|} () with
     | Error Invalid_secret -> () | _ -> fail "credential document must not become an API key");
    check int "rejection creates no files" 0 (Array.length (Sys.readdir home)))

let test_stale_connection_never_receives_key () =
  with_home (fun home ->
    let path = Filename.concat home "runtime.toml" in
    let original = "[runtime]\n" in
    let changed = "[runtime]\n# concurrently edited endpoint/configuration\n" in
    let expected = Runtime.config_observation ~path original in
    Out_channel.with_open_bin path (fun out -> output_string out changed);
    let pending = match Runtime_setup_credentials.save ~secret:"fixture-secret" () with
      | Ok pending -> pending | Error error -> fail (Runtime_setup_credentials.error_message error) in
    (match Runtime_setup_credentials.apply_to_provider ~runtime_config_path:path
      ~provider_id:"provider" ~expected_source_revision:(Runtime.config_source_revision_to_string expected.source_revision) pending with
     | Error Configuration_changed -> () | _ -> fail "stale connection must be rejected under the config lock");
    check string "concurrent config preserved" changed (In_channel.with_open_text path In_channel.input_all);
    Runtime_setup_credentials.remove_uncommitted pending;
    check bool "uncommitted key removed" false (Sys.file_exists (Runtime_setup_credentials.reference_path pending)))

let () = run "private setup credentials" ["storage", [
  test_case "private pending and retained files" `Quick test_private_key_lifecycle;
  test_case "credential document rejected" `Quick test_document_rejected_without_storage;
  test_case "stale provider configuration rejected" `Quick test_stale_connection_never_receives_key]]
