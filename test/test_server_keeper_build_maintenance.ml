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
    match Keeper_cleanup_attempt.read_meta ~config
            ~keeper_name:"cleanup-owner" with
    | Ok (Some meta) ->
      Alcotest.(check bool) "cleanup resolves declared profile" true
        (meta.sandbox_profile = Keeper_types_profile_sandbox.Micro_vm);
      Alcotest.(check bool) "cleanup resolves declared backend" true
        (meta.microvm_backend = Some Keeper_microvm_backend.Apple_container)
    | _ -> Alcotest.fail "cleanup did not read effective metadata")

let remote_ssh_profile =
  "[keeper]\ninstructions = \"fixture instructions for keeper build maintenance\"\nsandbox_profile = \"remote_ssh\"\nremote_endpoint = \"fixture-endpoint\"\n"

let test_step_follows_the_declared_profile () =
  with_fixture (fun config profile seed ->
    profile "remote-owner" remote_ssh_profile;
    seed ~owner:"remote-owner" ~payload_name:"remote-owner";
    profile "guest-owner" microvm_profile;
    seed ~owner:"guest-owner" ~payload_name:"guest-owner";
    (match Keeper_meta_store.read_meta config "remote-owner" with
     | Ok (Some raw) ->
       Alcotest.(check bool) "stored meta carries the decoder placeholder" true
         (raw.sandbox_profile = Keeper_types_profile_sandbox.Docker)
     | _ -> Alcotest.fail "fixture disk meta missing");
    let selected keeper_name =
      Keeper_cleanup_attempt.select ~config ~enabled:(fun _ -> true) ~keeper_name in
    Alcotest.(check bool) "remote_ssh TOML selects the workspace step" true
      (selected "remote-owner" = Ok [ Keeper_cleanup_step.Remote_workspace ]);
    Alcotest.(check bool) "microvm TOML selects the build step" true
      (selected "guest-owner" = Ok [ Keeper_cleanup_step.Guest_builds ]))

let test_cleanup_rejects_other_owner () =
  with_fixture (fun config profile seed ->
    profile "cleanup-owner" microvm_profile;
    profile "other-owner" microvm_profile;
    seed ~owner:"cleanup-owner" ~payload_name:"other-owner";
    match Keeper_cleanup_attempt.read_meta ~config
            ~keeper_name:"cleanup-owner" with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "another Keeper was admitted as the cleanup target")

