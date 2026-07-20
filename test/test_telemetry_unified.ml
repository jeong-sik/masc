module Types = Masc_domain

(** test_telemetry_unified — Tests for unified telemetry read aggregation. *)

open Masc

(* ── Helpers ─────────────────────────────────────── *)

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s_%d_%d_%.0f" prefix !counter (Unix.getpid ())
       (Unix.gettimeofday ()))
  in
  Fs_compat.mkdir_p dir;
  dir

let write_jsonl dir entries =
  let store = Dated_jsonl.create ~base_dir:dir () in
  List.iter (fun json -> Dated_jsonl.append store json) entries

let today_jsonl_path dir =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let month_dir = Filename.concat dir month in
  Fs_compat.mkdir_p month_dir;
  Filename.concat month_dir day

let write_raw_jsonl_rows dir rows =
  let path = today_jsonl_path dir in
  let content =
    List.init rows (fun i ->
      Printf.sprintf
        "{\"timestamp\": %.1f, \"event\": \"e%d\"}\n"
        (float_of_int i) i)
    |> String.concat ""
  in
  Fs_compat.append_file path content

let jsonl_path_for_unix_seconds dir ts =
  let tm = Unix.gmtime ts in
  let month = Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.Unix.tm_mday in
  let month_dir = Filename.concat dir month in
  Fs_compat.mkdir_p month_dir;
  Filename.concat month_dir day

let append_jsonl_entry_for_ts dir ts json =
  let path = jsonl_path_for_unix_seconds dir ts in
  Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n")

let json_int_field name = function
  | `Assoc fields -> (
      match List.assoc_opt name fields with
      | Some (`Int value) -> value
      | _ -> -1)
  | _ -> -1

let json_string_field name = function
  | `Assoc fields -> (
      match List.assoc_opt name fields with
      | Some (`String value) -> value
      | _ -> "")
  | _ -> ""

let source_summary source_name = function
  | `Assoc fields -> (
      match List.assoc_opt "sources" fields with
      | Some (`List sources) ->
        List.find
          (fun source_json ->
            String.equal source_name (json_string_field "source" source_json))
          sources
      | _ -> Alcotest.fail "expected sources")
  | _ -> Alcotest.fail "expected summary object"

let source_read_failure_metric source site =
  Otel_metric_store.metric_value_or_zero
    Otel_metric_store.metric_telemetry_unified_source_read_failures
    ~labels:[ ("source", source); ("site", site) ]
    ()

(* ── Source roundtrip ────────────────────────────── *)

let test_source_roundtrip () =
  List.iter (fun source ->
    let s = Telemetry_unified.source_to_string source in
    let result = Telemetry_unified.source_of_string s in
    Alcotest.(check bool) (Printf.sprintf "%s roundtrips" s) true
      (result = Some source)
  ) Telemetry_unified.all_sources

let test_source_of_string_unknown () =
  let result = Telemetry_unified.source_of_string "unknown_source" in
  Alcotest.(check bool) "unknown returns None" true (result = None)

(* ── Empty base_path ─────────────────────────────── *)

let masc_root dir = Filename.concat dir Common.masc_dirname

let canonical_trajectory_tool_json ?(keeper_turn_id = 1) ?(oas_turn = 0)
    ?(planned_index = 0) ?(batch_index = 0) ?(batch_size = 1)
    ?(execution_mode = Agent_sdk.Tool.Serial) ?(tool_use_id = "") ~ts
    ~tool_name ~duration_ms ~execution_id () =
  `Assoc
    [ ("schema", `String "masc.keeper_trajectory.v1")
    ; ("type", `String "tool_call")
    ; ("ts", `Float ts)
    ; ("ts_iso", `String (Masc_domain.iso8601_of_unix_seconds ts))
    ; ("keeper_turn_id", `Int keeper_turn_id)
    ; ("oas_turn", `Int oas_turn)
    ; ( "schedule"
      , `Assoc
          [ ("planned_index", `Int planned_index)
          ; ("batch_index", `Int batch_index)
          ; ("batch_size", `Int batch_size)
          ; ( "execution_mode"
            , Agent_sdk.Tool.execution_mode_to_yojson execution_mode )
          ] )
    ; ("tool_use_id", `String tool_use_id)
    ; ("tool_name", `String tool_name)
    ; ("args", `Assoc [])
    ; ( "outcome"
      , `Assoc
          [ ("status", `String "succeeded")
          ; ("output", `String "ok")
          ] )
    ; ("duration_ms", `Int duration_ms)
    ; ("execution_id", `String execution_id)
    ]

let test_empty_returns_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_empty" in
  let entries = Telemetry_unified.read_unified ~base_path:dir ~masc_root:(masc_root dir) () in
  Alcotest.(check int) "no entries" 0 (List.length entries)

let test_summary_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_sum_empty" in
  let json = Telemetry_unified.summary_json ~base_path:dir ~masc_root:(masc_root dir) () in
  match json with
  | `Assoc fields ->
    let total = match List.assoc_opt "total_entries" fields with
      | Some (`Int n) -> n | _ -> -1 in
    Alcotest.(check int) "zero total" 0 total
  | _ -> Alcotest.fail "expected Assoc"

(* ── Single source read ──────────────────────────── *)

let test_agent_event_source () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_agent_event" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  write_jsonl telemetry_dir [
    `Assoc [("timestamp", `Float 1000.0); ("event", `String "test1")];
    `Assoc [("timestamp", `Float 2000.0); ("event", `String "test2")];
  ];
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[Telemetry_unified.Agent_event] ()
  in
  Alcotest.(check int) "two entries" 2 (List.length entries);
  (* Check source tag *)
  match List.hd entries with
  | `Assoc fields ->
    let source = match List.assoc_opt "source" fields with
      | Some (`String s) -> s | _ -> "" in
    Alcotest.(check string) "tagged as agent_event" "agent_event" source
  | _ -> Alcotest.fail "expected Assoc"

let test_oas_event_source_and_scope_filter () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_oas_event" in
  let oas_events_dir = Filename.concat dir ".masc/oas-events" in
  Fs_compat.mkdir_p oas_events_dir;
  write_jsonl oas_events_dir [
    `Assoc
      [
        ("ts_unix", `Float 1000.0);
        ("event_type", `String "tool_called");
        ("agent_name", `String "alpha");
        ("session_id", `String "sess-1");
        ("worker_run_id", `String "run-1");
        ("tool_name", `String "masc_status");
      ];
    `Assoc
      [
        ("ts_unix", `Float 2000.0);
        ("event_type", `String "turn_completed");
        ("agent_name", `String "beta");
        ("session_id", `String "sess-2");
        ("worker_run_id", `String "run-2");
        ("turn", `Int 3);
      ];
  ];
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[Telemetry_unified.Oas_event]
      ~session_id:"sess-2" ~worker_run_id:"run-2" ()
  in
  Alcotest.(check int) "one filtered oas event" 1 (List.length entries);
  match List.hd entries with
  | `Assoc fields ->
    let source = match List.assoc_opt "source" fields with
      | Some (`String s) -> s | _ -> "" in
    let event_type = match List.assoc_opt "event_type" fields with
      | Some (`String s) -> s | _ -> "" in
    Alcotest.(check string) "tagged as oas_event" "oas_event" source;
    Alcotest.(check string) "event type preserved" "turn_completed" event_type
  | _ -> Alcotest.fail "expected Assoc"

let test_keeper_tool_called_scope_promoted_for_filters () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_keeper_tool_scope" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  write_jsonl telemetry_dir
    [
      `Assoc
        [
          ("timestamp", `Float 1100.0);
          ( "event",
            `List
              [
                `String "Tool_called";
                `Assoc
                  [
                    ("tool_name", `String "keeper_task_claim");
                    ("success", `Bool true);
                    ("duration_ms", `Int 42);
                    ("agent_id", `String "codex-mcp-client");
                    ("session_id", `String "mcp-session-1");
                    ("operation_id", `String "op-1");
                    ("worker_run_id", `String "worker-1");
                  ];
              ] );
        ];
    ];
  let result =
    Telemetry_unified.read_unified_result ~base_path:dir
      ~masc_root:(masc_root dir) ~sources:[ Telemetry_unified.Agent_event ]
      ~session_id:"mcp-session-1" ~operation_id:"op-1"
      ~worker_run_id:"worker-1" ()
  in
  Alcotest.(check int) "scoped agent tool event visible" 1
    result.total_matching_entries;
  match List.hd result.entries with
  | `Assoc fields ->
    let json = `Assoc fields in
    Alcotest.(check string) "tool promoted" "keeper_task_claim"
      (json_string_field "tool_name" json);
    Alcotest.(check string) "session promoted" "mcp-session-1"
      (json_string_field "session_id" json);
    Alcotest.(check string) "operation promoted" "op-1"
      (json_string_field "operation_id" json);
    Alcotest.(check string) "worker promoted" "worker-1"
      (json_string_field "worker_run_id" json)
  | _ -> Alcotest.fail "expected Assoc"

