(** Test Metrics_store_eio Module - Pure Synchronous Tests *)

open Masc

let () = Random.init 42

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_masc_dir f =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-metrics-eio-%d-%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000000.)))
  in
  Unix.mkdir base 0o755;
  let config = Workspace.default_config base in
  let _ = Workspace.init config ~agent_name:None in
  try
    let result = f config in
    let _ = Workspace.reset config in
    rm_rf base;
    result
  with e ->
    let _ = Workspace.reset config in
    rm_rf base;
    raise e

let record_ok config metric =
  match Metrics_store_eio.record config metric with
  | Ok Metrics_store_eio.Written -> ()
  | Ok Enqueued -> Metrics_store_eio.flush_pending ()
  | Error error -> failwith (Metrics_store_eio.record_error_to_string error)

let test_create_metric () =
  let metric = Metrics_store_eio.create_metric
    ~agent_id:"claude"
    ~task_id:"task-001"
    ~collaborators:["gemini"]
    ()
  in
  assert (metric.agent_id = "claude");
  assert (metric.task_id = "task-001");
  assert (List.mem "gemini" metric.collaborators);
  assert (metric.success = false);  (* Default *)
  assert (Option.is_none metric.completed_at);
  print_endline "✓ test_create_metric passed"

let test_complete_metric () =
  let metric = Metrics_store_eio.create_metric
    ~agent_id:"gemini"
    ~task_id:"task-002"
    ()
  in
  let completed = Metrics_store_eio.complete_metric metric
    ~success:true
    ~handoff_to:"codex"
    ()
  in
  assert (completed.success = true);
  assert (Option.is_some completed.completed_at);
  assert (completed.handoff_to = Some "codex");
  print_endline "✓ test_complete_metric passed"

let read_ok = function
  | Ok value -> value
  | Error error -> failwith (Metrics_store_eio.read_error_to_string error)

let test_record_and_get () =
  with_temp_masc_dir (fun config ->
    (* Create and record a metric *)
    let metric = Metrics_store_eio.create_metric
      ~agent_id:"claude"
      ~task_id:"task-record"
      ()
    in
    let completed = Metrics_store_eio.complete_metric metric ~success:true () in
    record_ok config completed;

    (* Get recent metrics *)
    let recent = read_ok (Metrics_store_eio.get_recent config ~agent_id:"claude" ~days:1) in
    assert (List.length recent >= 1);

    (* Find our metric *)
    let found = List.exists (fun m -> m.Metrics_store_eio.task_id = "task-record") recent in
    assert found
  );
  print_endline "✓ test_record_and_get passed"

let test_calculate_agent_metrics () =
  with_temp_masc_dir (fun config ->
    (* Record several metrics *)
    for i = 1 to 5 do
      let metric = Metrics_store_eio.create_metric
        ~agent_id:"claude"
        ~task_id:(Printf.sprintf "calc-task-%d" i)
        ()
      in
      let success = (i mod 2 = 0) in  (* Alternate success/fail *)
      let completed = Metrics_store_eio.complete_metric metric ~success () in
      record_ok config completed
    done;

    (* Calculate aggregated metrics *)
    match read_ok (Metrics_store_eio.calculate_agent_metrics config ~agent_id:"claude" ~days:1) with
    | Some metrics ->
      assert (metrics.total_tasks = 5);
      (* completed_tasks counts successful tasks: i=2 and i=4 (even numbers) *)
      assert (metrics.completed_tasks = 2);
      (* task_completion_rate = successful / total = 2/5 = 0.4 *)
      assert (metrics.task_completion_rate >= 0.3 && metrics.task_completion_rate <= 0.5);
      print_endline (Printf.sprintf "  Completion rate: %.1f%%" (metrics.task_completion_rate *. 100.0))
    | None -> failwith "Expected to get agent metrics"
  );
  print_endline "✓ test_calculate_agent_metrics passed"

let test_get_all_agents () =
  with_temp_masc_dir (fun config ->
    (* Record metrics for multiple agents *)
    let agents = ["claude"; "gemini"; "codex"] in
    List.iter (fun agent ->
      let metric = Metrics_store_eio.create_metric
        ~agent_id:agent
        ~task_id:(Printf.sprintf "%s-task" agent)
        ()
      in
      let completed = Metrics_store_eio.complete_metric metric ~success:true () in
      record_ok config completed
    ) agents;

    (* Get all agents *)
    let all = read_ok (Metrics_store_eio.get_all_agents config) in
    assert (List.length all = 3);
    List.iter (fun a -> assert (List.mem a all)) agents
  );
  print_endline "✓ test_get_all_agents passed"