let test_cleanup_rejects_invalid_profile () =
  with_fixture (fun config profile seed ->
    profile "cleanup-owner" "[keeper]\ninstructions = \"fixture instructions\"\nsandbox_profile = \"invalid-profile\"\n";
    seed ~owner:"cleanup-owner" ~payload_name:"cleanup-owner";
    match Keeper_cleanup_attempt.read_meta ~config
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

let test_workspace_report_counts_entries_and_keeps_skip_reason () =
  let decode = Keeper_remote_workspace_cleanup.report_of_string in
  (match decode {|{"skip":"/proc unavailable","entries":[],"free_kib_before":5,"free_kib_after":5}|} with
   | Error reason -> Alcotest.(check string) "payload refusal remains observable"
       "Keeper workspace cleanup skipped: /proc unavailable" reason
   | Ok _ -> Alcotest.fail "skipped sweep was reported as successful");
  (match decode
     {|{"free_kib_before":100,"free_kib_after":160,"entries":[
        {"name":"p1","result":"removed"},{"name":"p2","result":"removed"},
        {"name":".config","result":"skipped","reason":"dot entry"},
        {"name":"p3","result":"failed","reason":"busy"}]}|} with
   | Ok report ->
     Alcotest.(check (list int)) "removed, skipped, failed, freed, available"
       [ 2; 1; 1; 60; 160 ]
       [ report.removed; report.skipped; report.failed; report.freed_kib; report.available_kib ]
   | Error reason -> Alcotest.fail reason);
  List.iter (fun body ->
    match decode body with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "malformed workspace report accepted: %s" body)
    [ {|{"free_kib_before":1,"free_kib_after":1,"entries":[{"result":"would remove"}]}|};
      {|{"free_kib_before":1,"free_kib_after":1,"entries":[{"name":"p1"}]}|};
      {|{"entries":[]}|};
      {|{"skip":false,"entries":[],"free_kib_before":1,"free_kib_after":1}|};
      "not JSON" ]

let docker_profile =
  "[keeper]\ninstructions = \"fixture instructions for keeper build maintenance\"\nsandbox_profile = \"docker\"\nsandbox_image = \"fixture-image\"\n"

let test_each_step_takes_its_own_switch () =
  with_fixture (fun config profile seed ->
    List.iter (fun (owner, contents) ->
      profile owner contents;
      seed ~owner ~payload_name:owner)
      [ "guest-owner", microvm_profile;
        "remote-owner", remote_ssh_profile;
        "docker-owner", docker_profile ];
    let module Step = Keeper_cleanup_step in
    let module Status = Keeper_cleanup_status in
    let selection = Alcotest.testable
        (fun ppf selection -> Format.pp_print_string ppf (match selection with
           | Error (Status.Unreadable detail) -> "unreadable: " ^ detail
           | Error Status.Without_meta -> "without meta"
           | Error Status.No_step -> "no step"
           | Error Status.Switched_off -> "switched off"
           | Ok steps -> String.concat "," (List.map Step.to_string steps)))
        ( = ) in
    let only wanted candidate = Step.equal candidate wanted in
    let every _ = true in
    List.iter (fun (label, keeper_name, enabled, expected) ->
      Alcotest.check selection label expected
        (Keeper_cleanup_attempt.select ~config ~enabled ~keeper_name))
      [ "guest step on", "guest-owner", only Step.Guest_builds, Ok [ Step.Guest_builds ];
        "guest step off", "guest-owner", only Step.Remote_workspace,
        Error Status.Switched_off;
        "workspace step on", "remote-owner", only Step.Remote_workspace,
        Ok [ Step.Remote_workspace ];
        "workspace step off", "remote-owner", only Step.Guest_builds,
        Error Status.Switched_off;
        "no step cleans a docker sandbox", "docker-owner", every, Error Status.No_step;
        "a Keeper with no stored meta", "absent-owner", every, Error Status.Without_meta ])

let test_admission_result_becomes_an_outcome () =
  let module M = Keeper_cleanup_attempt in
  let module Status = Keeper_cleanup_status in
  let report = { Status.cleaned = 2; failed = 1 } in
  Alcotest.(check bool) "a run to its end carries the report" true
    (M.outcome_of_admission (Ok (`Ran (Ok (Some report)))) = Status.Reclaimed report);
  Alcotest.(check bool) "no running guest" true
    (M.outcome_of_admission (Ok (`Ran (Ok None)))
     = (Status.Not_running : Status.builds Status.outcome));
  Alcotest.(check bool) "a payload failure keeps its words" true
    (M.outcome_of_admission (Ok (`Ran (Error "exit=1: traceback")))
     = (Status.Failed "exit=1: traceback" : Status.builds Status.outcome));
  (match (M.outcome_of_admission (Ok (`Busy Keeper_owner.Admission_paused))
          : Status.builds Status.outcome) with
   | Status.Deferred _ -> ()
   | Status.Reclaimed _ | Status.Not_running | Status.Failed _ ->
     Alcotest.fail "a busy Keeper was not deferred");
  match (M.outcome_of_admission
           (Error (Keeper_owner_registry.Command_lookup_failed
                     (Keeper_owner_registry.Owner_not_found "gone")))
         : Status.builds Status.outcome) with
  | Status.Failed _ -> ()
  | Status.Reclaimed _ | Status.Deferred _ | Status.Not_running ->
    Alcotest.fail "a refused command was not recorded as failed"

(* No Owner inventory is installed for the fixture's base path and no meta is
   stored, so neither step reaches a guest or an endpoint: both end at the
   server, and the loop keeps a row for each. *)
let test_refused_attempt_leaves_a_failed_row () =
  with_fixture (fun config _profile _seed ->
    let module M = Server_keeper_build_maintenance in
    let module Status = Keeper_cleanup_status in
    let module Step = Keeper_cleanup_step in
    M.attempt_steps ~config ~keeper_name:"absent-owner" Step.all ();
    let rows = List.filter
        (fun (row : Status.row) -> String.equal row.keeper "absent-owner")
        (M.current ()).rows in
    let names steps = List.sort String.compare (List.map Step.to_string steps) in
    Alcotest.(check (list string)) "every step left a row" (names Step.all)
      (names (List.map (fun (row : Status.row) -> Status.step row.attempt) rows));
    List.iter (fun (row : Status.row) ->
      (match row.attempt with
       | Status.Guest_builds (Status.Failed _) | Status.Remote_workspace (Status.Failed _) -> ()
       | Status.Guest_builds (Status.Reclaimed _ | Status.Deferred _ | Status.Not_running)
       | Status.Remote_workspace (Status.Reclaimed _ | Status.Deferred _ | Status.Not_running) ->
         Alcotest.failf "%s was not recorded as failed"
           (Step.to_string (Status.step row.attempt)));
      Alcotest.(check bool) "nothing ran to its end" true
        (Option.is_none row.reclaimed_at))
      rows)

let test_server_always_applies_the_workspace_payload () =
  Alcotest.(check (list string)) "argv"
    [ "python3"; "-"; "--root"; "/masc-work/keeper"; "--retention-sec"; "172800."; "--apply" ]
    (Keeper_remote_workspace_cleanup.payload_argv ~root:"/masc-work/keeper"
       ~retention_sec:172800.)

