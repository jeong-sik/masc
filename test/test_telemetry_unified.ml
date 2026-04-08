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
          Alcotest.test_case "keeper metrics" `Quick test_keeper_metrics_per_keeper;
          Alcotest.test_case "sorted newest first" `Quick test_sorted_newest_first;
          Alcotest.test_case "n limits output" `Quick test_n_limits_output;
        ] );
      ( "summary",
        [
          Alcotest.test_case "empty" `Quick test_summary_empty;
          Alcotest.test_case "with data" `Quick test_summary_with_data;
        ] );
      ( "cluster",
        [
          Alcotest.test_case "cluster-aware read" `Quick test_cluster_aware_read;
          Alcotest.test_case "cluster keeper metrics" `Quick test_cluster_keeper_metrics;
        ] );
    ]
