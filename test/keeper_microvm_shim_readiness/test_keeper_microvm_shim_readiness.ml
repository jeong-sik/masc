module Ready = Masc.Keeper_microvm_shim_readiness
module Shim = Masc.Keeper_sandbox_microvm
module Backend = Masc.Keeper_microvm_backend
module Recovery_test = Fs_compat_test_support.Publication_recovery_for_testing

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
let recovery_root base =
  Filename.concat (Config_dir_resolver.masc_root ~base_path:base) "microvm-shim-recovery"
let recovery_area base area =
  Filename.concat (recovery_root base)
    (Filename.concat "fs-publication-recovery/lanes/microvm-shim-config" area)

let install base bytes =
  mkdir (shim_dir base);
  write (binary base) bytes;
  Unix.chmod (binary base) 0o700;
  let digest = Agent_core_sha256.(digest_string bytes |> to_hex) in
  write (sidecar base) (digest ^ "  " ^ Shim.shim_binary_name ^ "\n")

let corrupt base =
  write (sidecar base) (String.make 64 '0' ^ "  " ^ Shim.shim_binary_name ^ "\n")

let with_fixture use =
  Eio_main.run (fun env ->
    let fs = Eio.Stdenv.fs env in
    let base = Filename.temp_dir "masc-shim-readiness-" "" in
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.clear_fs ();
    Fun.protect ~finally:(fun () ->
      Fs_compat.remove_tree base;
      match previous_fs with None -> () | Some fs -> Fs_compat.set_fs fs)
      (fun () -> use ~fs base))

let initialize fs base = Ready.initialize ~fs ~base_path:base ~payload_path
let verify ?(backend=Backend.Apple_container) ?(guest=guest_name) fs base =
  Ready.verify ~fs ~base_path:base ~backend ~guest_name:guest

let expect_rejected = function
  | Error (Ready.Verification_failed (Ready.Sidecar_rejected _)) -> ()
  | Error error -> Alcotest.fail (Ready.error_message error)
  | Ok () -> Alcotest.fail "invalid sidecar authorized the endpoint"

let test_startup_config_is_written_once () = with_fixture (fun ~fs base ->
  install base "fixture Linux shim bytes";
  value (initialize fs base);
  Alcotest.(check string) "canonical config content"
    (Shim.shim_config_content ~payload_path) (read (config base));
  let original = Unix.stat (config base) in
  value (initialize fs base);
  let repeated = Unix.stat (config base) in
  Alcotest.(check int) "repeat did not replace config" original.st_ino repeated.st_ino;
  Alcotest.(check (float 0.)) "repeat preserved config mtime" original.st_mtime repeated.st_mtime;
  (match Ready.initialize ~fs ~base_path:base ~payload_path:"/different/fixture/bin" with
   | Error Ready.Initialization_conflict -> ()
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "new payload falsely reused an old config");
  Alcotest.(check string) "conflict kept original bytes"
    (Shim.shim_config_content ~payload_path) (read (config base)))

let test_verification_requires_actual_startup () = with_fixture (fun ~fs base ->
  install base "valid but not initialized";
  (match verify fs base with
   | Error Ready.Not_initialized -> ()
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "endpoint guessed startup readiness");
  Alcotest.(check bool) "verify did not create config" false (Sys.file_exists (config base)))

let test_startup_failure_recovers_after_install () = with_fixture (fun ~fs base ->
  let missing = function
    | Error (Ready.Initialization_failed (Ready.Startup_shim_missing _)) -> ()
    | Error error -> Alcotest.fail (Ready.error_message error)
    | Ok () -> Alcotest.fail "missing startup shim accepted" in
  missing (initialize fs base);
  missing (verify fs base);
  install base "installed after actual startup failure";
  value (verify fs base);
  Alcotest.(check string) "verification created the canonical config"
    (Shim.shim_config_content ~payload_path) (read (config base));
  let original = Unix.stat (config base) in
  value (initialize fs base);
  Alcotest.(check int) "successful retry is not replaced"
    original.st_ino (Unix.stat (config base)).st_ino)

let test_startup_write_failure_is_retained () = with_fixture (fun ~fs base ->
  install base "fixture shim";
  Unix.mkdir (config base) 0o700;
  let failed = function
    | Error _ -> ()
    | Ok () -> Alcotest.fail "startup config publication failure became Ready" in
  failed (initialize fs base);
  failed (verify fs base);
  Alcotest.(check bool) "failed target was not repaired" true
    ((Unix.lstat (config base)).st_kind = Unix.S_DIR);
  Unix.rmdir (config base);
  value (verify fs base);
  Alcotest.(check string) "a removed obstruction is replaced safely"
    (Shim.shim_config_content ~payload_path) (read (config base)))

