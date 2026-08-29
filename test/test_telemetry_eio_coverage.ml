(** Telemetry Eio Module Coverage Tests

    Tests for telemetry event types with deriving yojson:
    - event type variants
    - event_record type
    - JSON roundtrip tests
*)

open Alcotest

module Telemetry_eio = Masc.Telemetry_eio
module Workspace = Masc.Workspace
module Otel_metric_store = Masc.Otel_metric_store

let error_kind value = Telemetry_eio.error_kind_of_string value
let error_kind_to_string = Telemetry_eio.error_kind_to_string

let temp_dir () =
  let dir = Filename.temp_file "test_telemetry_eio_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  let restore () =
    match prior with
    | Some old -> Unix.putenv key old
    | None -> Unix.putenv key ""
  in
  match f () with
  | result ->
      restore ();
      result
  | exception exn ->
      restore ();
      raise exn

let with_temp_dir f =
  let dir = temp_dir () in
  match f dir with
  | result ->
      cleanup_dir dir;
      result
  | exception exn ->
      cleanup_dir dir;
      raise exn

let telemetry_dir base_dir =
  Filename.concat (Filename.concat base_dir ".masc") "telemetry"

let write_dated_file dir month day lines =
  let month_dir = Filename.concat dir month in
  Fs_compat.mkdir_p month_dir;
  Fs_compat.append_file
    (Filename.concat month_dir (day ^ ".jsonl"))
    (String.concat "\n" lines ^ "\n")

(* ============================================================
   event Type Tests
   ============================================================ *)

let test_event_agent_session_bounded () =
  let e = Telemetry_eio.Agent_session_bound {
    agent_id = "claude-001";
    capabilities = ["code"; "review"];
  } in
  match e with
  | Telemetry_eio.Agent_session_bound r ->
      check string "agent_id" "claude-001" r.agent_id;
      check int "capabilities" 2 (List.length r.capabilities)
  | _ -> fail "expected Agent_session_bound"

let test_event_agent_unbound () =
  let e = Telemetry_eio.Agent_unbound {
    agent_id = "claude-001";
    reason = "session ended";
  } in
  match e with
  | Telemetry_eio.Agent_unbound r ->
      check string "reason" "session ended" r.reason
  | _ -> fail "expected Agent_unbound"

let test_event_task_started () =
  let e = Telemetry_eio.Task_started {
    task_id = "task-001";
    agent_id = "claude-001";
  } in
  match e with
  | Telemetry_eio.Task_started r ->
      check string "task_id" "task-001" r.task_id
  | _ -> fail "expected Task_started"

let test_event_task_completed () =
  let e = Telemetry_eio.Task_completed {
    task_id = "task-001";
    duration_ms = 5000;
    success = true;
  } in
  match e with
  | Telemetry_eio.Task_completed r ->
      check int "duration_ms" 5000 r.duration_ms;
      check bool "success" true r.success
  | _ -> fail "expected Task_completed"

let test_event_error_occurred () =
  let e = Telemetry_eio.Error_occurred {
    code = "E001";
    message = "Something failed";
    context = "test";
  } in
  match e with
  | Telemetry_eio.Error_occurred r ->
      check string "code" "E001" r.code;
      check string "message" "Something failed" r.message
  | _ -> fail "expected Error_occurred"

let test_event_tool_called () =
  let e = Telemetry_eio.Tool_called {
    tool_name = "masc_status";
    success = true;
    duration_ms = 100;
    agent_id = Some "claude-001";
    source = Some "external_mcp";
    session_id = Some "mcp-session-1";
    operation_id = Some "op-1";
    worker_run_id = Some "run-1";
    execution_id = None;
    error_kind = Some (error_kind "timeout");
    error_message = Some "timed out after 30s";
    exit_code = None;
    stderr_excerpt = None;
    failure_class = None;
  } in
  match e with
  | Telemetry_eio.Tool_called r ->
      check string "tool_name" "masc_status" r.tool_name;
      check bool "success" true r.success;
      check (option string) "session_id" (Some "mcp-session-1") r.session_id;
      check (option string) "operation_id" (Some "op-1") r.operation_id;
      check (option string) "worker_run_id" (Some "run-1") r.worker_run_id;
      check (option string) "error_kind" (Some "timeout")
        (Option.map error_kind_to_string r.error_kind);
      check (option string) "error_message" (Some "timed out after 30s")
        r.error_message
  | _ -> fail "expected Tool_called"

