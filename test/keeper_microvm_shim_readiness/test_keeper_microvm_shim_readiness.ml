module Ready = Masc.Keeper_microvm_shim_readiness
module Shim = Masc.Keeper_sandbox_microvm
module Backend = Masc.Keeper_microvm_backend

let payload_path = "/fixture/bin:/usr/bin:/bin"
let guest_name = "masc-keeper-vm-fixture-none-12345678"

let value = function Ok () -> () | Error error -> Alcotest.fail (Ready.error_message error)

let write path contents =
  Out_channel.with_open_bin path (fun output -> output_string output contents)

let read path = In_channel.with_open_bin path In_channel.input_all

let rec mkdir path =
  if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)

let shim_dir base = Config_dir_resolver.microvm_shim_dir ~base_path:base
let binary base = Filename.concat (shim_dir base) Shim.shim_binary_name
let sidecar base = Filename.concat (shim_dir base) Shim.shim_sidecar_name
let config base = Filename.concat (shim_dir base) Shim.shim_config_name

let install base bytes =
  mkdir (shim_dir base);
  write (binary base) bytes;
  Unix.chmod (binary base) 0o700;
  let digest = Digestif.SHA256.(digest_string bytes |> to_hex) in
  write (sidecar base) (digest ^ "  " ^ Shim.shim_binary_name ^ "\n")

let corrupt base =
  write (sidecar base) (String.make 64 '0' ^ "  " ^ Shim.shim_binary_name ^ "\n")

let with_fixture use =
  Eio_main.run (fun _env ->
    let base = Filename.temp_dir "masc-shim-readiness-" "" in
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.clear_fs ();
    Fun.protect ~finally:(fun () ->
      Fs_compat.remove_tree base;
      match previous_fs with None -> () | Some fs -> Fs_compat.set_fs fs)
      (fun () -> use base))

let initialize base = Ready.initialize ~base_path:base ~payload_path
let verify ?(backend=Backend.Apple_container) ?(guest=guest_name) base =
  Ready.verify ~base_path:base ~backend ~guest_name:guest

let expect_rejected = function
  | Error (Ready.Verification_failed (Ready.Sidecar_rejected _)) -> ()
  | Error error -> Alcotest.fail (Ready.error_message error)
  | Ok () -> Alcotest.fail "invalid sidecar authorized the endpoint"

let test_startup_config_is_written_once () = with_fixture (fun base ->
  install base "fixture Linux shim bytes";
  value (initialize base);
  Alcotest.(check string) "canonical config content"
    (Shim.shim_config_content ~payload_path) (read (config base));
  let original = Unix.stat (config base) in
  value (initialize base);
  let repeated = Unix.stat (config base) in
  Alcotest.(check int) "repeat did not replace config" original.st_ino repeated.st_ino;
  Alcotest.(check (float 0.)) "repeat preserved config mtime" original.st_mtime repeated.st_mtime;
  (match Ready.initialize ~base_path:base ~payload_path:"/different/fixture/bin" with
   | Error Ready.Initialization_conflict -> ()
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "new payload falsely reused an old config");
  Alcotest.(check string) "conflict kept original bytes"
    (Shim.shim_config_content ~payload_path) (read (config base)))

let test_verification_requires_actual_startup () = with_fixture (fun base ->
  install base "valid but not initialized";
  (match verify base with
   | Error Ready.Not_initialized -> ()
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "endpoint guessed startup readiness");
  Alcotest.(check bool) "verify did not create config" false (Sys.file_exists (config base)))

let test_startup_failure_is_not_implicitly_retried () = with_fixture (fun base ->
  let missing = function
    | Error (Ready.Initialization_failed (Ready.Startup_shim_missing _)) -> ()
    | Error error -> Alcotest.fail (Ready.error_message error)
    | Ok () -> Alcotest.fail "missing startup shim accepted" in
  missing (initialize base);
  install base "installed after actual startup failure";
  missing (verify base);
  Alcotest.(check bool) "verification did not retry config publication" false
    (Sys.file_exists (config base));
  value (initialize base);
  value (verify base))