let test_uncertain_startup_publication_is_reconciled () = with_fixture (fun ~fs base ->
  install base "fixture shim";
  let fault = Recovery_test.parent_sync_dispatch_fault
      ~exception_:(Unix.Unix_error (Unix.EIO, "fsync", "private fixture path")) in
  let failure = Recovery_test.with_replace_dispatch_fault fault (fun () -> initialize fs base) in
  (match failure with
   | Error (Ready.Config_unavailable (Ready.Recovery_publication_failed error)) ->
     Alcotest.(check bool) "publication reached target" true
       (error.target_effect = Fs_compat.Target_created || error.target_effect = Target_replaced);
     Alcotest.(check bool) "diagnostic does not expose path" false
       (Astring.String.is_infix ~affix:"private fixture path" (Ready.error_message
          (Ready.Config_unavailable (Ready.Recovery_publication_failed error))))
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "uncertain publication was admitted");
  Alcotest.(check string) "real publication reached config"
    (Shim.shim_config_content ~payload_path) (read (config base));
  Alcotest.(check bool) "uncertain publication retains an owned record" true
    (Array.length (Sys.readdir (recovery_area base "owned")) > 0);
  value (verify fs base);
  Alcotest.(check int) "reconciliation settles the owned record" 0
    (Array.length (Sys.readdir (recovery_area base "owned")));
  Alcotest.(check bool) "reconciliation preserves forensic evidence" true
    (Array.length (Sys.readdir (recovery_area base "forensic")) > 0);
  Alcotest.(check string) "reconciliation preserved canonical config"
    (Shim.shim_config_content ~payload_path) (read (config base)))

let test_recovery_uses_current_runtime_fs () =
  let base = Filename.temp_dir "masc-shim-readiness-restart-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    Eio_main.run (fun env ->
      install base "fixture shim";
      value (initialize (Eio.Stdenv.fs env) base));
    Unix.unlink (config base);
    Eio_main.run (fun env ->
      value (verify (Eio.Stdenv.fs env) base);
      Alcotest.(check string) "new runtime restored config"
        (Shim.shim_config_content ~payload_path) (read (config base))))

let test_recovery_registry_is_outside_guest_mount () = with_fixture (fun ~fs base ->
  install base "fixture shim";
  let shared = Filename.concat (Config_dir_resolver.masc_root ~base_path:base)
      "fs-publication-recovery" in
  write shared "unrelated unavailable keeper registry";
  let microvm = Filename.dirname (shim_dir base) in
  Unix.chmod microvm 0o555;
  Fun.protect ~finally:(fun () -> Unix.chmod microvm 0o700) (fun () ->
    value (initialize fs base);
    Alcotest.(check bool) "shim registry uses its own namespace" true
      (Sys.file_exists (Filename.concat (recovery_root base) "fs-publication-recovery"));
    Alcotest.(check string) "shared keeper registry was left untouched"
      "unrelated unavailable keeper registry" (read shared);
    Alcotest.(check bool) "registry is not in guest shim mount" false
      (Sys.file_exists (Filename.concat (shim_dir base) "fs-publication-recovery"))))

let test_recovery_refuses_namespace_symlink () = with_fixture (fun ~fs base ->
  install base "fixture shim";
  let other = Filename.concat base "operator-directory" in
  Unix.mkdir other 0o700;
  Unix.symlink other (recovery_root base);
  (match initialize fs base with
   | Error (Ready.Config_unavailable (Ready.Recovery_registry_failed _)) -> ()
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "symlink namespace was accepted");
  Alcotest.(check bool) "namespace symlink was preserved" true
    ((Unix.lstat (recovery_root base)).st_kind = Unix.S_LNK);
  Alcotest.(check int) "symlink target was untouched" 0
    (Array.length (Sys.readdir other)))