(* ============================================================
   event_record Type Tests
   ============================================================ *)

let test_event_record_type () =
  let r : Telemetry_eio.event_record = {
    timestamp = 1704067200.0;
    event = Telemetry_eio.Agent_session_bound {
      agent_id = "test";
      capabilities = [];
    };
  } in
  check (float 0.1) "timestamp" 1704067200.0 r.timestamp

let check_one_tool_called_record label json ~operation_id ~worker_run_id =
  match Telemetry_eio.parse_event_records [json] with
  | [ record ] -> (
      match record.event with
      | Telemetry_eio.Tool_called r ->
          check string (label ^ " tool_name") "tool_execute" r.tool_name;
          check bool (label ^ " success") false r.success;
          check int (label ^ " duration_ms") 658 r.duration_ms;
          check (option string) (label ^ " agent_id")
            (Some "keeper-omicron-improver-agent") r.agent_id;
          check (option string) (label ^ " operation_id") operation_id
            r.operation_id;
          check (option string) (label ^ " worker_run_id") worker_run_id
            r.worker_run_id
      | _ -> fail (label ^ ": expected Tool_called"))
  | records ->
      fail
        (Printf.sprintf "%s: expected one parsed record, got %d" label
           (List.length records))

let test_parse_event_records_tool_called_null_options () =
  let json =
    `Assoc
      [
        ("timestamp", `Float 1777120367.858374);
        ( "event",
          `List
            [
              `String "Tool_called";
              `Assoc
                [
                  ("tool_name", `String "tool_execute");
                  ("success", `Bool false);
                  ("duration_ms", `Int 658);
                  ("agent_id", `String "keeper-omicron-improver-agent");
                  ("source", `String "keeper_internal");
                  ("session_id", `String "mcp-session");
                  ("operation_id", `Null);
                  ("worker_run_id", `Null);
                ];
            ] );
      ]
  in
  check_one_tool_called_record "null options" json ~operation_id:None
    ~worker_run_id:None

let test_parse_event_records_tool_called_missing_options () =
  let json =
    `Assoc
      [
        ("timestamp", `Int 1777120367);
        ( "event",
          `List
            [
              `String "Tool_called";
              `Assoc
                [
                  ("tool_name", `String "tool_execute");
                  ("success", `Bool false);
                  ("duration_ms", `Int 658);
                  ("agent_id", `String "keeper-omicron-improver-agent");
                  ("source", `String "keeper_internal");
                  ("session_id", `String "mcp-session");
                ];
            ] );
      ]
  in
  check_one_tool_called_record "missing options" json ~operation_id:None
    ~worker_run_id:None

let test_parse_event_records_legacy_transient_failure_class () =
  let json =
    `Assoc
      [ "timestamp", `Float 1777120367.858374
      ; ( "event"
        , `List
            [ `String "Tool_called"
            ; `Assoc
                [ "tool_name", `String "tool_execute"
                ; "success", `Bool false
                ; "duration_ms", `Int 658
                ; "failure_class", `List [ `String "Transient_error" ]
                ]
            ] )
      ]
  in
  match Telemetry_eio.parse_event_records [ json ] with
  | [ { event = Telemetry_eio.Tool_called event; _ } ] ->
    Alcotest.(check (option string))
      "legacy constructor is preserved as dependency_unavailable"
      (Some "dependency_unavailable")
      (Option.map Tool_result.tool_failure_class_to_string event.failure_class);
    let canonical = Telemetry_eio.event_to_json (Telemetry_eio.Tool_called event) in
    let failure_class =
      let open Yojson.Safe.Util in
      canonical |> member "event" |> index 1 |> member "failure_class"
    in
    Alcotest.(check string)
      "rewritten row uses the canonical derived constructor"
      {|["Dependency_unavailable"]|}
      (Yojson.Safe.to_string failure_class);
    (match Telemetry_eio.parse_event_records [ canonical ] with
     | [ { event = Telemetry_eio.Tool_called _; _ } ] -> ()
     | records ->
       Alcotest.failf
         "expected canonical round-trip row, got %d"
         (List.length records))
  | records ->
    Alcotest.failf
      "expected one legacy Tool_called record, got %d"
      (List.length records)
;;

