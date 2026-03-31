open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_mdal_store_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let dummy_profile () : Mdal.profile =
  {
    Mdal.name = "custom";
    metric_fn = "printf '0.5\\n'";
    goal = { Bounded.path = "metric"; condition = Bounded.Gte 0.9 };
    target = "round-trip";
    reference = Some "/tmp/reference.txt";
    agent = "claude";
    max_iterations = 5;
    max_time_seconds = Some 60.0;
    stagnation_threshold = 0.01;
    stagnation_count = 3;
    heuristics = "small, measurable changes";
    tools_allow = [ "rg" ];
    tools_deny = [ "rm" ];
  }

let dummy_state () : Mdal.loop_state =
  let now = Time_compat.now () in
  {
    Mdal.loop_id = "mdal-store-test";
    profile = dummy_profile ();
    status = `Interrupted;
    error_message = None;
    stop_reason = Some "server_restart";
    current_iteration = 2;
    history =
      [
        {
          Mdal.iteration = 2;
          metric_before = 0.5;
          metric_after = 0.55;
          delta = 0.05;
          changes = "added one test";
          failed_attempts = "";
          next_suggestion = "keep going";
          elapsed_ms = 120;
          cost_usd = Some 0.01;
          evidence = None;
        };
      ];
    strict_mode = false;
    stagnation_streak = 1;
    baseline_metric = 0.5;
    start_time = now -. 30.0;
    updated_at = now;
    stopped_at = None;
    execution_mode = `Manual_only;
    worker_engine = None;
    worker_model = None;
  }

let test_round_trip () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let state = dummy_state () in
  Mdal_store.save_loop config state;
  let loaded =
    match Mdal_store.load_loop config state.loop_id with
    | Some loop -> loop
    | None -> Alcotest.fail "expected persisted loop"
  in
  Alcotest.(check string) "loop id" state.loop_id loaded.loop_id;
  Alcotest.(check string) "status" "interrupted"
    (Mdal.status_to_string loaded.status);
  Alcotest.(check string) "stop reason" "server_restart"
    (loaded.stop_reason |> Option.value ~default:"");
  Alcotest.(check string) "reference preserved" "/tmp/reference.txt"
    (loaded.profile.reference |> Option.value ~default:"");
  Alcotest.(check int) "history preserved" 1 (List.length loaded.history);
  Alcotest.(check string) "execution mode" "manual_only"
    (Mdal.execution_mode_to_string loaded.execution_mode);
  cleanup_dir base_dir

let test_latest_pointer_and_listing () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let state_a = dummy_state () in
  let state_b = { state_a with loop_id = "mdal-store-test-b"; status = `Running } in
  Mdal_store.save_loop config state_a;
  Mdal_store.save_loop config state_b;
  Mdal_store.save_latest_loop_id config state_b.loop_id;
  let latest =
    Mdal_store.load_latest_loop_id config |> Option.value ~default:""
  in
  Alcotest.(check string) "latest pointer" state_b.loop_id latest;
  let listed = Mdal_store.list_loops config in
  Alcotest.(check int) "list size" 2 (List.length listed);
  let ids =
    listed
    |> List.map (fun (state : Mdal.loop_state) -> state.loop_id)
    |> List.sort String.compare
  in
  Alcotest.(check (list string)) "ids"
    [ "mdal-store-test"; "mdal-store-test-b" ] ids;
  cleanup_dir base_dir

let () =
  Alcotest.run "Mdal_store"
    [
      ( "persistence",
        [
          Alcotest.test_case "round trip" `Quick test_round_trip;
          Alcotest.test_case "latest pointer and listing" `Quick
            test_latest_pointer_and_listing;
        ] );
    ]