let test_corrupt_recovery_record_blocks_admission () = with_fixture (fun ~fs base ->
  install base "fixture shim";
  let fault = Recovery_test.parent_sync_dispatch_fault
      ~exception_:(Unix.Unix_error (Unix.EIO, "fsync", "fixture")) in
  (match Recovery_test.with_replace_dispatch_fault fault (fun () -> initialize fs base) with
   | Error (Ready.Config_unavailable (Ready.Recovery_publication_failed _)) -> ()
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "uncertain publication was admitted");
  let owned = recovery_area base "owned" in
  let records = Sys.readdir owned in
  Alcotest.(check int) "one record is retained" 1 (Array.length records);
  let record = Filename.concat owned records.(0) in
  write record "corrupt recovery record\n";
  (match verify fs base with
   | Error (Ready.Config_unavailable (Ready.Recovery_lane_failed _)) -> ()
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "corrupt journal was accepted");
  Alcotest.(check string) "corrupt journal remains available for diagnosis"
    "corrupt recovery record\n" (read record);
  Alcotest.(check string) "config was preserved"
    (Shim.shim_config_content ~payload_path) (read (config base)))

let test_missing_config_recovers_after_cached_verification () = with_fixture (fun ~fs base ->
  install base "fixture verified bytes";
  value (initialize fs base);
  value (verify fs base);
  Unix.unlink (config base);
  let first, second = Eio.Fiber.pair (fun () -> verify fs base) (fun () -> verify fs base) in
  value first;
  value second;
  Alcotest.(check string) "concurrent admissions recovered the complete config"
    (Shim.shim_config_content ~payload_path) (read (config base));
  Alcotest.(check int) "recovered file is private" 0o600
    ((Unix.stat (config base)).st_perm land 0o777))

let test_existing_config_is_not_overwritten_by_recovery () = with_fixture (fun ~fs base ->
  install base "fixture verified bytes";
  value (initialize fs base);
  value (verify fs base);
  write (config base) "operator-owned different bytes\n";
  (match verify fs base with
   | Error (Ready.Config_unavailable Ready.Config_not_canonical) -> ()
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "changed config was accepted");
  Alcotest.(check string) "changed config was preserved"
    "operator-owned different bytes\n" (read (config base));
  write (config base) (Shim.shim_config_content ~payload_path);
  Unix.chmod (config base) 0o666;
  (match verify fs base with
   | Error (Ready.Config_unavailable Ready.Config_owner_or_mode_refused) -> ()
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "writable config was accepted");
  Unix.chmod (config base) 0o600;
  value (verify fs base))

let test_config_symlink_is_preserved () = with_fixture (fun ~fs base ->
  install base "fixture verified bytes";
  value (initialize fs base);
  value (verify fs base);
  let other = Filename.concat (shim_dir base) "operator-file" in
  write other "keep these bytes\n";
  Unix.unlink (config base);
  Unix.symlink other (config base);
  (match verify fs base with
   | Error (Ready.Config_unavailable (Ready.Config_inspection_failed _)) -> ()
   | Error error -> Alcotest.fail (Ready.error_message error)
   | Ok () -> Alcotest.fail "symlink config was accepted");
  Alcotest.(check bool) "symlink was preserved" true
    ((Unix.lstat (config base)).st_kind = Unix.S_LNK);
  Alcotest.(check string) "symlink target was preserved" "keep these bytes\n" (read other))

let test_success_is_cached_until_guest_is_forgotten () = with_fixture (fun ~fs base ->
  install base "fixture verified bytes";
  value (initialize fs base);
  value (verify fs base);
  corrupt base;
  value (verify fs base);
  Ready.forget ~backend:Backend.Apple_container ~guest_name;
  expect_rejected (verify fs base))

let test_failed_verification_can_observe_repair () = with_fixture (fun ~fs base ->
  install base "fixture bytes";
  corrupt base;
  value (initialize fs base);
  let original = Unix.stat (config base) in
  expect_rejected (verify fs base);
  install base "repaired fixture bytes";
  value (verify fs base);
  Alcotest.(check int) "verification repair did not rewrite config"
    original.st_ino (Unix.stat (config base)).st_ino)

let test_cache_key_includes_guest_backend_and_base () = with_fixture (fun ~fs base ->
  let other_base = Filename.concat base "another-base" in
  Unix.mkdir other_base 0o700;
  install base "first base fixture bytes";
  install other_base "other base fixture bytes";
  corrupt other_base;
  value (initialize fs base);
  value (initialize fs other_base);
  value (verify fs base);
  expect_rejected (verify fs other_base);
  corrupt base;
  expect_rejected (verify ~guest:"another-actual-guest" fs base);
  expect_rejected (verify ~backend:Backend.Nerdctl_kata fs base);
  value (verify fs base))