let test_slow_keeper_does_not_block_another_cleanup () =
  Eio_main.run @@ fun _env ->
  let running = Server_keeper_build_maintenance.create_running () in
  Eio.Switch.run @@ fun sw ->
  let started, mark_started = Eio.Promise.create () in
  let release, allow_release = Eio.Promise.create () in
  let other, mark_other = Eio.Promise.create () in
  let duplicate = ref false in
  Alcotest.(check bool) "first attempt is scheduled" true
    (Server_keeper_build_maintenance.schedule ~sw ~running ~keeper_name:"slow" (fun () ->
       Eio.Promise.resolve mark_started ();
       Eio.Promise.await release));
  Eio.Promise.await started;
  Alcotest.(check bool) "second attempt reports the one still running" false
    (Server_keeper_build_maintenance.schedule ~sw ~running ~keeper_name:"slow"
       (fun () -> duplicate := true));
  Alcotest.(check bool) "another Keeper is scheduled" true
    (Server_keeper_build_maintenance.schedule ~sw ~running ~keeper_name:"other"
       (fun () -> Eio.Promise.resolve mark_other ()));
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
     ignore
       (Server_keeper_build_maintenance.schedule ~sw ~running ~keeper_name:"cancelled"
          (fun () -> Fun.protect
            ~finally:(fun () -> joined := true)
            (fun () -> Eio.Promise.resolve mark_started (); Eio.Fiber.await_cancel ()))
        : bool);
     Eio.Promise.await started;
     Eio.Switch.fail sw Stop_cleanup_fixture)
   with Stop_cleanup_fixture -> ());
  Alcotest.(check bool) "cancelled callback joined before scope returns" true !joined;
  let reran = ref false in
  Eio.Switch.run (fun sw ->
    Alcotest.(check bool) "released reservation is scheduled again" true
      (Server_keeper_build_maintenance.schedule ~sw ~running ~keeper_name:"cancelled"
         (fun () -> reran := true)));
  Alcotest.(check bool) "next scope can schedule the Keeper again" true !reran

let test_first_pass_waits_one_delay_and_later_ones_their_interval () =
  Eio_main.run @@ fun _env ->
  let clock = Eio_mock.Clock.make () in
  let passes = ref 0 in
  let passes_at time =
    Eio_mock.Clock.set_time clock time;
    (* The woken loop runs its pass and reaches its next sleep. *)
    Eio.Fiber.yield ();
    !passes
  in
  try
    Eio.Switch.run (fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
        Server_keeper_build_maintenance.run_passes ~clock ~first_delay_sec:60. (fun () ->
          incr passes;
          (* Each pass names its own wait. The second names a shorter one. *)
          if !passes = 1 then 3600. else 600.));
      Alcotest.(check int) "no pass before the first delay" 0 (passes_at 59.);
      Alcotest.(check int) "the first pass at the first delay" 1 (passes_at 60.);
      Alcotest.(check int) "no pass inside the interval" 1 (passes_at 3659.);
      Alcotest.(check int) "the second pass one interval later" 2 (passes_at 3660.);
      Alcotest.(check int) "no pass inside the second interval" 2 (passes_at 4259.);
      Alcotest.(check int) "the third after the wait the second named" 3 (passes_at 4260.);
      Eio.Switch.fail sw Stop_cleanup_fixture)
  with
  | Stop_cleanup_fixture -> ()

let () =
  Alcotest.run "Keeper build maintenance admission"
    [ "metadata", [
      Alcotest.test_case "TOML resolves disk placeholders" `Quick test_cleanup_reads_toml_owned_backend;
      Alcotest.test_case "Step follows the declared profile" `Quick test_step_follows_the_declared_profile;
      Alcotest.test_case "Owner identity must match" `Quick test_cleanup_rejects_other_owner;
      Alcotest.test_case "Profile errors refuse cleanup" `Quick test_cleanup_rejects_invalid_profile;
      Alcotest.test_case "Guest skip reason is not empty success" `Quick test_cleanup_report_keeps_guest_skip_reason;
      Alcotest.test_case "Workspace report counts entries" `Quick test_workspace_report_counts_entries_and_keeps_skip_reason;
      Alcotest.test_case "Each step takes its own switch" `Quick test_each_step_takes_its_own_switch;
      Alcotest.test_case "An admission result becomes an outcome" `Quick test_admission_result_becomes_an_outcome;
      Alcotest.test_case "A refused attempt leaves a failed row" `Quick test_refused_attempt_leaves_a_failed_row;
      Alcotest.test_case "Server applies the workspace payload" `Quick test_server_always_applies_the_workspace_payload;
      Alcotest.test_case "Slow Keeper does not block another cleanup" `Quick test_slow_keeper_does_not_block_another_cleanup;
      Alcotest.test_case "Cancelled cleanup releases its reservation" `Quick test_cancelled_cleanup_releases_its_reservation;
      Alcotest.test_case "The first pass waits one delay, later ones their interval" `Quick test_first_pass_waits_one_delay_and_later_ones_their_interval;
    ] ]