let check_one_tool_assigned_record label json =
  match Telemetry_eio.parse_event_records [json] with
  | [ record ] -> (
      match record.event with
      | Telemetry_eio.Tool_assigned r ->
          check string (label ^ " agent_id")
            "keeper-omicron-improver-agent" r.agent_id;
          check string (label ^ " profile") "default" r.profile;
          check int (label ^ " tool_count") 32 r.tool_count;
          check string (label ^ " assignment_id") "asg-001" r.assignment_id
      | _ -> fail (label ^ ": expected Tool_assigned"))
  | records ->
      fail
        (Printf.sprintf "%s: expected one parsed record, got %d" label
           (List.length records))

let test_parse_event_records_tool_assigned_minimal_payload () =
  let json =
    `Assoc
      [
        ("timestamp", `Float 1777120367.858374);
        ( "event",
          `List
            [
              `String "Tool_assigned";
              `Assoc
                [
                  ("agent_id", `String "keeper-omicron-improver-agent");
                  ("profile", `String "default");
                  ("tool_count", `Int 32);
                  ("assignment_id", `String "asg-001");
                ];
            ] );
      ]
  in
  check_one_tool_assigned_record "minimal payload" json

let test_parse_event_records_tool_assigned_missing_optional_fields () =
  let json =
    `Assoc
      [
        ("timestamp", `Int 1777120367);
        ( "event",
          `List
            [
              `String "Tool_assigned";
              `Assoc
                [
                  ("agent_id", `String "keeper-omicron-improver-agent");
                  ("profile", `String "default");
                  ("tool_count", `Int 32);
                  ("assignment_id", `String "asg-001");
                ];
            ] );
      ]
  in
  check_one_tool_assigned_record "missing optional fields" json

(* ============================================================
   JSON Roundtrip Tests
   ============================================================ *)

let test_event_json_roundtrip () =
  let original = Telemetry_eio.Task_completed {
    task_id = "task-roundtrip";
    duration_ms = 1234;
    success = true;
  } in
  let json = Telemetry_eio.event_to_yojson original in
  match Telemetry_eio.event_of_yojson json with
  | Ok decoded ->
      (match decoded with
       | Telemetry_eio.Task_completed r ->
           check string "task_id" "task-roundtrip" r.task_id;
           check int "duration_ms" 1234 r.duration_ms
       | _ -> fail "wrong event type")
  | Error e -> fail ("json decode failed: " ^ e)

let test_retired_agent_variants_are_rejected () =
  let row variant payload =
    `Assoc
      [ "timestamp", `Float 1000.0
      ; "event", `List [ `String variant; payload ]
      ]
  in
  let cases =
    [ ( "Agent_joined"
      , `Assoc [ "agent_id", `String "keeper-test"; "capabilities", `List [] ] )
    ; ( "Agent_left"
      , `Assoc [ "agent_id", `String "keeper-test"; "reason", `String "leave" ] )
    ]
  in
  List.iter
    (fun (variant, payload) ->
      check
        int
        (variant ^ " is not repaired")
        0
        (List.length (Telemetry_eio.parse_event_records [ row variant payload ])))
    cases

(* Drop observability: malformed payload increments
   masc_persistence_read_drops_total{surface=telemetry_eio,reason=invalid_payload}.
   Pairs with WARN log via Safe_ops.report_persistence_read_drop. *)
let test_parse_event_records_drop_increments_counter () =
  let metric = Otel_metric_store.metric_persistence_read_drops in
  let labels =
    [
      ("surface", "telemetry_eio");
      ("reason", Read_drop_reason.to_wire Read_drop_reason.Invalid_payload);
    ]
  in
  let before = Otel_metric_store.metric_value_or_zero metric ~labels () in
  let malformed =
    `Assoc
      [
        ("timestamp", `Float 1.0);
        ( "event",
          `List [ `String "Unknown_variant"; `Assoc [ ("x", `Int 1) ] ] );
      ]
  in
  let parsed = Telemetry_eio.parse_event_records [ malformed ] in
  check int "malformed payload produces zero records" 0 (List.length parsed);
  let after = Otel_metric_store.metric_value_or_zero metric ~labels () in
  check (float 0.001) "drop counter incremented by 1" 1.0 (after -. before)

(* ============================================================
   event_to_json Tests
   ============================================================ *)

let test_event_to_json_agent_session_bounded () =
  let e = Telemetry_eio.Agent_session_bound {
    agent_id = "test";
    capabilities = ["a"; "b"];
  } in
  let json = Telemetry_eio.event_to_json e in
  let json_str = Yojson.Safe.to_string json in
  check bool "nonempty" true (String.length json_str > 0);
  check bool "is json" true (String.contains json_str '{')