let test_forget_clears_matching_guest_across_bases () = with_fixture (fun ~fs base ->
  let other_base = Filename.concat base "another-base" in
  Unix.mkdir other_base 0o700;
  List.iter (fun base -> install base "valid fixture bytes"; value (initialize fs base);
    value (verify fs base); corrupt base) [base; other_base];
  Ready.forget ~backend:Backend.Apple_container ~guest_name;
  List.iter (fun base -> expect_rejected (verify fs base)) [base; other_base])

let test_hand_built_unverified_policy_is_preserved () = with_fixture (fun ~fs base ->
  install base "hand-built fixture bytes";
  Unix.unlink (sidecar base);
  value (initialize fs base);
  value (verify fs base))

let test_cancelled_caller_cannot_reuse_cached_success () = with_fixture (fun ~fs base ->
  install base "valid fixture bytes";
  value (initialize fs base);
  value (verify fs base);
  let original = Unix.stat (config base) in
  let expect_cancelled call =
    let cancelled = try
      Eio.Cancel.sub (fun context ->
        Eio.Cancel.cancel context Exit;
        value (call ()));
      false
    with Eio.Cancel.Cancelled _ -> true in
    Alcotest.(check bool) "caller cancellation propagates" true cancelled in
  expect_cancelled (fun () -> initialize fs base);
  expect_cancelled (fun () -> verify fs base);
  Alcotest.(check int) "cancelled callers preserved the published config"
    original.st_ino (Unix.stat (config base)).st_ino;
  value (verify fs base))

let test_cancellation_during_failed_recovery_propagates () = with_fixture (fun ~fs base ->
  install base "valid fixture bytes";
  value (initialize fs base);
  value (verify fs base);
  Unix.unlink (config base);
  let cancelled = try
    Eio.Cancel.sub (fun context ->
      let fault = Recovery_test.before_parent_sync_dispatch ~before_sync:(fun () ->
        Eio.Cancel.cancel context Exit;
        raise (Unix.Unix_error (Unix.EIO, "fsync", "fixture"))) in
      Recovery_test.with_replace_dispatch_fault fault (fun () -> ignore (verify fs base)));
    false
  with Eio.Cancel.Cancelled _ -> true in
  Alcotest.(check bool) "cancellation survives recovery error" true cancelled;
  value (verify fs base))

let () = Alcotest.run "microvm startup and endpoint shim readiness"
  ["actual fixture filesystem", [
    Alcotest.test_case "startup config once and conflicting payload" `Quick test_startup_config_is_written_once;
    Alcotest.test_case "uninitialized endpoint never guesses Ready" `Quick test_verification_requires_actual_startup;
    Alcotest.test_case "startup failure recovers after install" `Quick test_startup_failure_recovers_after_install;
    Alcotest.test_case "actual config publication failure is retained" `Quick test_startup_write_failure_is_retained;
    Alcotest.test_case "uncertain startup publication is reconciled" `Quick test_uncertain_startup_publication_is_reconciled;
    Alcotest.test_case "recovery uses current runtime filesystem" `Quick test_recovery_uses_current_runtime_fs;
    Alcotest.test_case "recovery registry stays outside guest mount" `Quick test_recovery_registry_is_outside_guest_mount;
    Alcotest.test_case "recovery namespace refuses symlinks" `Quick test_recovery_refuses_namespace_symlink;
    Alcotest.test_case "corrupt recovery record blocks admission" `Quick test_corrupt_recovery_record_blocks_admission;
    Alcotest.test_case "cached endpoint repairs missing config" `Quick test_missing_config_recovers_after_cached_verification;
    Alcotest.test_case "changed or writable config is preserved" `Quick test_existing_config_is_not_overwritten_by_recovery;
    Alcotest.test_case "symlink config is preserved" `Quick test_config_symlink_is_preserved;
    Alcotest.test_case "successful verification cache and actual forget" `Quick test_success_is_cached_until_guest_is_forgotten;
    Alcotest.test_case "failed sidecar check observes later repair" `Quick test_failed_verification_can_observe_repair;
    Alcotest.test_case "guest backend and base isolate cache authority" `Quick test_cache_key_includes_guest_backend_and_base;
    Alcotest.test_case "forget invalidates every matching base" `Quick test_forget_clears_matching_guest_across_bases;
    Alcotest.test_case "hand-built shim remains allowed" `Quick test_hand_built_unverified_policy_is_preserved;
    Alcotest.test_case "cached readiness preserves caller cancellation" `Quick test_cancelled_caller_cannot_reuse_cached_success;
    Alcotest.test_case "failed recovery preserves caller cancellation" `Quick test_cancellation_during_failed_recovery_propagates]]