let test_shadow_keeper_tool_called_deduped_from_unified_view () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_shadow_tool_called" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  let tool_calls_dir = Filename.concat dir ".masc/tool_calls" in
  Fs_compat.mkdir_p telemetry_dir;
  Fs_compat.mkdir_p tool_calls_dir;
  write_jsonl telemetry_dir [
    `Assoc
      [
        ("timestamp", `Float 1000.2);
        ( "event",
          `List
            [
              `String "Tool_called";
              `Assoc
                [
                  ("tool_name", `String "masc_status");
                  ("success", `Bool true);
                  ("duration_ms", `Int 12);
                  ("agent_id", `String "keeper-sangsu-agent");
                ];
            ] );
      ];
  ];
  write_jsonl tool_calls_dir [
    `Assoc
      [
        ("ts", `Float 1000.0);
        ("keeper", `String "sangsu");
        ("tool", `String "masc_status");
        ("success", `Bool true);
        ("duration_ms", `Float 12.0);
      ];
  ];
  let result =
    Telemetry_unified.read_unified_result ~base_path:dir
      ~masc_root:(masc_root dir)
      ~sources:[ Telemetry_unified.Agent_event; Telemetry_unified.Tool_call_io ]
      ()
  in
  Alcotest.(check int) "shadow agent event removed" 1
    (List.length result.entries);
  Alcotest.(check int) "total reflects visible unified entries" 1
    result.total_matching_entries;
  Alcotest.(check string) "full tool call row preserved" "tool_call_io"
    (json_string_field "source" (List.hd result.entries));
  let raw_agent_entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[ Telemetry_unified.Agent_event ] ()
  in
  Alcotest.(check int) "source-filtered agent event remains available" 1
    (List.length raw_agent_entries)

(* ── Keeper metrics discovery ────────────────────── *)

let test_keeper_metrics_per_keeper () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_keeper_metrics" in
  let cheolsu_dir = Filename.concat dir ".masc/keepers/cheolsu/metrics" in
  let sangsu_dir = Filename.concat dir ".masc/keepers/sangsu/metrics" in
  Fs_compat.mkdir_p cheolsu_dir;
  Fs_compat.mkdir_p sangsu_dir;
  write_jsonl cheolsu_dir [
    `Assoc [("ts_unix", `Float 3000.0); ("name", `String "cheolsu");
            ("channel", `String "turn")];
  ];
  write_jsonl sangsu_dir [
    `Assoc [("ts_unix", `Float 4000.0); ("name", `String "sangsu");
            ("channel", `String "turn")];
  ];
  (* All keepers *)
  let all = Telemetry_unified.read_unified ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[Telemetry_unified.Keeper_metric] () in
  Alcotest.(check int) "two keeper entries" 2 (List.length all);
  (* Filter by keeper *)
  let cheolsu_only = Telemetry_unified.read_unified ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[Telemetry_unified.Keeper_metric]
      ~keeper_name:"cheolsu" () in
  Alcotest.(check int) "one cheolsu entry" 1 (List.length cheolsu_only)

let test_keeper_metrics_fast_path_preserves_noisy_keeper_top_n () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_keeper_fast_top" in
  let hot_dir = Filename.concat dir ".masc/keepers/hot/metrics" in
  let old_dir = Filename.concat dir ".masc/keepers/old/metrics" in
  Fs_compat.mkdir_p hot_dir;
  Fs_compat.mkdir_p old_dir;
  write_jsonl hot_dir
    (List.init 120 (fun i ->
         `Assoc
           [
             ("ts_unix", `Float (1_000.0 +. Float.of_int i));
             ("name", `String "hot");
             ("i", `Int i);
           ]));
  write_jsonl old_dir
    (List.init 50 (fun i ->
         `Assoc
           [
             ("ts_unix", `Float (Float.of_int i));
             ("name", `String "old");
             ("i", `Int i);
           ]));
  let result =
    Telemetry_unified.read_unified_result ~base_path:dir
      ~masc_root:(masc_root dir) ~sources:[ Telemetry_unified.Keeper_metric ]
      ~n:100 ()
  in
  Alcotest.(check int) "limited result" 100 (List.length result.entries);
  Alcotest.(check int) "marker total" 101 result.total_matching_entries;
  Alcotest.(check bool) "truncated" true result.truncated;
  let indices = List.map (json_int_field "i") result.entries in
  Alcotest.(check int) "newest hot entry first" 119 (List.hd indices);
  Alcotest.(check int) "oldest returned hot entry last" 20 (List.nth indices 99);
  Alcotest.(check (list string)) "only hot top entries returned"
    (List.init 100 (fun _ -> "hot"))
    (List.map (json_string_field "name") result.entries)

let test_keeper_metrics_fast_path_sets_truncated_with_marker () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_keeper_fast_marker" in
  let write_keeper name ts =
    let metrics_dir = Filename.concat dir (".masc/keepers/" ^ name ^ "/metrics") in
    Fs_compat.mkdir_p metrics_dir;
    write_jsonl metrics_dir
      [
        `Assoc
          [
            ("ts_unix", `Float ts);
            ("name", `String name);
            ("channel", `String "turn");
          ];
      ]
  in
  write_keeper "alpha" 3_000.0;
  write_keeper "beta" 2_000.0;
  write_keeper "gamma" 1_000.0;
  let result =
    Telemetry_unified.read_unified_result ~base_path:dir
      ~masc_root:(masc_root dir) ~sources:[ Telemetry_unified.Keeper_metric ]
      ~n:2 ()
  in
  Alcotest.(check int) "returned limit" 2 (List.length result.entries);
  Alcotest.(check int) "marker total" 3 result.total_matching_entries;
  Alcotest.(check bool) "truncated" true result.truncated;
  Alcotest.(check (list string)) "newest keepers"
    [ "alpha"; "beta" ]
    (List.map (json_string_field "name") result.entries)

(* ── Sorting (newest first) ──────────────────────── *)

let test_sorted_newest_first () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_sorted" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  write_jsonl telemetry_dir [
    `Assoc [("timestamp", `Float 1000.0); ("event", `String "old")];
    `Assoc [("timestamp", `Float 3000.0); ("event", `String "new")];
    `Assoc [("timestamp", `Float 2000.0); ("event", `String "mid")];
  ];
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[Telemetry_unified.Agent_event] ()
  in
  Alcotest.(check int) "three entries" 3 (List.length entries);
  let first_event = match List.hd entries with
    | `Assoc fields ->
      (match List.assoc_opt "event" fields with
       | Some (`String s) -> s | _ -> "")
    | _ -> "" in
  Alcotest.(check string) "newest first" "new" first_event

(* ── Limit ───────────────────────────────────────── *)

let test_n_limits_output () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_limit" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  write_jsonl telemetry_dir (
    List.init 50 (fun i ->
      `Assoc [("timestamp", `Float (Float.of_int (i * 100))); ("i", `Int i)])
  );
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[Telemetry_unified.Agent_event] ~n:10 ()
  in
  Alcotest.(check int) "limited to 10" 10 (List.length entries)

let test_time_window_reports_total_before_limit () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_window_limit" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  let now = Unix.gettimeofday () in
  write_jsonl telemetry_dir [
    `Assoc [("timestamp", `Float (now -. 7_200.0)); ("event", `String "too_old")];
    `Assoc [("timestamp", `Float (now -. 1_800.0)); ("event", `String "within_1")];
    `Assoc [("timestamp", `Float (now -. 300.0)); ("event", `String "within_2")];
    `Assoc [("timestamp", `Float (now -. 60.0)); ("event", `String "within_3")];
  ];
  let result =
    Telemetry_unified.read_unified_result ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[Telemetry_unified.Agent_event]
      ~since_ts:(now -. 3_600.0) ~until_ts:now ~n:2 ()
  in
  Alcotest.(check int) "total matching preserved before limit" 3
    result.total_matching_entries;
  Alcotest.(check bool) "range result truncated" true result.truncated;
  Alcotest.(check int) "returned entry count limited" 2 (List.length result.entries);
  let events =
    List.map (function
      | `Assoc fields ->
        (match List.assoc_opt "event" fields with
         | Some (`String s) -> s
         | _ -> "")
      | _ -> "") result.entries
  in
  Alcotest.(check (list string)) "newest matching entries returned"
    ["within_3"; "within_2"] events

let test_time_window_reads_matching_day_files () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_window_days" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  let now = Unix.gettimeofday () in
  let yesterday = now -. 86_400.0 in
  append_jsonl_entry_for_ts telemetry_dir yesterday
    (`Assoc [("timestamp", `Float yesterday); ("event", `String "yesterday")]);
  append_jsonl_entry_for_ts telemetry_dir now
    (`Assoc [("timestamp", `Float now); ("event", `String "today")]);
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[Telemetry_unified.Agent_event]
      ~since_ts:(yesterday -. 60.0) ~until_ts:(now +. 60.0) ()
  in
  let events =
    List.map (function
      | `Assoc fields ->
        (match List.assoc_opt "event" fields with
         | Some (`String s) -> s
         | _ -> "")
      | _ -> "") entries
  in
  Alcotest.(check (list string)) "range spans multiple day files"
    ["today"; "yesterday"] events

let test_unbounded_read_is_rejected () =
  Alcotest.check_raises
    "n=0 is not an unlimited server read"
    (Invalid_argument
       "Telemetry_unified.read_unified_result: n must be positive")
    (fun () ->
       Telemetry_unified.read_unified_result
         ~base_path:"unused"
         ~masc_root:"unused"
         ~n:0
         ()
       |> ignore)

let test_negative_offset_is_rejected () =
  Alcotest.check_raises
    "negative offset is not normalized"
    (Invalid_argument
       "Telemetry_unified.read_unified_result: offset must be non-negative")
    (fun () ->
       Telemetry_unified.read_unified_result
         ~base_path:"unused"
         ~masc_root:"unused"
         ~offset:(-1)
         ()
       |> ignore)

(* ── Summary with data ───────────────────────────── *)

let test_summary_with_data () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_summary" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  write_jsonl telemetry_dir [
    `Assoc [("timestamp", `Float 1000.0); ("event", `String "test")];
  ];
  let json = Telemetry_unified.summary_json ~base_path:dir ~masc_root:(masc_root dir) () in
  match json with
  | `Assoc fields ->
    let total = match List.assoc_opt "total_entries" fields with
      | Some (`Int n) -> n | _ -> -1 in
    Alcotest.(check bool) "at least 1 entry" true (total >= 1)
  | _ -> Alcotest.fail "expected Assoc"

let test_summary_includes_freshness_metadata () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_summary_freshness" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  let recent_ts = Unix.gettimeofday () -. 42.0 in
  write_jsonl telemetry_dir
    [ `Assoc [ ("timestamp", `Float recent_ts); ("event", `String "fresh") ] ];
  let json = Telemetry_unified.summary_json ~base_path:dir ~masc_root:(masc_root dir) () in
  let source_fields =
    match json with
    | `Assoc fields -> (
        match List.assoc_opt "sources" fields with
        | Some (`List sources) ->
          List.find_map
            (function
              | `Assoc source_fields -> (
                  match List.assoc_opt "source" source_fields with
                  | Some (`String "agent_event") -> Some source_fields
                  | _ -> None)
              | _ -> None)
            sources
        | _ -> None)
    | _ -> None
  in
  match source_fields with
  | Some fields ->
    let latest_ts =
      match List.assoc_opt "latest_ts_unix" fields with
      | Some (`Float ts) -> ts
      | Some (`Int ts) -> float_of_int ts
      | _ -> Alcotest.fail "expected latest_ts_unix"
    in
    let latest_iso =
      match List.assoc_opt "latest_ts_iso" fields with
      | Some (`String iso) -> iso
      | _ -> Alcotest.fail "expected latest_ts_iso"
    in
    let latest_age =
      match List.assoc_opt "latest_age_s" fields with
      | Some (`Float age) -> age
      | Some (`Int age) -> float_of_int age
      | _ -> Alcotest.fail "expected latest_age_s"
    in
    let health =
      match List.assoc_opt "health" fields with
      | Some (`String value) -> value
      | _ -> Alcotest.fail "expected health"
    in
    let producer =
      match List.assoc_opt "producer" fields with
      | Some (`String value) -> value
      | _ -> Alcotest.fail "expected producer"
    in
    let freshness_slo_s =
      match List.assoc_opt "freshness_slo_s" fields with
      | Some (`Float value) -> value
      | Some (`Int value) -> float_of_int value
      | _ -> Alcotest.fail "expected freshness_slo_s"
    in
    Alcotest.(check bool) "latest ts close to event" true
      (abs_float (latest_ts -. recent_ts) < 5.0);
    Alcotest.(check bool) "latest iso present" true (String.length latest_iso > 0);
    Alcotest.(check bool) "latest age bounded" true
      (latest_age >= 0.0 && latest_age < 180.0);
    Alcotest.(check string) "health ok" "ok" health;
    Alcotest.(check string) "producer" "telemetry_eio" producer;
    Alcotest.(check (float 0.1)) "freshness SLO" 900.0 freshness_slo_s
  | None -> Alcotest.fail "expected agent_event source summary"

let test_summary_tool_metric_surface_points_to_raw_metrics () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_summary_tool_metric_surface" in
  let metrics_dir = Filename.concat dir "data/tool-metrics" in
  Fs_compat.mkdir_p metrics_dir;
  write_jsonl metrics_dir
    [ `Assoc [ ("timestamp", `Float (Unix.gettimeofday ()));
               ("tool_name", `String "tool_read_file");
               ("duration_ms", `Float 12.0);
               ("success", `Bool true) ] ];
  let json = Telemetry_unified.summary_json ~base_path:dir ~masc_root:(masc_root dir) () in
  let summary = source_summary "tool_metric" json in
  Alcotest.(check string) "tool_metric dashboard surface"
    "/api/v1/tool-metrics"
    (json_string_field "dashboard_surface" summary)

let test_summary_includes_trajectory_and_execution_receipt_sources () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_summary_tool_lanes" in
  let root = masc_root dir in
  let now = Unix.gettimeofday () in
  let trajectory_path = Trajectory.trajectory_path root "alice" "trace-1" in
  let trajectory_dir = Filename.dirname trajectory_path in
  Fs_compat.mkdir_p trajectory_dir;
  Fs_compat.append_file trajectory_path
    (Yojson.Safe.to_string
       (canonical_trajectory_tool_json ~ts:now ~tool_name:"tool_execute"
          ~duration_ms:7 ~execution_id:"exec-telemetry-summary-1" ())
     ^ "\n");
  let receipt_dir = Filename.concat root "keepers/alice/execution-receipts" in
  Fs_compat.mkdir_p receipt_dir;
  write_jsonl receipt_dir
    [ `Assoc
        [
          ("recorded_at", `String (Masc_domain.iso8601_of_unix_seconds now));
          ("ended_at", `String (Masc_domain.iso8601_of_unix_seconds now));
          ("keeper_name", `String "alice");
          ("trace_id", `String "trace-1");
          ("outcome", `String "completed");
        ] ];
  let json = Telemetry_unified.summary_json ~base_path:dir ~masc_root:root () in
  let trajectory_summary = source_summary "trajectory_tool_call" json in
  let receipt_summary = source_summary "execution_receipt" json in
  Alcotest.(check int) "trajectory count" 1
    (json_int_field "entry_count" trajectory_summary);
  Alcotest.(check int) "trajectory keeper count" 1
    (json_int_field "keeper_count" trajectory_summary);
  Alcotest.(check string) "trajectory health" "ok"
    (json_string_field "health" trajectory_summary);
  Alcotest.(check string) "trajectory dashboard surface"
    "/api/v1/keepers/:name/tool-stats"
    (json_string_field "dashboard_surface" trajectory_summary);
  Alcotest.(check int) "execution receipt count" 1
    (json_int_field "entry_count" receipt_summary);
  Alcotest.(check int) "execution receipt keeper count" 1
    (json_int_field "keeper_count" receipt_summary);
  Alcotest.(check string) "execution receipt health" "ok"
    (json_string_field "health" receipt_summary);
  Alcotest.(check string) "execution receipt dashboard surface"
    "/api/v1/dashboard/execution-trust"
    (json_string_field "dashboard_surface" receipt_summary)

let test_read_unified_reads_trajectory_and_execution_receipts () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_read_tool_lanes" in
  let root = masc_root dir in
  let invocation =
    Agent_sdk.Tool.Invocation.create ~tool_use_id:"tool-use-telemetry-read-1"
      ~turn:4
      ~schedule:
        { planned_index = 5
        ; batch_index = 1
        ; batch_size = 2
        ; execution_mode = Agent_sdk.Tool.Concurrent
        }
  in
  let trajectory_entry =
    match
      Trajectory.make_tool_call_entry
        ~ts:2000.0
        ~ts_iso:"1970-01-01T00:33:20Z"
        ~keeper_turn_id:1
        ~invocation
        ~tool_name:"tool_execute"
        ~arguments:[]
        ~outcome:(Trajectory.Tool_succeeded "ok")
        ~duration_ms:7
        ~execution_id:
          (Ids.Execution_id.of_string "exec-telemetry-read-1")
    with
    | Ok entry -> entry
    | Error error ->
      Alcotest.failf "canonical trajectory fixture rejected: %s"
        (Trajectory.entry_decode_error_to_string error)
  in
  let trajectory_accumulator =
    Trajectory.create_accumulator ~masc_root:root ~keeper_name:"alice"
      ~trace_id:"trace-1" ~keeper_turn_id:1 ~generation:0 ()
  in
  Trajectory.record_entry trajectory_accumulator trajectory_entry;
  Trajectory.finalize trajectory_accumulator Trajectory.Completed |> ignore;
  let receipt_dir = Filename.concat root "keepers/alice/execution-receipts" in
  Fs_compat.mkdir_p receipt_dir;
  write_jsonl receipt_dir
    [ `Assoc
        [
          ("recorded_at", `String "1970-01-01T00:16:40Z");
          ("ended_at", `String "1970-01-01T00:16:40Z");
          ("keeper_name", `String "alice");
          ("trace_id", `String "trace-1");
          ("outcome", `String "completed");
        ] ];
  let entries =
    Telemetry_unified.read_unified
      ~base_path:dir
      ~masc_root:root
      ~sources:
        [
          Telemetry_unified.Trajectory_tool_call;
          Telemetry_unified.Execution_receipt;
        ]
      ~keeper_name:"alice"
      ~n:10
      ()
  in
  if List.length entries <> 2 then
    Alcotest.failf "expected two entries, got sources: %s"
      (entries
       |> List.map (json_string_field "source")
       |> String.concat ",");
  Alcotest.(check string) "newest source" "trajectory_tool_call"
    (List.hd entries |> json_string_field "source");
  Alcotest.(check string) "oldest source" "execution_receipt"
    (List.nth entries 1 |> json_string_field "source");
  let trajectory_json = List.hd entries in
  Alcotest.(check int) "keeper turn preserved" 1
    (json_int_field "keeper_turn_id" trajectory_json);
  Alcotest.(check int) "OAS turn preserved" 4
    (json_int_field "oas_turn" trajectory_json);
  Alcotest.(check string) "OAS tool use id preserved"
    "tool-use-telemetry-read-1"
    (json_string_field "tool_use_id" trajectory_json);
  Alcotest.(check string) "MASC execution id preserved"
    "exec-telemetry-read-1"
    (json_string_field "execution_id" trajectory_json);
  let schedule =
    match trajectory_json with
    | `Assoc fields ->
      (match List.assoc_opt "schedule" fields with
       | Some (`Assoc _ as schedule) -> schedule
       | Some _ | None -> Alcotest.fail "expected exact OAS schedule")
    | _ -> Alcotest.fail "expected trajectory object"
  in
  Alcotest.(check int) "planned index preserved" 5
    (json_int_field "planned_index" schedule);
  Alcotest.(check int) "batch index preserved" 1
    (json_int_field "batch_index" schedule);
  Alcotest.(check int) "batch size preserved" 2
    (json_int_field "batch_size" schedule);
  Alcotest.(check string) "execution mode preserved" "concurrent"
    (json_string_field "execution_mode" schedule)

let test_goal_event_source_and_summary () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_goal_event" in
  let root = masc_root dir in
  Fs_compat.mkdir_p root;
  let newer_ts = Unix.gettimeofday () in
  let older_ts = newer_ts -. 1.0 in
  let path = Filename.concat root "goal_events.jsonl" in
  Fs_compat.append_file path
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("ts", `String (Masc_domain.iso8601_of_unix_seconds older_ts));
            ("goal_id", `String "goal-1");
            ("event_type", `String "transition_requested");
            ("payload", `Assoc [ ("phase", `String "active") ]);
          ])
     ^ "\n");
  Fs_compat.append_file path
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("ts", `String (Masc_domain.iso8601_of_unix_seconds newer_ts));
            ("goal_id", `String "goal-1");
            ("event_type", `String "transition_completed");
            ("payload", `Assoc [ ("phase", `String "done") ]);
          ])
     ^ "\n");
  let entries =
    Telemetry_unified.read_unified
      ~base_path:dir
      ~masc_root:root
      ~sources:[ Telemetry_unified.Goal_event ]
      ~n:10
      ()
  in
  Alcotest.(check int) "two goal events" 2 (List.length entries);
  Alcotest.(check string) "newest source" "goal_event"
    (List.hd entries |> json_string_field "source");
  Alcotest.(check string) "newest event" "transition_completed"
    (List.hd entries |> json_string_field "event_type");
  let summary =
    Telemetry_unified.summary_json ~base_path:dir ~masc_root:root ()
  in
  let goal_summary = source_summary "goal_event" summary in
  Alcotest.(check int) "goal event count" 2
    (json_int_field "entry_count" goal_summary);
  Alcotest.(check string) "goal event health" "ok"
    (json_string_field "health" goal_summary);
  Alcotest.(check string) "goal dashboard surface"
    "/api/v1/dashboard/goals"
    (json_string_field "dashboard_surface" goal_summary)

let test_goal_event_missing_reports_not_yet () =
  (* Goal_event store is created lazily by goal_fsm on the first verification.
     A fleet that has not yet verified a goal MUST surface as a neutral
     [not_yet] state, not the alarming [missing] state used for sources that
     should always exist (Tool_call_io, Keeper_metric, ...).
     Locks in the contract added by #10921. *)
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_goal_event_missing" in
  let root = masc_root dir in
  Fs_compat.mkdir_p root;
  (* Intentionally do NOT create goal_events.jsonl. *)
  let summary = Telemetry_unified.summary_json ~base_path:dir ~masc_root:root () in
  let goal_summary = source_summary "goal_event" summary in
  Alcotest.(check int) "no goal events yet" 0
    (json_int_field "entry_count" goal_summary);
  Alcotest.(check string) "missing-but-optional surfaces as not_yet"
    "not_yet"
    (json_string_field "health" goal_summary);
  Alcotest.(check string) "stale_reason describes the not-yet state"
    "no_entries_yet"
    (json_string_field "stale_reason" goal_summary)

let test_tool_call_io_missing_still_reports_missing () =
  (* Counterpart to [test_goal_event_missing_reports_not_yet]: a non-optional
     source must NOT silently slide into [not_yet]. Tool_call_io is written by
     every keeper turn, so absence of its store is a real write-pipeline alarm.
     Locks in the asymmetry between the two health classifications. *)
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_tool_call_io_missing" in
  let root = masc_root dir in
  Fs_compat.mkdir_p root;
  (* Intentionally do NOT create tool_calls/. *)
  let summary = Telemetry_unified.summary_json ~base_path:dir ~masc_root:root () in
  let tool_summary = source_summary "tool_call_io" summary in
  Alcotest.(check string) "non-optional missing source stays loud"
    "missing"
    (json_string_field "health" tool_summary);
  Alcotest.(check string) "stale_reason names the missing store"
    "store_missing"
    (json_string_field "stale_reason" tool_summary)

let test_fixed_source_bad_store_type_is_observed () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_bad_fixed_source" in
  let root = masc_root dir in
  Fs_compat.mkdir_p root;
  let telemetry_path = Filename.concat root "telemetry" in
  Fs_compat.append_file telemetry_path "not a directory\n";
  let before = source_read_failure_metric "agent_event" "read_fixed_source_dir" in
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:root
      ~sources:[ Telemetry_unified.Agent_event ] ()
  in
  Alcotest.(check int) "bad store reads as empty" 0 (List.length entries);
  Alcotest.(check (float 0.001)) "read failure counter increments"
    (before +. 1.0)
    (source_read_failure_metric "agent_event" "read_fixed_source_dir");
  let summary = Telemetry_unified.summary_json ~base_path:dir ~masc_root:root () in
  let agent_summary = source_summary "agent_event" summary in
  Alcotest.(check string) "bad store is an error, not empty"
    "error"
    (json_string_field "health" agent_summary);
  Alcotest.(check string) "stale reason is read failure"
    "read_failed"
    (json_string_field "stale_reason" agent_summary)

let test_keeper_discovery_bad_root_is_observed () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_bad_keeper_root" in
  let root = masc_root dir in
  Fs_compat.mkdir_p root;
  Fs_compat.append_file (Filename.concat root "keepers") "not a directory\n";
  let before =
    source_read_failure_metric "keeper_metric" "discover_keeper_metric_root"
  in
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:root
      ~sources:[ Telemetry_unified.Keeper_metric ] ()
  in
  Alcotest.(check int) "bad keeper root reads as empty" 0 (List.length entries);
  Alcotest.(check (float 0.001)) "discovery failure counter increments"
    (before +. 1.0)
    (source_read_failure_metric "keeper_metric" "discover_keeper_metric_root")

let test_trajectory_parse_errors_are_aggregated_per_file () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_bad_trajectory_rows" in
  let root = masc_root dir in
  let path = Trajectory.trajectory_path root "alice" "trace-bad" in
  let trajectory_dir = Filename.dirname path in
  Fs_compat.mkdir_p trajectory_dir;
  Fs_compat.append_file path
    (String.concat "\n"
       [
         "{not-json";
         Yojson.Safe.to_string
           (canonical_trajectory_tool_json ~ts:2000.0
              ~tool_name:"tool_execute" ~duration_ms:7
              ~execution_id:"exec-telemetry-valid-1" ());
         "{still-not-json";
         "";
       ]);
  let before =
    source_read_failure_metric "trajectory_tool_call"
      "read_trajectory_file_parse"
  in
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:root
      ~sources:[ Telemetry_unified.Trajectory_tool_call ] ()
  in
  Alcotest.(check int) "valid trajectory row still read" 1
    (List.length entries);
  Alcotest.(check (float 0.001)) "parse failures counted once per file"
    (before +. 1.0)
    (source_read_failure_metric "trajectory_tool_call"
       "read_trajectory_file_parse")

let test_summary_bad_trajectory_root_observed_once () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_bad_trajectory_root" in
  let root = masc_root dir in
  Fs_compat.mkdir_p root;
  Fs_compat.append_file (Filename.concat root "keepers")
    "not a directory\n";
  let before_summary =
    source_read_failure_metric "trajectory_tool_call"
      "summary_trajectory_root"
  in
  let before_discover =
    source_read_failure_metric "trajectory_tool_call"
      "discover_trajectory_root"
  in
  let summary = Telemetry_unified.summary_json ~base_path:dir ~masc_root:root () in
  let trajectory_summary = source_summary "trajectory_tool_call" summary in
  Alcotest.(check string) "bad trajectory root is error"
    "error"
    (json_string_field "health" trajectory_summary);
  Alcotest.(check (float 0.001)) "summary root counted once"
    (before_summary +. 1.0)
    (source_read_failure_metric "trajectory_tool_call"
       "summary_trajectory_root");
  Alcotest.(check (float 0.001)) "discovery root not double-counted"
    before_discover
    (source_read_failure_metric "trajectory_tool_call"
       "discover_trajectory_root")

let test_summary_surfaces_coverage_gaps () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_summary_gap" in
  let root = masc_root dir in
  let labels =
    [
      ("source", "agent_event");
      ("producer", "telemetry_eio");
      ("dashboard_surface", "/api/v1/dashboard/telemetry");
      ("stale_reason", "append_failed");
    ]
  in
  let before =
    Otel_metric_store.metric_value_or_zero Otel_metric_store.metric_telemetry_coverage_gap
      ~labels ()
  in
  Telemetry_coverage_gap.record
    ~masc_root:root
    ~source:"agent_event"
    ~producer:"telemetry_eio"
    ~durable_store:(Filename.concat root "telemetry")
    ~dashboard_surface:"/api/v1/dashboard/telemetry"
    ~stale_reason:"append_failed"
    ~error:"disk full"
    ();
  Alcotest.(check (float 0.001))
    "coverage gap Otel_metric_store counter increments" (before +. 1.0)
    (Otel_metric_store.metric_value_or_zero Otel_metric_store.metric_telemetry_coverage_gap
       ~labels ());
  let json = Telemetry_unified.summary_json ~base_path:dir ~masc_root:root () in
  match json with
  | `Assoc fields ->
    let gaps =
      match List.assoc_opt "coverage_gaps" fields with
      | Some (`List values) -> values
      | _ -> Alcotest.fail "expected coverage_gaps"
    in
    Alcotest.(check int) "one coverage gap" 1 (List.length gaps);
    let source_summary =
      match List.assoc_opt "sources" fields with
      | Some (`List sources) ->
        List.find
          (fun source_json ->
            String.equal "agent_event"
              (json_string_field "source" source_json))
          sources
      | _ -> Alcotest.fail "expected sources"
    in
    Alcotest.(check string) "agent_event health" "coverage_gap"
      (json_string_field "health" source_summary);
    Alcotest.(check string) "agent_event stale reason" "append_failed"
      (json_string_field "stale_reason" source_summary)
  | _ -> Alcotest.fail "expected Assoc"

let test_summary_ignores_recovered_coverage_gap () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_summary_recovered_gap" in
  let root = masc_root dir in
  Telemetry_coverage_gap.record
    ~masc_root:root
    ~source:"tool_call_io"
    ~producer:"keeper_hooks_oas"
    ~durable_store:(Filename.concat root "tool_calls")
    ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
    ~stale_reason:"tool_call_io_append_failed"
    ~error:"old fd pressure"
    ();
  let recovered_ts = Unix.gettimeofday () +. 10.0 in
  write_jsonl
    (Filename.concat root "tool_calls")
    [
      `Assoc
        [
          ("ts", `Float recovered_ts);
          ("keeper", `String "alice");
          ("tool", `String "masc_status");
          ("success", `Bool true);
        ];
    ];
  let json = Telemetry_unified.summary_json ~base_path:dir ~masc_root:root () in
  let tool_summary = source_summary "tool_call_io" json in
  Alcotest.(check string) "recovered gap health" "ok"
    (json_string_field "health" tool_summary);
  Alcotest.(check string) "recovered gap stale reason cleared" ""
    (json_string_field "stale_reason" tool_summary);
  Alcotest.(check int) "historical gap count" 1
    (json_int_field "coverage_gap_count" tool_summary);
  Alcotest.(check int) "active gap count" 0
    (json_int_field "active_coverage_gap_count" tool_summary);
  match json with
  | `Assoc fields ->
    let gaps =
      match List.assoc_opt "coverage_gaps" fields with
      | Some (`List values) -> values
      | _ -> Alcotest.fail "expected coverage_gaps"
    in
    Alcotest.(check int) "historical gap retained" 1 (List.length gaps)
  | _ -> Alcotest.fail "expected Assoc"

let test_summary_counts_all_entries_beyond_recent_cap () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_summary_full_count" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  write_raw_jsonl_rows telemetry_dir 10_050;
  let json = Telemetry_unified.summary_json ~base_path:dir ~masc_root:(masc_root dir) () in
  match json with
  | `Assoc fields ->
    let total = match List.assoc_opt "total_entries" fields with
      | Some (`Int n) -> n | _ -> -1 in
    Alcotest.(check int) "counts all rows, not read_recent cap" 10_050 total
  | _ -> Alcotest.fail "expected Assoc"

let test_replay_retention_lists_selected_sources () =
  let dir = tmpdir "telem_replay_retention" in
  let root = masc_root dir in
  let json =
    Telemetry_unified.replay_retention_json ~base_path:dir ~masc_root:root
      ~sources:[ Telemetry_unified.Oas_event; Telemetry_unified.Tool_metric ]
  in
  match json with
  | `Assoc fields ->
    Alcotest.(check string) "scope" "dashboard_telemetry_replay"
      (json_string_field "scope" json);
    Alcotest.(check string) "workspace root" root
      (json_string_field "workspace_root" json);
    let selected_sources =
      match List.assoc_opt "selected_sources" fields with
      | Some (`List values) ->
        List.map
          (function `String value -> value | _ -> Alcotest.fail "bad source")
          values
      | _ -> Alcotest.fail "expected selected_sources"
    in
    Alcotest.(check (list string)) "selected sources"
      [ "oas_event"; "tool_metric" ]
      selected_sources;
    let durable_stores =
      match List.assoc_opt "durable_stores" fields with
      | Some (`List values) -> values
      | _ -> Alcotest.fail "expected durable_stores"
    in
    Alcotest.(check int) "durable store count" 2 (List.length durable_stores);
    let oas_store =
      List.find
        (fun value ->
          String.equal "oas_event" (json_string_field "source" value))
        durable_stores
    in
    Alcotest.(check string) "oas durable store"
      (Filename.concat root "oas-events")
      (json_string_field "durable_store" oas_store);
    Alcotest.(check string) "oas dashboard surface"
      "/api/v1/dashboard/telemetry"
      (json_string_field "dashboard_surface" oas_store)
  | _ -> Alcotest.fail "expected Assoc"

(* ── Cluster-aware path ─────────────────────────── *)

let test_cluster_aware_read () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_cluster" in
  (* Simulate cluster layout: masc_root is NOT base_path/.masc but
     base_path/.masc/clusters/my-cluster — the scenario that was broken. *)
  let cluster_masc = Filename.concat dir ".masc/clusters/my-cluster" in
  let telemetry_dir = Filename.concat cluster_masc "telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  write_jsonl telemetry_dir [
    `Assoc [("timestamp", `Float 5000.0); ("event", `String "cluster_event")];
  ];
  (* Read with cluster-aware masc_root — should find the entry *)
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:cluster_masc
      ~sources:[Telemetry_unified.Agent_event] ()
  in
  Alcotest.(check int) "cluster entry found" 1 (List.length entries);
  (* Read with default masc_root — should NOT find it (old bug behavior) *)
  let default_entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[Telemetry_unified.Agent_event] ()
  in
  Alcotest.(check int) "default masc_root misses cluster data" 0 (List.length default_entries)

let test_cluster_keeper_metrics () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_cluster_keeper" in
  let cluster_masc = Filename.concat dir ".masc/clusters/prod" in
  let keeper_dir = Filename.concat cluster_masc "keepers/alpha/metrics" in
  Fs_compat.mkdir_p keeper_dir;
  write_jsonl keeper_dir [
    `Assoc [("ts_unix", `Float 6000.0); ("name", `String "alpha"); ("channel", `String "turn")];
  ];
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:cluster_masc
      ~sources:[Telemetry_unified.Keeper_metric] ()
  in
  Alcotest.(check int) "cluster keeper metric found" 1 (List.length entries)

(* ── Trajectory summary incremental cache ─────────── *)

let trajectory_row ~ts ~tool_name =
  (canonical_trajectory_tool_json ~ts ~tool_name ~duration_ms:1
     ~execution_id:(Printf.sprintf "exec-%s-%.0f" tool_name ts) ()
   |> Yojson.Safe.to_string)
  ^ "\n"

let thinking_row ~ts =
  Yojson.Safe.to_string
    (`Assoc
       [ ("schema", `String "masc.keeper_trajectory.v1")
       ; ("type", `String "thinking")
       ; ("ts", `Float ts)
       ; ("ts_iso", `String (Masc_domain.iso8601_of_unix_seconds ts))
       ; ("keeper_turn_id", `Int 1)
       ; ("oas_turn", `Int 0)
       ; ("block_index", `Int 0)
       ; ( "block",
           `Assoc
             [ ("type", `String "thinking")
             ; ("thinking", `String "reasoning text")
             ] )
       ])
  ^ "\n"

let test_trajectory_read_scan_budget_counts_thinking_rows () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_traj_scan_budget" in
  let root = masc_root dir in
  let trace = Trajectory.trajectory_path root "alice" "trace-scan-budget" in
  Fs_compat.mkdir_p (Filename.dirname trace);
  (* The Tool row is older than the canonical rows in the bounded tail.  A
     Tool-only projection must not keep paging through Thinking rows until it
     happens to find a matching Tool. *)
  Fs_compat.append_file trace (trajectory_row ~ts:100.0 ~tool_name:"old_tool");
  Fs_compat.append_file trace (thinking_row ~ts:200.0);
  Fs_compat.append_file trace (thinking_row ~ts:300.0);
  Fs_compat.append_file trace (thinking_row ~ts:400.0);
  let entries =
    Telemetry_unified.read_unified ~base_path:dir ~masc_root:root
      ~sources:[ Telemetry_unified.Trajectory_tool_call ] ~n:1 ()
  in
  Alcotest.(check int) "bounded canonical tail contains no Tool row" 0
    (List.length entries)

(* The (count, latest_ts) summary must (a) count only tool-call rows,
   (b) pick appended rows up on the next call without any cache reset —
   the snapshot loop calls this every 2 s and must not re-parse the whole
   store — and (c) agree with a cold-cache recomputation. *)
let test_trajectory_summary_incremental () =
  Telemetry_unified.For_testing.reset_trajectory_summary_cache_for_testing ();
  let dir = tmpdir "telem_traj_summary_incr" in
  let root = masc_root dir in
  let trace = Trajectory.trajectory_path root "alice" "trace-1" in
  let keeper_dir = Filename.dirname trace in
  Fs_compat.mkdir_p keeper_dir;
  Fs_compat.append_file trace (trajectory_row ~ts:100.0 ~tool_name:"tool_a");
  Fs_compat.append_file trace (thinking_row ~ts:150.0);
  Fs_compat.append_file trace (trajectory_row ~ts:200.0 ~tool_name:"tool_b");
  let count, latest =
    Telemetry_unified.For_testing.trajectory_tool_call_summary_stats
      ~masc_root:root
  in
  Alcotest.(check int) "thinking rows excluded from count" 2 count;
  Alcotest.(check (option (float 0.001))) "latest ts from tool rows only"
    (Some 200.0) latest;
  (* Append behind the warm cache: the delta must be picked up without a
     reset (this is the property the 2 s snapshot loop depends on). *)
  Fs_compat.append_file trace (trajectory_row ~ts:300.0 ~tool_name:"tool_c");
  let count2, latest2 =
    Telemetry_unified.For_testing.trajectory_tool_call_summary_stats
      ~masc_root:root
  in
  Alcotest.(check int) "appended tool row visible without reset" 3 count2;
  Alcotest.(check (option (float 0.001))) "latest ts advanced" (Some 300.0) latest2;
  (* Cold cache must agree with the warm incremental result. *)
  Telemetry_unified.For_testing.reset_trajectory_summary_cache_for_testing ();
  let count3, latest3 =
    Telemetry_unified.For_testing.trajectory_tool_call_summary_stats
      ~masc_root:root
  in
  Alcotest.(check int) "cold recomputation agrees" count2 count3;
  Alcotest.(check (option (float 0.001))) "cold latest agrees" latest2 latest3

(* ── Runner ──────────────────────────────────────── *)

let () =
  Alcotest.run "telemetry_unified"
    [
      ( "source",
        [
          Alcotest.test_case "roundtrip" `Quick test_source_roundtrip;
          Alcotest.test_case "unknown" `Quick test_source_of_string_unknown;
        ] );
      ( "read",
        [
          Alcotest.test_case "empty base" `Quick test_empty_returns_empty;
          Alcotest.test_case "agent events" `Quick test_agent_event_source;
          Alcotest.test_case "oas events + scope filter" `Quick
            test_oas_event_source_and_scope_filter;
          Alcotest.test_case "agent tool_called scope promotion" `Quick
            test_keeper_tool_called_scope_promoted_for_filters;
          Alcotest.test_case "dedupe shadow agent tool_called" `Quick
            test_shadow_keeper_tool_called_deduped_from_unified_view;
          Alcotest.test_case "keeper metrics" `Quick test_keeper_metrics_per_keeper;
          Alcotest.test_case "keeper metrics fast path keeps noisy top n" `Quick
            test_keeper_metrics_fast_path_preserves_noisy_keeper_top_n;
          Alcotest.test_case "keeper metrics fast path marker" `Quick
            test_keeper_metrics_fast_path_sets_truncated_with_marker;
          Alcotest.test_case "sorted newest first" `Quick test_sorted_newest_first;
          Alcotest.test_case "n limits output" `Quick test_n_limits_output;
          Alcotest.test_case "time window reports total before limit" `Quick
            test_time_window_reports_total_before_limit;
          Alcotest.test_case "time window reads matching day files" `Quick
            test_time_window_reads_matching_day_files;
          Alcotest.test_case "unbounded reads are rejected" `Quick
            test_unbounded_read_is_rejected;
          Alcotest.test_case "negative offsets are rejected" `Quick
            test_negative_offset_is_rejected;
          Alcotest.test_case "trajectory and receipts" `Quick
            test_read_unified_reads_trajectory_and_execution_receipts;
          Alcotest.test_case "goal events" `Quick
            test_goal_event_source_and_summary;
          Alcotest.test_case "fixed source bad store type is observed" `Quick
            test_fixed_source_bad_store_type_is_observed;
          Alcotest.test_case "keeper discovery bad root is observed" `Quick
            test_keeper_discovery_bad_root_is_observed;
          Alcotest.test_case "trajectory parse failures are aggregated"
            `Quick
            test_trajectory_parse_errors_are_aggregated_per_file;
          Alcotest.test_case "trajectory scan budget counts thinking rows"
            `Quick
            test_trajectory_read_scan_budget_counts_thinking_rows;
        ] );
      ( "summary",
        [
          Alcotest.test_case "empty" `Quick test_summary_empty;
          Alcotest.test_case "with data" `Quick test_summary_with_data;
          Alcotest.test_case "includes freshness metadata" `Quick
            test_summary_includes_freshness_metadata;
          Alcotest.test_case "tool_metric surface points to raw metrics" `Quick
            test_summary_tool_metric_surface_points_to_raw_metrics;
          Alcotest.test_case "includes trajectory and execution receipt sources"
            `Quick
            test_summary_includes_trajectory_and_execution_receipt_sources;
          Alcotest.test_case "surfaces coverage gaps" `Quick
            test_summary_surfaces_coverage_gaps;
          Alcotest.test_case "ignores recovered coverage gaps" `Quick
            test_summary_ignores_recovered_coverage_gap;
          Alcotest.test_case "goal_event missing reports not_yet" `Quick
            test_goal_event_missing_reports_not_yet;
          Alcotest.test_case "tool_call_io missing stays missing" `Quick
            test_tool_call_io_missing_still_reports_missing;
          Alcotest.test_case "bad trajectory root observed once" `Quick
            test_summary_bad_trajectory_root_observed_once;
          Alcotest.test_case "counts all rows beyond recent cap" `Quick
            test_summary_counts_all_entries_beyond_recent_cap;
          Alcotest.test_case "trajectory summary cache is incremental" `Quick
            test_trajectory_summary_incremental;
          Alcotest.test_case "replay retention selected sources" `Quick
            test_replay_retention_lists_selected_sources;
        ] );
      ( "cluster",
        [
          Alcotest.test_case "cluster-aware read" `Quick test_cluster_aware_read;
          Alcotest.test_case "cluster keeper metrics" `Quick test_cluster_keeper_metrics;
        ] );
    ]