let test_event_to_json_task_completed () =
  let e = Telemetry_eio.Task_completed {
    task_id = "t1";
    duration_ms = 100;
    success = true;
  } in
  let json = Telemetry_eio.event_to_json e in
  let json_str = Yojson.Safe.to_string json in
  check bool "nonempty" true (String.length json_str > 0);
  check bool "contains timestamp" true (String.length json_str > 10)

(* ============================================================
   count_active_agents Tests
   ============================================================ *)

let test_count_active_agents_empty () =
  let events : Telemetry_eio.event_record list = [] in
  check int "empty" 0 (Telemetry_eio.count_active_agents events)

let test_count_active_agents_one_bound () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Agent_session_bound { agent_id = "a1"; capabilities = [] } };
  ] in
  check int "one bound" 1 (Telemetry_eio.count_active_agents events)

let test_count_active_agents_bound_then_unbound () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Agent_session_bound { agent_id = "a1"; capabilities = [] } };
    { timestamp = 2.0; event = Agent_unbound { agent_id = "a1"; reason = "done" } };
  ] in
  check int "bound then unbound" 0 (Telemetry_eio.count_active_agents events)

let test_count_active_agents_multiple () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Agent_session_bound { agent_id = "a1"; capabilities = [] } };
    { timestamp = 2.0; event = Agent_session_bound { agent_id = "a2"; capabilities = [] } };
    { timestamp = 3.0; event = Agent_unbound { agent_id = "a1"; reason = "x" } };
  ] in
  check int "multiple" 1 (Telemetry_eio.count_active_agents events)

(* ============================================================
   count_tasks_in_progress Tests
   ============================================================ *)

let test_count_tasks_in_progress_empty () =
  let events : Telemetry_eio.event_record list = [] in
  check int "empty" 0 (Telemetry_eio.count_tasks_in_progress events)

let test_count_tasks_in_progress_one_started () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Task_started { task_id = "t1"; agent_id = "a1" } };
  ] in
  check int "one started" 1 (Telemetry_eio.count_tasks_in_progress events)

let test_count_tasks_in_progress_started_completed () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Task_started { task_id = "t1"; agent_id = "a1" } };
    { timestamp = 2.0; event = Task_completed { task_id = "t1"; duration_ms = 100; success = true } };
  ] in
  check int "completed" 0 (Telemetry_eio.count_tasks_in_progress events)

(* ============================================================
   count_completed_tasks Tests
   ============================================================ *)

let test_count_completed_tasks_empty () =
  let events : Telemetry_eio.event_record list = [] in
  check int "empty" 0 (Telemetry_eio.count_completed_tasks events)

let test_count_completed_tasks_one () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Task_completed { task_id = "t1"; duration_ms = 100; success = true } };
  ] in
  check int "one" 1 (Telemetry_eio.count_completed_tasks events)

let test_count_completed_tasks_multiple () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Task_completed { task_id = "t1"; duration_ms = 100; success = true } };
    { timestamp = 2.0; event = Task_completed { task_id = "t2"; duration_ms = 200; success = false } };
    { timestamp = 3.0; event = Task_started { task_id = "t3"; agent_id = "a1" } };
  ] in
  check int "two completed" 2 (Telemetry_eio.count_completed_tasks events)

(* ============================================================
   avg_duration Tests
   ============================================================ *)

let test_avg_duration_empty () =
  let events : Telemetry_eio.event_record list = [] in
  let avg = Telemetry_eio.avg_duration events in
  check bool "zero" true (abs_float avg < 0.01)

let test_avg_duration_one () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Task_completed { task_id = "t1"; duration_ms = 1000; success = true } };
  ] in
  let avg = Telemetry_eio.avg_duration events in
  check bool "1000" true (abs_float (avg -. 1000.0) < 0.01)

let test_avg_duration_multiple () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Task_completed { task_id = "t1"; duration_ms = 1000; success = true } };
    { timestamp = 2.0; event = Task_completed { task_id = "t2"; duration_ms = 2000; success = true } };
  ] in
  let avg = Telemetry_eio.avg_duration events in
  check bool "avg 1500" true (abs_float (avg -. 1500.0) < 0.01)

(* ============================================================
   calculate_error_rate Tests
   ============================================================ *)

let test_calculate_error_rate_empty () =
  let events : Telemetry_eio.event_record list = [] in
  let rate = Telemetry_eio.calculate_error_rate events in
  check bool "zero" true (abs_float rate < 0.01)