let test_collaborators () =
  with_temp_masc_dir (fun config ->
    let metric = Metrics_store_eio.create_metric
      ~agent_id:"claude"
      ~task_id:"collab-task"
      ~collaborators:["gemini"; "codex"]
      ()
    in
    let completed = Metrics_store_eio.complete_metric metric ~success:true () in
    record_ok config completed;

    match read_ok (Metrics_store_eio.calculate_agent_metrics config ~agent_id:"claude" ~days:1) with
    | Some metrics ->
      assert (List.mem "gemini" metrics.unique_collaborators);
      assert (List.mem "codex" metrics.unique_collaborators)
    | None -> failwith "Expected metrics"
  );
  print_endline "✓ test_collaborators passed"

let test_handoff_tracking () =
  with_temp_masc_dir (fun config ->
    (* Record handoff metrics *)
    let m1 = Metrics_store_eio.create_metric
      ~agent_id:"claude"
      ~task_id:"handoff-1"
      ~handoff_from:"gemini"
      ()
    in
    let c1 = Metrics_store_eio.complete_metric m1 ~success:true () in
    record_ok config c1;

    let m2 = Metrics_store_eio.create_metric
      ~agent_id:"claude"
      ~task_id:"handoff-2"
      ()
    in
    let c2 = Metrics_store_eio.complete_metric m2 ~success:true ~handoff_to:"codex" () in
    record_ok config c2;

    match read_ok (Metrics_store_eio.calculate_agent_metrics config ~agent_id:"claude" ~days:1) with
    | Some metrics ->
      assert (metrics.handoff_success_rate = 1.0);  (* Both handoffs successful *)
      print_endline (Printf.sprintf "  Handoff success rate: %.0f%%" (metrics.handoff_success_rate *. 100.0))
    | None -> failwith "Expected metrics"
  );
  print_endline "✓ test_handoff_tracking passed"

let test_source_observations () =
  with_temp_masc_dir (fun config ->
    assert (read_ok (Metrics_store_eio.calculate_agent_metrics config ~agent_id:"absent" ~days:1) = None);
    let metric = Metrics_store_eio.create_metric ~agent_id:"Exact" ~task_id:"observed" () in
    record_ok config metric;
    assert (Option.is_some (read_ok (Metrics_store_eio.calculate_agent_metrics config ~agent_id:"Exact" ~days:1)));
    assert (read_ok (Metrics_store_eio.calculate_agent_metrics config ~agent_id:" Exact " ~days:1) = None);
    assert (read_ok (Metrics_store_eio.get_recent config ~agent_id:"../Exact" ~days:1) = []);
    let dir = Metrics_store_eio.agent_metrics_dir config "Exact" in
    let file = Filename.concat dir "corrupt.jsonl" in
    Fs_compat.save_file file "not-json\n";
    (match Metrics_store_eio.calculate_agent_metrics config ~agent_id:"Exact" ~days:1 with
     | Error (Metrics_store_eio.Invalid_record { line = 1; _ }) -> ()
     | Error _ | Ok _ -> failwith "corrupt sibling became partial metrics");
    Fs_compat.save_file file (Yojson.Safe.to_string
      (Metrics_store_eio.task_metric_to_yojson { metric with agent_id = "Other" }) ^ "\n");
    (match Metrics_store_eio.calculate_agent_metrics config ~agent_id:"Exact" ~days:1 with
     | Error (Metrics_store_eio.Invalid_record _) -> ()
     | Error _ | Ok _ -> failwith "another identity was accepted");
    Sys.remove file;
    Unix.symlink "/missing-metric-target" file;
    (match Metrics_store_eio.calculate_agent_metrics config ~agent_id:"Exact" ~days:1 with
     | Error (Metrics_store_eio.Source_unavailable _) -> ()
     | Error _ | Ok _ -> failwith "unreadable captured file became absence");
    Unix.unlink file)

