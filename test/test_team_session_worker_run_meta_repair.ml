module Lib = Masc_mcp
module Oas = Agent_sdk
module U = Yojson.Safe.Util

open Alcotest

let test_counter = ref 0

let temp_dir prefix =
  incr test_counter;
  let dir =
    Filename.temp_file (Printf.sprintf "%s_%d_" prefix !test_counter) ""
  in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let sample_session session_id =
  let now = Unix.gettimeofday () in
  let open Team_session_types in
  {
    session_id;
    goal = "repair worker run meta";
    created_by = "repair-tester";
    origin_kind = Origin_human;
    room_id = "default";
    operation_id = None;
    status = Running;
    duration_seconds = 300;
    execution_scope = Limited_code_change;
    checkpoint_interval_sec = 60;
    min_agents = 1;
    scale_profile = Scale_standard;
    control_profile = Control_flat;
    orchestration_mode = Assist;
    communication_mode = Comm_broadcast;
    model_cascade = [ "glm-5" ];
    fallback_policy = Fallback_none;
    instruction_profile = Profile_standard;
    alert_channel = Alert_broadcast;
    auto_resume = false;
    report_formats = [ Markdown ];
    turn_count = 0;
    agent_names = [ "repair-tester" ];
    planned_workers = [];
    broadcast_count = 0;
    portal_count = 0;
    cascade_attempted = 0;
    cascade_success = 0;
    cascade_failed = 0;
    fallback_task_created = 0;
    min_agents_violation_streak = 0;
    policy_violations = [];
    baseline_done_counts = [];
    final_done_delta_total = None;
    final_done_delta_by_agent = None;
    delivery_contract = None;
    latest_delivery_verdict = None;
    started_at = now -. 10.0;
    planned_end_at = now +. 290.0;
    stopped_at = None;
    last_checkpoint_at = None;
    last_event_at = None;
    last_turn_at = None;
    stop_reason = None;
    generated_report = false;
    artifacts_dir = Filename.concat ".masc/team-sessions" session_id;
    created_at_iso = Types.now_iso ();
    updated_at_iso = Types.now_iso ();
  }

let sample_proof ~(run_id : string) : Oas.Cdal_proof.t =
  {
    schema_version = Oas.Cdal_proof.schema_version_current;
    run_id;
    contract_id = "repair-contract";
    requested_execution_mode = Oas.Execution_mode.Execute;
    effective_execution_mode = Oas.Execution_mode.Execute;
    mode_decision_source = "repair-test";
    risk_class = Oas.Risk_class.Medium;
    provider_snapshot =
      {
        Oas.Cdal_proof.provider_name = "glm";
        model_id = "glm-5";
        api_version = None;
      };
    capability_snapshot =
      {
        Oas.Cdal_proof.tools = [ "file_read"; "file_write"; "shell_exec" ];
        mcp_servers = [];
        max_turns = 8;
        max_tokens = Some 4096;
        thinking_enabled = None;
      };
    tool_trace_refs = [ "proof-store://repair/tool-trace-1" ];
    raw_evidence_refs = [ "proof-store://repair/evidence-1" ];
    checkpoint_ref = Some "proof-store://repair/checkpoint";
    result_status = Oas.Cdal_proof.Completed;
    started_at = 1.0;
    ended_at = 2.0;
    scope = None;
  }

let fake_trace_ref =
  {
    Oas.Raw_trace.worker_run_id = "wr-repair";
    path = "/tmp/repair-trace.jsonl";
    start_seq = 1;
    end_seq = 4;
    agent_name = "worker-a";
    session_id = Some "evidence-session-1";
  }

let fake_oas_evidence =
  {
    Lib.Team_session_worker_run_meta.trace_ref = Some fake_trace_ref;
    trace_summary_json =
      Some
        (`Assoc
          [
            ("run_ref", Oas.Raw_trace.run_ref_to_yojson fake_trace_ref);
            ("event_count", `Int 4);
          ]);
    trace_validation_json =
      Some
        (`Assoc
          [
            ("run_ref", Oas.Raw_trace.run_ref_to_yojson fake_trace_ref);
            ("ok", `Bool true);
          ]);
    worker_json =
      Some
        (`Assoc
          [
            ("worker_run_id", `String "wr-repair");
            ("status", `String "completed");
          ]);
    conformance_json =
      Some
        (`Assoc
          [
            ("summary", `String "ok");
            ("failed_checks", `Int 0);
          ]);
    worker = None;
  }

let with_fixture f =
  let dir = temp_dir "worker_run_meta_repair" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "repair-tester"));
      let session_id = "ts-1234567890000-abcdef123456789" in
      Lib.Team_session_store.ensure_session_dirs config session_id;
      Lib.Team_session_store.save_session config (sample_session session_id);
      f config session_id)

let seed_legacy_meta config session_id worker_run_id =
  Lib.Team_session_store.save_worker_run_meta_json config session_id worker_run_id
    (`Assoc
      [
        ("worker_run_id", `String worker_run_id);
        ("worker_name", `String "worker-a");
        ("mode", `String "swarm");
        ("status", `String "completed");
        ("wait_mode", `String "background");
        ("trace_capability", `String "summary_only");
        ("success", `Bool true);
        ("evidence_session_id", `String "evidence-session-1");
        ("trace_ref", `Null);
        ("trace_summary", `Null);
        ("trace_validation", `Null);
        ("oas_worker_run", `Null);
        ("session_conformance", `Null);
        ("proof_run_id", `Null);
        ("proof_status", `Null);
      ])

let read_meta_json config session_id worker_run_id =
  Lib.Team_session_store.worker_run_meta_path config session_id worker_run_id
  |> Room_utils.read_json config

