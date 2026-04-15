(** test_telemetry_unified — Tests for unified telemetry read aggregation. *)

open Masc_mcp

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

let masc_root dir = Filename.concat dir ".masc"

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

let test_time_window_n_zero_disables_truncation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "telem_window_unbounded" in
  let telemetry_dir = Filename.concat dir ".masc/telemetry" in
  Fs_compat.mkdir_p telemetry_dir;
  let now = Unix.gettimeofday () in
  write_jsonl telemetry_dir [
    `Assoc [("timestamp", `Float (now -. 900.0)); ("event", `String "a")];
    `Assoc [("timestamp", `Float (now -. 600.0)); ("event", `String "b")];
    `Assoc [("timestamp", `Float (now -. 300.0)); ("event", `String "c")];
  ];
  let result =
    Telemetry_unified.read_unified_result ~base_path:dir ~masc_root:(masc_root dir)
      ~sources:[Telemetry_unified.Agent_event]
      ~since_ts:(now -. 3_600.0) ~until_ts:now ~n:0 ()
  in
  Alcotest.(check int) "returns every matching entry" 3 (List.length result.entries);
  Alcotest.(check int) "total matching preserved" 3 result.total_matching_entries;
  Alcotest.(check bool) "unbounded result is not truncated" false result.truncated

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
    Alcotest.(check bool) "latest ts close to event" true
      (abs_float (latest_ts -. recent_ts) < 5.0);
    Alcotest.(check bool) "latest iso present" true (String.length latest_iso > 0);
    Alcotest.(check bool) "latest age bounded" true
      (latest_age >= 0.0 && latest_age < 180.0)
  | None -> Alcotest.fail "expected agent_event source summary"

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
          Alcotest.test_case "keeper metrics" `Quick test_keeper_metrics_per_keeper;
          Alcotest.test_case "sorted newest first" `Quick test_sorted_newest_first;
          Alcotest.test_case "n limits output" `Quick test_n_limits_output;
          Alcotest.test_case "time window reports total before limit" `Quick
            test_time_window_reports_total_before_limit;
          Alcotest.test_case "time window reads matching day files" `Quick
            test_time_window_reads_matching_day_files;
          Alcotest.test_case "time window n=0 disables truncation" `Quick
            test_time_window_n_zero_disables_truncation;
        ] );
      ( "summary",
        [
          Alcotest.test_case "empty" `Quick test_summary_empty;
          Alcotest.test_case "with data" `Quick test_summary_with_data;
          Alcotest.test_case "includes freshness metadata" `Quick
            test_summary_includes_freshness_metadata;
          Alcotest.test_case "counts all rows beyond recent cap" `Quick
            test_summary_counts_all_entries_beyond_recent_cap;
        ] );
      ( "cluster",
        [
          Alcotest.test_case "cluster-aware read" `Quick test_cluster_aware_read;
          Alcotest.test_case "cluster keeper metrics" `Quick test_cluster_keeper_metrics;
        ] );
    ]
