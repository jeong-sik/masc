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

let test_cleanup_report_keeps_guest_skip_reason () =
  let decode = Keeper_turn_sandbox_runtime.build_cleanup_report_of_string in
  (match decode {|{"skip":"dune unavailable","entries":[]}|} with
   | Error reason -> Alcotest.(check string) "guest refusal remains observable"
       "Keeper guest cleanup skipped: dune unavailable" reason
   | Ok _ -> Alcotest.fail "skipped cleanup was reported as successful");
  (match decode {|{"entries":[{"action":"cleaned"},{"action":"clean failed"}]}|} with
   | Ok report ->
     Alcotest.(check int) "successful clean counted" 1 report.cleaned;
     Alcotest.(check int) "failed clean counted" 1 report.failed
   | Error reason -> Alcotest.fail reason);
  List.iter (fun body ->
    match decode body with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "malformed cleanup report accepted")
    [ {|{"skip":false,"entries":[]}|}; "not JSON" ]

let test_slow_keeper_does_not_block_another_cleanup () =
  Eio_main.run @@ fun _env ->
  let running = Server_keeper_build_maintenance.create_running () in
  Eio.Switch.run @@ fun sw ->
  let started, mark_started = Eio.Promise.create () in
  let release, allow_release = Eio.Promise.create () in
  let other, mark_other = Eio.Promise.create () in
  let duplicate = ref false in
  Server_keeper_build_maintenance.schedule ~sw ~running ~keeper_name:"slow" (fun () ->
    Eio.Promise.resolve mark_started ();
    Eio.Promise.await release);
  Eio.Promise.await started;
  Server_keeper_build_maintenance.schedule ~sw ~running ~keeper_name:"slow"
    (fun () -> duplicate := true);
  Server_keeper_build_maintenance.schedule ~sw ~running ~keeper_name:"other"
    (fun () -> Eio.Promise.resolve mark_other ());
  Eio.Promise.await other;
  Alcotest.(check bool) "in-flight Keeper is not duplicated" false !duplicate;
  Eio.Promise.resolve allow_release ()

exception Stop_cleanup_fixture

let test_cancelled_cleanup_releases_its_reservation () =
  Eio_main.run @@ fun _env ->
  let running = Server_keeper_build_maintenance.create_running () in
  let joined = ref false in
  (try Eio.Switch.run (fun sw ->
     let started, mark_started = Eio.Promise.create () in
     Server_keeper_build_maintenance.schedule ~sw ~running ~keeper_name:"cancelled"
       (fun () -> Fun.protect
         ~finally:(fun () -> joined := true)
         (fun () -> Eio.Promise.resolve mark_started (); Eio.Fiber.await_cancel ()));
     Eio.Promise.await started;
     Eio.Switch.fail sw Stop_cleanup_fixture)
   with Stop_cleanup_fixture -> ());
  Alcotest.(check bool) "cancelled callback joined before scope returns" true !joined;
  let reran = ref false in
  Eio.Switch.run (fun sw ->
    Server_keeper_build_maintenance.schedule ~sw ~running ~keeper_name:"cancelled"
      (fun () -> reran := true));
  Alcotest.(check bool) "next scope can schedule the Keeper again" true !reran

let () =
  Alcotest.run "Keeper build maintenance admission"
    [ "metadata", [
      Alcotest.test_case "TOML resolves disk placeholders" `Quick test_cleanup_reads_toml_owned_backend;
      Alcotest.test_case "Owner identity must match" `Quick test_cleanup_rejects_other_owner;
      Alcotest.test_case "Profile errors refuse cleanup" `Quick test_cleanup_rejects_invalid_profile;
      Alcotest.test_case "Guest skip reason is not empty success" `Quick test_cleanup_report_keeps_guest_skip_reason;
      Alcotest.test_case "Slow Keeper does not block another cleanup" `Quick test_slow_keeper_does_not_block_another_cleanup;
      Alcotest.test_case "Cancelled cleanup releases its reservation" `Quick test_cancelled_cleanup_releases_its_reservation;
    ] ]