let test_calculate_error_rate_no_errors () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Task_completed { task_id = "t1"; duration_ms = 100; success = true } };
  ] in
  let rate = Telemetry_eio.calculate_error_rate events in
  check bool "zero" true (abs_float rate < 0.01)

let test_calculate_error_rate_some_errors () =
  let events : Telemetry_eio.event_record list = [
    { timestamp = 1.0; event = Task_completed { task_id = "t1"; duration_ms = 100; success = true } };
    { timestamp = 2.0; event = Error_occurred { code = "E1"; message = "err"; context = "ctx" } };
  ] in
  let rate = Telemetry_eio.calculate_error_rate events in
  check bool "positive" true (rate > 0.0)

let test_summarize_tool_usage_reads_date_split_store_without_fs () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Workspace.default_config base_dir in
      Telemetry_eio.track_tool_called config ~tool_name:"masc_status"
        ~success:true ~duration_ms:42 ~agent_id:"codex" ();
      let summary = Telemetry_eio.summarize_tool_usage config in
      check int "total calls" 1 summary.total_calls;
      let stats =
        match Hashtbl.find_opt summary.stats_by_tool "masc_status" with
        | Some stats -> stats
        | None -> fail "missing stats for masc_status"
      in
      check int "usage count" 1 stats.count;
      check bool "telemetry available" true summary.telemetry_available;
      check
        string
        "telemetry path is the current date-split store"
        (telemetry_dir base_dir)
        summary.telemetry_path)

let test_legacy_single_file_is_ignored () =
  with_temp_dir
  @@ fun base_dir ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config base_dir in
  let legacy_path =
    Filename.concat (Filename.concat base_dir ".masc") "telemetry.jsonl"
  in
  Fs_compat.mkdir_p (Filename.dirname legacy_path);
  Fs_compat.append_file
    legacy_path
    {|{"timestamp":1000.0,"event":["Agent_session_bound",{"agent_id":"legacy-only","capabilities":[]}]}|}
  ;
  check
    int
    "legacy single-file telemetry is not read"
    0
    (List.length (Telemetry_eio.read_all_events config))

(* [read_all_events] decodes rows during the read now instead of materialising
   the window first. The decoder runs under a newest-first scan while the
   result stays chronological, so order is the thing worth pinning. *)
let test_read_all_events_is_chronological_across_day_files () =
  with_temp_dir (fun base_dir ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Workspace.default_config base_dir in
    let dir = telemetry_dir base_dir in
    let row ts agent_id =
      Printf.sprintf
        {|{"timestamp":%.1f,"event":["Agent_session_bound",{"agent_id":"%s","capabilities":[]}]}|}
        ts agent_id
    in
    write_dated_file dir "2026-01" "31" [ row 100.0 "a"; row 200.0 "b" ];
    write_dated_file dir "2026-02" "01" [ "not-json"; row 300.0 "c" ];
    let timestamps =
      Telemetry_eio.read_all_events config
      |> List.map (fun (record : Telemetry_eio.event_record) -> record.timestamp)
    in
    check (list (float 0.001))
      "oldest first across months, malformed row dropped"
      [ 100.0; 200.0; 300.0 ] timestamps)

let test_track_applies_default_retention_days () =
  with_env "MASC_TELEMETRY_RETENTION_DAYS" "" (fun () ->
    with_env "MASC_TELEMETRY_MAX_BYTES" "0" (fun () ->
      with_temp_dir (fun base_dir ->
        Eio_main.run @@ fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        let config = Workspace.default_config base_dir in
        let telemetry_dir = telemetry_dir base_dir in
        let old_file =
          Filename.concat (Filename.concat telemetry_dir "2020-01") "01.jsonl"
        in
        write_dated_file telemetry_dir "2020-01" "01" [ {|{"old":true}|} ];
        Telemetry_eio.track_agent_session_bound config ~agent_id:"retention-test" ();
        check bool "old telemetry file pruned by default retention" false
          (Sys.file_exists old_file))))

