open Alcotest

module Coord = Masc_mcp.Coord
module Dashboard_http_keeper = Masc_mcp.Dashboard_http_keeper
module Keeper_types = Masc_mcp.Keeper_types

let test_counter = ref 0

let temp_dir prefix =
  incr test_counter;
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%d"
         prefix (Unix.getpid ()) !test_counter
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  (try Unix.mkdir path 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  path

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String ("trace-" ^ name));
          ("cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name);
          ("last_model_used", `String "test-model");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

let append_metric config keeper_name fields =
  Dated_jsonl.append
    (Keeper_types.keeper_metrics_store config keeper_name)
    (`Assoc fields)

let keeper_item json =
  match Yojson.Safe.Util.(json |> member "keepers") with
  | `List [ item ] -> item
  | other ->
      fail
        ("expected exactly one keeper aggregate, got: "
         ^ Yojson.Safe.to_string other)

let int_field key json =
  match Yojson.Safe.Util.member key json with
  | `Int value -> value
  | other ->
      fail
        (Printf.sprintf "field %s is not int: %s"
           key (Yojson.Safe.to_string other))

let float_field key json =
  match Yojson.Safe.Util.member key json with
  | `Float value -> value
  | `Int value -> float_of_int value
  | other ->
      fail
        (Printf.sprintf "field %s is not float: %s"
           key (Yojson.Safe.to_string other))

let list_field key json =
  match Yojson.Safe.Util.member key json with
  | `List values -> values
  | other ->
      fail
        (Printf.sprintf "field %s is not list: %s"
           key (Yojson.Safe.to_string other))

let test_heartbeat_snapshots_do_not_count_as_cost_samples () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
  let base_dir = temp_dir "keeper_cost_aggregates" in
  let config = Coord.default_config base_dir in
  ignore (Coord.init config ~agent_name:None);
  let keeper_name = "cost-keeper" in
  let meta = make_meta keeper_name in
  let ts = Unix.gettimeofday () -. 1.0 in
  append_metric config keeper_name
    [
      ("ts_unix", `Float ts);
      ("channel", `String "heartbeat");
      ("work_kind", `String "llm_call");
      ("cost_usd", `Float 42.0);
      ("latency_ms", `Int 500);
      ("input_tokens", `Int 1000);
      ("output_tokens", `Int 1000);
      ("total_tokens", `Int 2000);
      ("model_used", `String "heartbeat-model");
    ];
  append_metric config keeper_name
    [
      ("ts_unix", `Float ts);
      ("channel", `String "turn");
      ("work_kind", `String "status_tick");
      ("cost_usd", `Float 13.0);
      ("latency_ms", `Int 300);
      ("input_tokens", `Int 300);
      ("output_tokens", `Int 300);
      ("total_tokens", `Int 600);
      ("model_used", `String "status-model");
    ];
  append_metric config keeper_name
    [
      ("ts_unix", `Float ts);
      ("snapshot_source", `String "keeper_context_status");
      ("cost_usd", `Float 7.0);
      ("latency_ms", `Int 150);
      ("input_tokens", `Int 200);
      ("output_tokens", `Int 200);
      ("total_tokens", `Int 400);
      ("model_used", `String "snapshot-model");
    ];
  append_metric config keeper_name
    [
      ("ts_unix", `Float ts);
      ("channel", `String "turn");
      ("work_kind", `String "llm_call");
      ("cost_usd", `Float 0.25);
      ("latency_ms", `Int 100);
      ("input_tokens", `Int 10);
      ("output_tokens", `Int 5);
      ("total_tokens", `Int 15);
      ("model_used", `String "test-model");
    ];
  let aggregate =
    Dashboard_http_keeper.keeper_cost_aggregates_json
      ~config ~keepers:[ meta ] ~window_minutes:60
    |> keeper_item
  in
  check int "only real call counted" 1 (int_field "sample_count" aggregate);
  check (float 0.0001) "total cost excludes snapshots" 0.25
    (float_field "total_cost_usd" aggregate);
  check int "input tokens exclude snapshots" 10
    (int_field "total_input_tokens" aggregate);
  check int "output tokens exclude snapshots" 5
    (int_field "total_output_tokens" aggregate);
  check int "total tokens exclude snapshots" 15
    (int_field "total_tokens" aggregate);
  check (float 0.0001) "p50 latency excludes snapshots" 100.0
    (float_field "p50_latency_ms" aggregate);
  check (float 0.0001) "p95 latency excludes snapshots" 100.0
    (float_field "p95_latency_ms" aggregate);
  match list_field "model_breakdown" aggregate with
  | [ item ] ->
      check string "model breakdown model" "test-model"
        Yojson.Safe.Util.(item |> member "model" |> to_string);
      check (float 0.0001) "model breakdown cost" 0.25
        (float_field "cost_usd" item)
  | other ->
      fail
        ("model breakdown should contain only the real call: "
         ^ Yojson.Safe.to_string (`List other))

let () =
  run "dashboard_keeper_cost_aggregates"
    [
      ( "keeper cost aggregates",
        [
          test_case "ignores heartbeat status snapshots" `Quick
            test_heartbeat_snapshots_do_not_count_as_cost_samples;
        ] );
    ]
