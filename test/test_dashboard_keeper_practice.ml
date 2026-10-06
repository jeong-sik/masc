(** Tests for the keeper practice summary fold.

    Covers:
    - autonomous turn-mode / outcome mix over a mixed decision tail
    - direct turns counted on paths only, never in the autonomous buckets
    - non-turn log siblings ignored without counting
    - strict parse: unknown outcome/path labels land unrecognized, never
      defaulted; absent/unknown modes land mode-absent
    - missing log folds to the zero summary
    - fleet JSON shape and limit clamping *)

open Alcotest
module Workspace = Masc.Workspace
module Keeper_fs = Masc.Keeper_fs
module Practice = Dashboard_http_keeper_practice
module Json = Yojson.Safe.Util

let test_counter = ref 0

let tmpdir prefix =
  incr test_counter;
  Filename.temp_dir (Printf.sprintf "%s_%d_" prefix !test_counter) ""
;;

let with_config f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = tmpdir "dashboard_keeper_practice" in
  let config = Workspace.default_config base_dir in
  f config
;;

let keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)
;;

let append_jsonl path json =
  let (_ : string) = Keeper_fs.ensure_dir (Filename.dirname path) in
  Masc.Keeper_types_support.append_jsonl_line path json
;;

let turn_row fields = `Assoc (("event", `String "turn") :: fields)

let label_counts json =
  json
  |> Json.to_list
  |> List.map (fun item ->
    ( Json.(item |> member "label" |> to_string)
    , Json.(item |> member "count" |> to_int) ))
;;

let test_practice_counts_autonomous_mix () =
  let rows =
    [ turn_row
        [ "ts_unix", `Float 1_000.0
        ; "execution_path", `String "autonomous_cycle"
        ; "turn_mode", `String "tool_use"
        ; "outcome", `String "success"
        ; "tool_call_count", `Int 4
        ; "tools_used", `List [ `String "tool_execute"; `String "tool_execute" ]
        ; "trigger_signals", `List [ `String "claimable_task" ]
        ; "latency_ms", `Int 80_000
        ]
    ; turn_row
        [ "ts_unix", `Float 1_100.0
        ; "execution_path", `String "autonomous_cycle"
        ; "turn_mode", `String "tool_use"
        ; "outcome", `String "checkpoint"
        ; "tool_call_count", `Int 2
        ; "tools_used", `List [ `String "masc_board_comment" ]
        ; "trigger_signals", `List [ `String "board_activity"; `String "claimable_task" ]
        ; "latency_ms", `Int 20_000
        ]
    ; turn_row
        [ "ts_unix", `Float 1_200.0
        ; "execution_path", `String "autonomous_cycle"
        ; "turn_mode", `String "text_response"
        ; "outcome", `String "success"
        ; "tool_call_count", `Int 0
        ; "tools_used", `List []
        ; "trigger_signals", `List [ `String "board_activity" ]
        ; "latency_ms", `Int 10_000
        ]
    ; turn_row
        [ "ts_unix", `Float 1_300.0
        ; "execution_path", `String "autonomous_cycle"
        ; "outcome", `String "error"
        ; "terminal_reason_code", `String "api_error_rate_limited"
        ; "trigger_signals", `List [ `String "claimable_task" ]
        ; "latency_ms", `Int 2_000
        ]
    ; turn_row
        [ "ts_unix", `Float 1_400.0
        ; "execution_path", `String "direct_turn"
        ; "turn_mode", `String "tool_use"
        ; "outcome", `String "success"
        ; "tool_call_count", `Int 9
        ; "tools_used", `List [ `String "masc_board_post" ]
        ; "latency_ms", `Int 5_000
        ]
    ; `Assoc [ "event", `String "tool_exec"; "ts_unix", `Float 1_500.0 ]
    ]
  in
  let json = Practice.to_json (Practice.summarize_rows ~keeper_name:"mix" rows) in
  check string "schema" "keeper.practice.v1" Json.(json |> member "schema" |> to_string);
  check string "keeper" "mix" Json.(json |> member "keeper" |> to_string);
  let window = Json.(json |> member "window") in
  check int "tail rows" 6 Json.(window |> member "tail_rows" |> to_int);
  check int "turn rows" 5 Json.(window |> member "turn_rows" |> to_int);
  check int "unrecognized" 0 Json.(window |> member "unrecognized_turn_rows" |> to_int);
  check (float 0.001) "since" 1000.0 Json.(window |> member "since_unix" |> to_float);
  check (float 0.001) "until" 1300.0 Json.(window |> member "until_unix" |> to_float);
  let paths = Json.(json |> member "paths") in
  check int "autonomous" 4 Json.(paths |> member "autonomous_cycle" |> to_int);
  check int "direct" 1 Json.(paths |> member "direct_turn" |> to_int);
  let auto = Json.(json |> member "autonomous") in
  let modes = Json.(auto |> member "modes") in
  check int "tool_use" 2 Json.(modes |> member "tool_use" |> to_int);
  check int "text_response" 1 Json.(modes |> member "text_response" |> to_int);
  check int "skip_text" 0 Json.(modes |> member "skip_text" |> to_int);
  check int "noop" 0 Json.(modes |> member "noop" |> to_int);
  check int "mode absent" 1 Json.(modes |> member "absent" |> to_int);
  let outcomes = Json.(auto |> member "outcomes") in
  check int "success" 2 Json.(outcomes |> member "success" |> to_int);
  check int "checkpoint" 1 Json.(outcomes |> member "checkpoint" |> to_int);
  check int "input_required" 0 Json.(outcomes |> member "input_required" |> to_int);
  check int "error" 1 Json.(outcomes |> member "error" |> to_int);
  check
    (list (pair string int))
    "terminal codes"
    [ "api_error_rate_limited", 1 ]
    (label_counts Json.(auto |> member "terminal_codes"));
  check
    (list (pair string int))
    "triggers"
    [ "claimable_task", 3; "board_activity", 2 ]
    (label_counts Json.(auto |> member "triggers"));
  let tools = Json.(auto |> member "tools") in
  check int "tool calls total" 6 Json.(tools |> member "total_calls" |> to_int);
  check
    (list (pair string int))
    "tools by name"
    [ "tool_execute", 2; "masc_board_comment", 1 ]
    (label_counts Json.(tools |> member "by_name"));
  let latency = Json.(auto |> member "latency_ms") in
  check int "latency total" 112_000 Json.(latency |> member "total" |> to_int);
  check int "latency count" 4 Json.(latency |> member "count" |> to_int);
  check int "latency max" 80_000 Json.(latency |> member "max" |> to_int)
;;

let test_practice_strict_parse_never_defaults () =
  let rows =
    [ turn_row
        [ "execution_path", `String "autonomous_cycle"
        ; "turn_mode", `String "tool_use"
        ; "outcome", `String "bogus_outcome"
        ]
    ; turn_row
        [ "execution_path", `String "elsewhere"
        ; "turn_mode", `String "tool_use"
        ; "outcome", `String "success"
        ]
    ; turn_row
        [ "execution_path", `String "autonomous_cycle"
        ; "turn_mode", `String "telepathy"
        ; "outcome", `String "success"
        ]
    ; turn_row
        [ "execution_path", `String "autonomous_cycle"
        ; "turn_mode", `String "tool_use"
        ]
    ]
  in
  let json = Practice.to_json (Practice.summarize_rows ~keeper_name:"strict" rows) in
  let window = Json.(json |> member "window") in
  check int "turn rows" 4 Json.(window |> member "turn_rows" |> to_int);
  check int "unrecognized" 3 Json.(window |> member "unrecognized_turn_rows" |> to_int);
  let auto = Json.(json |> member "autonomous") in
  check int "one autonomous" 1 Json.(auto |> member "turns" |> to_int);
  let modes = Json.(auto |> member "modes") in
  check int "unknown mode is absent" 1 Json.(modes |> member "absent" |> to_int);
  check int "not tool_use" 0 Json.(modes |> member "tool_use" |> to_int);
  let outcomes = Json.(auto |> member "outcomes") in
  check int "success" 1 Json.(outcomes |> member "success" |> to_int);
  check int "error" 0 Json.(outcomes |> member "error" |> to_int)
