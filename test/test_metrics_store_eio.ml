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

let test_create_metric () =
  let metric = Metrics_store_eio.create_metric
    ~agent_id:"agent_llm_a"
    ~task_id:"task-001"
    ~collaborators:["provider_f"]
    ()
  in
  assert (metric.agent_id = "agent_llm_a");
  assert (metric.task_id = "task-001");
  assert (List.mem "provider_f" metric.collaborators);
  assert (metric.success = false);  (* Default *)
  assert (Option.is_none metric.completed_at);
  print_endline "✓ test_create_metric passed"

let test_complete_metric () =
  let metric = Metrics_store_eio.create_metric
    ~agent_id:"provider_f"
    ~task_id:"task-002"
    ()
  in
  let completed = Metrics_store_eio.complete_metric metric
    ~success:true
    ~handoff_to:"agent_code"
    ()
  in
  assert (completed.success = true);
  assert (Option.is_some completed.completed_at);
  assert (completed.handoff_to = Some "agent_code");
  print_endline "✓ test_complete_metric passed"

let test_record_and_get () =
  with_temp_masc_dir (fun config ->
    (* Create and record a metric *)
    let metric = Metrics_store_eio.create_metric
      ~agent_id:"agent_llm_a"
      ~task_id:"task-record"
      ()
    in
    let completed = Metrics_store_eio.complete_metric metric ~success:true () in
    Metrics_store_eio.record config completed;

    (* Get recent metrics *)
    let recent = Metrics_store_eio.get_recent config ~agent_id:"agent_llm_a" ~days:1 in
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
        ~agent_id:"agent_llm_a"
        ~task_id:(Printf.sprintf "calc-task-%d" i)
        ()
      in
      let success = (i mod 2 = 0) in  (* Alternate success/fail *)
      let completed = Metrics_store_eio.complete_metric metric ~success () in
      Metrics_store_eio.record config completed
    done;

    (* Calculate aggregated metrics *)
    match Metrics_store_eio.calculate_agent_metrics config ~agent_id:"agent_llm_a" ~days:1 with
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
    let agents = ["agent_llm_a"; "provider_f"; "agent_code"] in
    List.iter (fun agent ->
      let metric = Metrics_store_eio.create_metric
        ~agent_id:agent
        ~task_id:(Printf.sprintf "%s-task" agent)
        ()
      in
      let completed = Metrics_store_eio.complete_metric metric ~success:true () in
      Metrics_store_eio.record config completed
    ) agents;

    (* Get all agents *)
    let all = Metrics_store_eio.get_all_agents config in
    assert (List.length all = 3);
    List.iter (fun a -> assert (List.mem a all)) agents
  );
  print_endline "✓ test_get_all_agents passed"

let test_collaborators () =
  with_temp_masc_dir (fun config ->
    let metric = Metrics_store_eio.create_metric
      ~agent_id:"agent_llm_a"
      ~task_id:"collab-task"
      ~collaborators:["provider_f"; "agent_code"]
      ()
    in
    let completed = Metrics_store_eio.complete_metric metric ~success:true () in
    Metrics_store_eio.record config completed;

    match Metrics_store_eio.calculate_agent_metrics config ~agent_id:"agent_llm_a" ~days:1 with
    | Some metrics ->
      assert (List.mem "provider_f" metrics.unique_collaborators);
      assert (List.mem "agent_code" metrics.unique_collaborators)
    | None -> failwith "Expected metrics"
  );
  print_endline "✓ test_collaborators passed"

let test_handoff_tracking () =
  with_temp_masc_dir (fun config ->
    (* Record handoff metrics *)
    let m1 = Metrics_store_eio.create_metric
      ~agent_id:"agent_llm_a"
      ~task_id:"handoff-1"
      ~handoff_from:"provider_f"
      ()
    in
    let c1 = Metrics_store_eio.complete_metric m1 ~success:true () in
    Metrics_store_eio.record config c1;

    let m2 = Metrics_store_eio.create_metric
      ~agent_id:"agent_llm_a"
      ~task_id:"handoff-2"
      ()
    in
    let c2 = Metrics_store_eio.complete_metric m2 ~success:true ~handoff_to:"agent_code" () in
    Metrics_store_eio.record config c2;

    match Metrics_store_eio.calculate_agent_metrics config ~agent_id:"agent_llm_a" ~days:1 with
    | Some metrics ->
      assert (metrics.handoff_success_rate = 1.0);  (* Both handoffs successful *)
      print_endline (Printf.sprintf "  Handoff success rate: %.0f%%" (metrics.handoff_success_rate *. 100.0))
    | None -> failwith "Expected metrics"
  );
  print_endline "✓ test_handoff_tracking passed"

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
  test_generate_id ();
  test_filter_recent_month_filenames ();
  print_endline "\n✅ All 9 Metrics_store_eio tests passed!\n"