let test_track_applies_telemetry_max_bytes () =
  with_env "MASC_TELEMETRY_RETENTION_DAYS" "0" (fun () ->
    with_env "MASC_TELEMETRY_MAX_BYTES" "120" (fun () ->
      with_temp_dir (fun base_dir ->
        Eio_main.run @@ fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        let config = Workspace.default_config base_dir in
        let telemetry_dir = telemetry_dir base_dir in
        let old_file_1 =
          Filename.concat (Filename.concat telemetry_dir "2020-01") "01.jsonl"
        in
        let old_file_2 =
          Filename.concat (Filename.concat telemetry_dir "2020-01") "02.jsonl"
        in
        write_dated_file telemetry_dir "2020-01" "01"
          [ Printf.sprintf {|{"payload":"%s"}|} (String.make 80 'a') ];
        write_dated_file telemetry_dir "2020-01" "02"
          [ Printf.sprintf {|{"payload":"%s"}|} (String.make 80 'b') ];
        Telemetry_eio.track_agent_session_bound config ~agent_id:"max-bytes-test" ();
        check bool "old telemetry file 1 pruned by max bytes" false
          (Sys.file_exists old_file_1);
        check bool "old telemetry file 2 pruned by max bytes" false
          (Sys.file_exists old_file_2);
        check int "current row remains readable" 1
          (List.length (Telemetry_eio.read_all_events config)))))

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Telemetry Eio Coverage" [
    "event", [
      test_case "agent_session_bounded" `Quick test_event_agent_session_bounded;
      test_case "agent_unbound" `Quick test_event_agent_unbound;
      test_case "task_started" `Quick test_event_task_started;
      test_case "task_completed" `Quick test_event_task_completed;
      test_case "error_occurred" `Quick test_event_error_occurred;
      test_case "tool_called" `Quick test_event_tool_called;
    ];
    "event_record", [
      test_case "type" `Quick test_event_record_type;
      test_case "tool_called null option fields" `Quick
        test_parse_event_records_tool_called_null_options;
      test_case "tool_called missing option fields" `Quick
        test_parse_event_records_tool_called_missing_options;
      test_case "legacy transient failure class" `Quick
        test_parse_event_records_legacy_transient_failure_class;
      test_case "tool_assigned minimal payload" `Quick
        test_parse_event_records_tool_assigned_minimal_payload;
      test_case "tool_assigned missing optional fields" `Quick
        test_parse_event_records_tool_assigned_missing_optional_fields;
    ];
    "json_roundtrip", [
      test_case "event" `Quick test_event_json_roundtrip;
      test_case "drop increments persistence_read_drops counter" `Quick
        test_parse_event_records_drop_increments_counter;
      test_case "retired agent variants are rejected" `Quick
        test_retired_agent_variants_are_rejected;
    ];
    "event_to_json", [
      test_case "agent_session_bounded" `Quick test_event_to_json_agent_session_bounded;
      test_case "task_completed" `Quick test_event_to_json_task_completed;
    ];
    "count_active_agents", [
      test_case "empty" `Quick test_count_active_agents_empty;
      test_case "one bound" `Quick test_count_active_agents_one_bound;
      test_case "bound then unbound" `Quick test_count_active_agents_bound_then_unbound;
      test_case "multiple" `Quick test_count_active_agents_multiple;
    ];
    "count_tasks_in_progress", [
      test_case "empty" `Quick test_count_tasks_in_progress_empty;
      test_case "one started" `Quick test_count_tasks_in_progress_one_started;
      test_case "started completed" `Quick test_count_tasks_in_progress_started_completed;
    ];
    "count_completed_tasks", [
      test_case "empty" `Quick test_count_completed_tasks_empty;
      test_case "one" `Quick test_count_completed_tasks_one;
      test_case "multiple" `Quick test_count_completed_tasks_multiple;
    ];
    "avg_duration", [
      test_case "empty" `Quick test_avg_duration_empty;
      test_case "one" `Quick test_avg_duration_one;
      test_case "multiple" `Quick test_avg_duration_multiple;
    ];
    "calculate_error_rate", [
      test_case "empty" `Quick test_calculate_error_rate_empty;
      test_case "no errors" `Quick test_calculate_error_rate_no_errors;
      test_case "some errors" `Quick test_calculate_error_rate_some_errors;
    ];
    "store_reads", [
      test_case "summarize_tool_usage reads date-split store" `Quick
        test_summarize_tool_usage_reads_date_split_store_without_fs;
      test_case "legacy single telemetry file is ignored" `Quick
        test_legacy_single_file_is_ignored;
      test_case "read_all_events is chronological across day files" `Quick
        test_read_all_events_is_chronological_across_day_files;
      test_case "track applies default retention days" `Quick
        test_track_applies_default_retention_days;
      test_case "track applies telemetry max bytes" `Quick
        test_track_applies_telemetry_max_bytes;
    ];
  ]