;;

let test_practice_missing_log_is_zero () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "no-such-log" in
  let json = Practice.to_json (Practice.summarize_keeper config meta ~limit:10 ()) in
  let window = Json.(json |> member "window") in
  check int "tail rows" 0 Json.(window |> member "tail_rows" |> to_int);
  check int "turn rows" 0 Json.(window |> member "turn_rows" |> to_int);
  check bool "since null" true Json.(window |> member "since_unix" = `Null);
  let auto = Json.(json |> member "autonomous") in
  check int "turns" 0 Json.(auto |> member "turns" |> to_int);
  check bool "latency max null" true Json.(auto |> member "latency_ms" |> member "max" = `Null)
;;

let test_practice_reads_decision_log_tail () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "tail-reader" in
  let path = Masc.Keeper_types_support.keeper_decision_log_path config meta.name in
  append_jsonl
    path
    (turn_row
       [ "ts_unix", `Float 2_000.0
       ; "execution_path", `String "autonomous_cycle"
       ; "turn_mode", `String "noop"
       ; "outcome", `String "success"
       ; "latency_ms", `Int 100
       ]);
  append_jsonl path (`Assoc [ "event", `String "tool_exec"; "ts_unix", `Float 2_001.0 ]);
  let json = Practice.to_json (Practice.summarize_keeper config meta ~limit:10 ()) in
  let window = Json.(json |> member "window") in
  check int "tail rows" 2 Json.(window |> member "tail_rows" |> to_int);
  check int "turn rows" 1 Json.(window |> member "turn_rows" |> to_int);
  let auto = Json.(json |> member "autonomous") in
  let modes = Json.(auto |> member "modes") in
  check int "noop" 1 Json.(modes |> member "noop" |> to_int)
;;

let test_practice_fleet_shape_and_limit_clamp () =
  with_config
  @@ fun config ->
  let keepers = [ keeper_meta "fleet-a"; keeper_meta "fleet-b" ] in
  let json = Practice.fleet_json config keepers ~limit:0 () in
  check int "clamped limit" 1 Json.(json |> member "limit" |> to_int);
  let items = Json.(json |> member "keepers" |> to_list) in
  check int "two keepers" 2 (List.length items);
  check bool "generated_at" true Json.(json |> member "generated_at" |> to_float >= 0.0);
  List.iter
    (fun item ->
      check string "item schema" "keeper.practice.v1" Json.(item |> member "schema" |> to_string))
    items
;;

let () =
  run
    "dashboard_keeper_practice"
    [ ( "fold"
      , [ test_case "autonomous mix" `Quick test_practice_counts_autonomous_mix
        ; test_case "strict parse" `Quick test_practice_strict_parse_never_defaults
        ; test_case "missing log" `Quick test_practice_missing_log_is_zero
        ; test_case "tail read" `Quick test_practice_reads_decision_log_tail
        ; test_case "fleet shape" `Quick test_practice_fleet_shape_and_limit_clamp
        ] )
    ]
;;