let test_startup_write_failure_is_retained () = with_fixture (fun base ->
  install base "fixture shim";
  Unix.mkdir (config base) 0o700;
  let failed = function
    | Error (Ready.Initialization_failed (Ready.Config_write_failed _)) -> ()
    | Error error -> Alcotest.fail (Ready.error_message error)
    | Ok () -> Alcotest.fail "startup config publication failure became Ready" in
  failed (initialize base);
  failed (verify base);
  Alcotest.(check bool) "failed target was not repaired" true
    ((Unix.lstat (config base)).st_kind = Unix.S_DIR))

let test_success_is_cached_until_guest_is_forgotten () = with_fixture (fun base ->
  install base "fixture verified bytes";
  value (initialize base);
  value (verify base);
  corrupt base;
  value (verify base);
  Ready.forget ~backend:Backend.Apple_container ~guest_name;
  expect_rejected (verify base))

let test_failed_verification_can_observe_repair () = with_fixture (fun base ->
  install base "fixture bytes";
  corrupt base;
  value (initialize base);
  let original = Unix.stat (config base) in
  expect_rejected (verify base);
  install base "repaired fixture bytes";
  value (verify base);
  Alcotest.(check int) "verification repair did not rewrite config"
    original.st_ino (Unix.stat (config base)).st_ino)

let test_cache_key_includes_guest_backend_and_base () = with_fixture (fun base ->
  let other_base = Filename.concat base "another-base" in
  Unix.mkdir other_base 0o700;
  install base "first base fixture bytes";
  install other_base "other base fixture bytes";
  corrupt other_base;
  value (initialize base);
  value (initialize other_base);
  value (verify base);
  expect_rejected (verify other_base);
  corrupt base;
  expect_rejected (verify ~guest:"another-actual-guest" base);
  expect_rejected (verify ~backend:Backend.Nerdctl_kata base);
  value (verify base))

let test_forget_clears_matching_guest_across_bases () = with_fixture (fun base ->
  let other_base = Filename.concat base "another-base" in
  Unix.mkdir other_base 0o700;
  List.iter (fun base -> install base "valid fixture bytes"; value (initialize base);
    value (verify base); corrupt base) [base; other_base];
  Ready.forget ~backend:Backend.Apple_container ~guest_name;
  List.iter (fun base -> expect_rejected (verify base)) [base; other_base])

let test_hand_built_unverified_policy_is_preserved () = with_fixture (fun base ->
  install base "hand-built fixture bytes";
  Unix.unlink (sidecar base);
  value (initialize base);
  value (verify base))

let test_cancelled_caller_cannot_reuse_cached_success () = with_fixture (fun base ->
  install base "valid fixture bytes";
  value (initialize base);
  value (verify base);
  let original = Unix.stat (config base) in
  let expect_cancelled call =
    let cancelled = try
      Eio.Cancel.sub (fun context ->
        Eio.Cancel.cancel context Exit;
        value (call ()));
      false
    with Eio.Cancel.Cancelled _ -> true in
    Alcotest.(check bool) "caller cancellation propagates" true cancelled in
  expect_cancelled (fun () -> initialize base);
  expect_cancelled (fun () -> verify base);
  Alcotest.(check int) "cancelled callers preserved the published config"
    original.st_ino (Unix.stat (config base)).st_ino;
  value (verify base))

let () = Alcotest.run "microvm startup and endpoint shim readiness"
  ["actual fixture filesystem", [
    Alcotest.test_case "startup config once and conflicting payload" `Quick test_startup_config_is_written_once;
    Alcotest.test_case "uninitialized endpoint never guesses Ready" `Quick test_verification_requires_actual_startup;
    Alcotest.test_case "startup failure needs explicit new initialization" `Quick test_startup_failure_is_not_implicitly_retried;
    Alcotest.test_case "actual config publication failure is retained" `Quick test_startup_write_failure_is_retained;
    Alcotest.test_case "successful verification cache and actual forget" `Quick test_success_is_cached_until_guest_is_forgotten;
    Alcotest.test_case "failed sidecar check observes later repair" `Quick test_failed_verification_can_observe_repair;
    Alcotest.test_case "guest backend and base isolate cache authority" `Quick test_cache_key_includes_guest_backend_and_base;
    Alcotest.test_case "forget invalidates every matching base" `Quick test_forget_clears_matching_guest_across_bases;
    Alcotest.test_case "hand-built shim remains allowed" `Quick test_hand_built_unverified_policy_is_preserved;
    Alcotest.test_case "cached readiness preserves caller cancellation" `Quick test_cancelled_caller_cannot_reuse_cached_success]]