let test_exact_storage_identity () =
  with_temp_masc_dir (fun config ->
    let names = ["team/agent"; "Exact"; "exact"; " Exact "; "../outside";
      "/absolute/name"; "한글/에이전트"; "é"; "e\204\129"; String.make 1024 'x'; "nul\000name"] in
    List.iter (fun agent_id ->
      record_ok config (Metrics_store_eio.create_metric ~agent_id ~task_id:"real-record" ());
      let rows = read_ok (Metrics_store_eio.get_recent config ~agent_id ~days:1) in
      assert (List.length rows = 1);
      assert (List.for_all (fun (row : Metrics_store_eio.task_metric) -> row.agent_id = agent_id) rows);
      assert (Filename.dirname (Metrics_store_eio.agent_metrics_dir config agent_id)
        = Filename.concat (Workspace.masc_dir config) "metrics")
    ) names;
    assert (read_ok (Metrics_store_eio.get_all_agents config) = List.sort_uniq String.compare names);
    let identity = Filename.concat (Metrics_store_eio.agent_metrics_dir config "Exact") "identity.json" in
    let corrupt = "{\"schema\":\"masc.agent-metric-identity/v1\",\"agent_id\":\"Other\"}\n" in
    Fs_compat.save_file identity corrupt;
    (match Metrics_store_eio.get_recent config ~agent_id:"Exact" ~days:1 with
     | Error (Metrics_store_eio.Source_unavailable _) -> ()
     | Error _ | Ok _ -> failwith "foreign identity binding became success");
    (match Metrics_store_eio.record config (Metrics_store_eio.create_metric ~agent_id:"Exact" ~task_id:"must-not-append" ()) with
     | Error (Metrics_store_eio.Metric_store_failure _) -> ()
     | Error _ | Ok _ -> failwith "conflicting binding was overwritten");
    assert (Fs_compat.load_file identity = corrupt))

let test_unbound_store_is_not_adopted () =
  with_temp_masc_dir (fun config ->
    let metrics_root = Filename.concat (Workspace.masc_dir config) "metrics" in
    Fs_compat.mkdir_p (Filename.concat metrics_root "unbound-agent");
    (match Metrics_store_eio.get_recent config ~agent_id:"unbound-agent" ~days:1 with
     | Error (Metrics_store_eio.Source_unavailable _) -> ()
     | Error _ | Ok _ -> failwith "unbound nonempty store became absence");
    (match Metrics_store_eio.record config (Metrics_store_eio.create_metric ~agent_id:"unbound-agent" ~task_id:"task" ()) with
     | Error (Metrics_store_eio.Metric_store_failure _) -> ()
     | Error _ | Ok _ -> failwith "unbound nonempty store was adopted");
    assert (not (Fs_compat.file_exists (Filename.concat metrics_root "store.json"))))

let test_concurrent_first_records () =
  with_temp_masc_dir (fun config ->
    let agent_id = "concurrent/agent" in
    let record task_id () =
      record_ok config (Metrics_store_eio.create_metric ~agent_id ~task_id ()) in
    Eio.Fiber.both (record "first") (record "second");
    let rows = read_ok (Metrics_store_eio.get_recent config ~agent_id ~days:1) in
    assert (List.sort String.compare (List.map (fun (row : Metrics_store_eio.task_metric) -> row.task_id) rows)
      = ["first"; "second"]);
    assert (read_ok (Metrics_store_eio.get_all_agents config) = [agent_id]);
    let path = Filename.concat (Metrics_store_eio.agent_metrics_dir config agent_id) "identity.json" in
    Fs_compat.save_file path "";
    (match Metrics_store_eio.record config (Metrics_store_eio.create_metric ~agent_id ~task_id:"rejected" ()) with
     | Error (Metrics_store_eio.Metric_store_failure _) -> ()
     | Error _ | Ok _ -> failwith "an empty existing binding was adopted");
    assert (Fs_compat.load_file path = ""))

let test_generate_id () =
  let ids = List.init 128 (fun _ -> Metrics_store_eio.generate_id ()) in
  let unique_ids = List.sort_uniq String.compare ids in
  assert (List.length ids = List.length unique_ids);
  assert (String.length (List.hd ids) > 10);
  print_endline "✓ test_generate_id passed"

let test_filter_recent_month_filenames () =
  let filenames =
    [
      "2025-12.jsonl";
      "2026-01.jsonl";
      "2026-02.jsonl";
      "2026-03.jsonl";
      "2026-04.jsonl";
      "notes.jsonl";
    ]
  in
  let filtered =
    Metrics_store_eio.filter_recent_month_filenames
      ~now:1_775_091_200.0
      ~days:7
      filenames
  in
  let expected = [ "2026-03.jsonl"; "2026-04.jsonl"; "notes.jsonl" ] in
  assert (filtered = expected);
  print_endline "✓ test_filter_recent_month_filenames passed"

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  print_endline "\n=== Metrics_store_eio Tests ===\n";
  test_create_metric ();
  test_complete_metric ();
  test_record_and_get ();
  test_calculate_agent_metrics ();
  test_get_all_agents ();
  test_collaborators ();
  test_handoff_tracking ();
  test_source_observations ();
  test_exact_storage_identity ();
  test_unbound_store_is_not_adopted ();
  test_concurrent_first_records ();
  test_generate_id ();
  test_filter_recent_month_filenames ();
  print_endline "\n✅ All Metrics_store_eio tests passed!\n"