let read_meta_text config session_id worker_run_id =
  Lib.Team_session_store.worker_run_meta_path config session_id worker_run_id
  |> Room_utils.read_text config

let repair_session_with config session_id ?worker_run_id ~dry_run () =
  Lib.Team_session_worker_run_meta.repair_session_with ~config ~session_id
    ?worker_run_id ~dry_run
    ~load_oas_evidence:(fun ~evidence_session_id ->
      if String.equal evidence_session_id "evidence-session-1" then
        Some fake_oas_evidence
      else
        None)
    ~load_saved_proof:(fun ~session_id:_ ~worker_run_id ->
      if String.equal worker_run_id "wr-repair" then
        Some (sample_proof ~run_id:"repair-proof-1")
      else
        None)
    ()

let test_repair_session_dry_run_and_apply () =
  with_fixture @@ fun config session_id ->
  let worker_run_id = "wr-repair" in
  seed_legacy_meta config session_id worker_run_id;
  let meta_before = read_meta_text config session_id worker_run_id in
  let proof_path =
    Lib.Team_session_store.worker_run_proof_path config session_id worker_run_id
  in
  let dry_run =
    match repair_session_with config session_id ~worker_run_id ~dry_run:true () with
    | Ok summary -> summary
    | Error msg -> fail msg
  in
  check int "dry-run scanned" 1 dry_run.scanned_count;
  check int "dry-run changed" 1 dry_run.changed_count;
  check int "dry-run applied" 0 dry_run.applied_count;
  let dry_item = List.hd dry_run.items in
  check string "dry-run status" "would_repair"
    (Lib.Team_session_worker_run_meta.repair_status_to_string dry_item.status);
  check bool "trace_ref change detected" true
    (List.mem "trace_ref" dry_item.changed_fields);
  check bool "proof_run_id change detected" true
    (List.mem "proof_run_id" dry_item.changed_fields);
  check string "meta unchanged on dry-run" meta_before
    (read_meta_text config session_id worker_run_id);
  check bool "proof absent on dry-run" false (Sys.file_exists proof_path);
  let applied =
    match repair_session_with config session_id ~worker_run_id ~dry_run:false () with
    | Ok summary -> summary
    | Error msg -> fail msg
  in
  check int "apply changed" 1 applied.changed_count;
  check int "apply applied" 1 applied.applied_count;
  let applied_item = List.hd applied.items in
  check string "apply status" "repaired"
    (Lib.Team_session_worker_run_meta.repair_status_to_string
       applied_item.status);
  let repaired_meta = read_meta_json config session_id worker_run_id in
  check bool "trace_ref repaired" true
    (repaired_meta |> U.member "trace_ref" <> `Null);
  check bool "trace_summary repaired" true
    (repaired_meta |> U.member "trace_summary" <> `Null);
  check bool "session_conformance repaired" true
    (repaired_meta |> U.member "session_conformance" <> `Null);
  check string "proof status repaired" "completed"
    (repaired_meta |> U.member "proof_status" |> U.to_string);
  check string "proof run id repaired" "repair-proof-1"
    (repaired_meta |> U.member "proof_run_id" |> U.to_string);
  check bool "proof file written" true (Sys.file_exists proof_path);
  let meta_after_apply = read_meta_text config session_id worker_run_id in
  let second_pass =
    match repair_session_with config session_id ~worker_run_id ~dry_run:false () with
    | Ok summary -> summary
    | Error msg -> fail msg
  in
  check int "second pass changed" 0 second_pass.changed_count;
  let second_item = List.hd second_pass.items in
  check string "second pass status" "unchanged"
    (Lib.Team_session_worker_run_meta.repair_status_to_string
       second_item.status);
  check string "meta unchanged after idempotent rerun" meta_after_apply
    (read_meta_text config session_id worker_run_id)

let test_repair_session_skips_without_recoverable_source () =
  with_fixture @@ fun config session_id ->
  let worker_run_id = "wr-legacy-only" in
  Lib.Team_session_store.save_worker_run_meta_json config session_id worker_run_id
    (`Assoc
      [
        ("worker_run_id", `String worker_run_id);
        ("worker_name", `String "worker-b");
        ("mode", `String "swarm");
        ("status", `String "completed");
        ("wait_mode", `String "background");
        ("success", `Bool true);
        ("trace_ref", `Null);
      ]);
  let meta_before = read_meta_text config session_id worker_run_id in
  let result =
    Lib.Team_session_worker_run_meta.repair_session_with ~config ~session_id
      ~worker_run_id ~dry_run:false
      ~load_oas_evidence:(fun ~evidence_session_id:_ -> None)
      ~load_saved_proof:(fun ~session_id:_ ~worker_run_id:_ -> None)
      ()
  in
  let summary =
    match result with Ok summary -> summary | Error msg -> fail msg
  in
  check int "skip scanned" 1 summary.scanned_count;
  check int "skip count" 1 summary.skipped_count;
  let item = List.hd summary.items in
  check string "skip status" "skipped"
    (Lib.Team_session_worker_run_meta.repair_status_to_string item.status);
  check string "skip reason" "recoverable_source_missing" item.reason;
  check string "meta unchanged" meta_before
    (read_meta_text config session_id worker_run_id)

let () =
  run "team_session_worker_run_meta_repair"
    [
      ( "repair",
        [
          test_case "dry-run then apply is idempotent" `Quick
            test_repair_session_dry_run_and_apply;
          test_case "skip without recoverable source" `Quick
            test_repair_session_skips_without_recoverable_source;
        ] );
    ]
