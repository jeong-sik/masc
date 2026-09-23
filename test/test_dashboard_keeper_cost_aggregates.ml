open Alcotest

module Workspace = Masc.Workspace
module Dashboard_http_keeper = Dashboard_http_keeper
module Keeper_types = Keeper_types
module Keeper_types_support = Masc.Keeper_types_support
module Keeper_metrics_record = Masc.Keeper_metrics_record

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
          ("trace_id", `String ("trace-" ^ name));
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

let append_metric config keeper_name fields =
  Dated_jsonl.append
    (Keeper_types_support.keeper_metrics_store config keeper_name)
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

(* Every turn row lands in exactly one of reported, unreported, unread, for
   cost and for tokens alike; a path that skips a tally shows up here. *)
let check_partition aggregate =
  let samples = int_field "sample_count" aggregate in
  List.iter
    (fun prefix ->
      check int (prefix ^ " readings partition the samples") samples
        (int_field (prefix ^ "_reported_samples") aggregate
        + int_field (prefix ^ "_unreported_samples") aggregate
        + int_field (prefix ^ "_unread_samples") aggregate))
    [ "cost"; "tokens" ]

let float_field key json =
  match Yojson.Safe.Util.member key json with
  | `Float value -> value
  | `Int value -> float_of_int value
  | other ->
      fail
        (Printf.sprintf "field %s is not float: %s"
           key (Yojson.Safe.to_string other))

let test_only_current_turn_rows_count_as_cost_samples () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
  let base_dir = temp_dir "keeper_cost_aggregates" in
  let config = Workspace.default_config base_dir in
  ignore (Workspace.init config ~agent_name:None);
  let keeper_name = "cost-keeper" in
  let meta = make_meta keeper_name in
  let ts = Unix.gettimeofday () -. 1.0 in
  (* Retired versionless row: never decoded, regardless of its shape. *)
  append_metric config keeper_name
    [
      ("ts_unix", `Float ts);
      ("cost_usd", `Float 42.0);
      ("latency_ms", `Int 500);
      ("input_tokens", `Int 1000);
      ("output_tokens", `Int 1000);
      ("total_tokens", `Int 2000);
    ];
  append_metric config keeper_name
    (Keeper_metrics_record.fields Keeper_metrics_record.Heartbeat
    @ [
      ("ts_unix", `Float ts);
      ("channel", `String "heartbeat");
      ("cost_usd", `Float 13.0);
      ("latency_ms", `Int 300);
      ( "usage"
      , `Assoc
          [ "input_tokens", `Int 300
          ; "output_tokens", `Int 300
          ; "total_tokens", `Int 600
          ] )
    ]);
  append_metric config keeper_name
    (Keeper_metrics_record.fields Keeper_metrics_record.Turn
    @ [
      ("ts_unix", `Float ts);
      ("channel", `String "turn");
      ("cost_usd", `Float 0.25);
      ("latency_ms", `Int 100);
      ( "usage"
      , `Assoc
          [ "input_tokens", `Int 10
          ; "output_tokens", `Int 5
          ; "total_tokens", `Int 15
          ] )
    ]);
  append_metric config keeper_name
    (Keeper_metrics_record.fields Keeper_metrics_record.Turn
    @ [
      ("ts_unix", `Float ts);
      ("channel", `String "turn");
      ("cost_usd", `Float 0.25);
      ("latency_ms", `Int 100);
      ("usage",
       `Assoc
         [
           ("input_tokens", `Int 7);
           ("output_tokens", `Int 3);
           ("total_tokens", `Int 10);
         ]);
    ]);
  let aggregate =
    Dashboard_http_keeper.keeper_cost_aggregates_json
      ~config ~keepers:[ meta ] ~window_minutes:60
    |> keeper_item
  in
  check int "only current turns counted" 2 (int_field "sample_count" aggregate);
  check_partition aggregate;
  check (float 0.0001) "total cost excludes retired rows and heartbeat" 0.5
    (float_field "total_cost_usd" aggregate);
  check int "input tokens include nested current schema" 17
    (int_field "total_input_tokens" aggregate);
  check int "output tokens include nested current schema" 8
    (int_field "total_output_tokens" aggregate);
  check int "total tokens include nested current schema" 25
    (int_field "total_tokens" aggregate);
  check (float 0.0001) "p50 latency excludes snapshots" 100.0
    (float_field "p50_latency_ms" aggregate);
  check (float 0.0001) "p95 latency excludes snapshots" 100.0
    (float_field "p95_latency_ms" aggregate);
  check int "every counted turn reported a cost" 2
    (int_field "cost_reported_samples" aggregate);
  check int "no counted turn left its cost out" 0
    (int_field "cost_unreported_samples" aggregate)

let turn_row ~ts ~cost ~latency_ms ~total_tokens =
  Keeper_metrics_record.fields Keeper_metrics_record.Turn
  @ [
    ("ts_unix", `Float ts);
    ("channel", `String "turn");
    ("cost_usd", cost);
    ("latency_ms", `Int latency_ms);
    ( "usage"
    , `Assoc
        [ "input_tokens", `Int (total_tokens / 2)
        ; "output_tokens", `Int (total_tokens - (total_tokens / 2))
        ; "total_tokens", `Int total_tokens
        ] );
  ]

let run_keeper_aggregate ~prefix ~keeper_name rows =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
  let base_dir = temp_dir prefix in
  let config = Workspace.default_config base_dir in
  ignore (Workspace.init config ~agent_name:None);
  List.iter (append_metric config keeper_name) rows;
  Dashboard_http_keeper.keeper_cost_aggregates_json
    ~config ~keepers:[ make_meta keeper_name ] ~window_minutes:60
  |> keeper_item

(* Subscription runtimes write [cost_usd: null]. Those turns still count as
   samples and their tokens still add up, but their cost is not folded into
   the sum as $0: the aggregate sums the reported costs and says how many
   turns left theirs out. *)
let test_unreported_cost_is_counted_not_summed_as_zero () =
  let ts = Unix.gettimeofday () -. 1.0 in
  let aggregate =
    run_keeper_aggregate ~prefix:"keeper_cost_mixed" ~keeper_name:"mixed-keeper"
      [
        turn_row ~ts ~cost:(`Float 0.25) ~latency_ms:100 ~total_tokens:10;
        turn_row ~ts ~cost:`Null ~latency_ms:200 ~total_tokens:1000;
        turn_row ~ts ~cost:`Null ~latency_ms:300 ~total_tokens:2000;
      ]
  in
  check int "all three turns are samples" 3 (int_field "sample_count" aggregate);
  check_partition aggregate;
  check int "one turn reported its cost" 1
    (int_field "cost_reported_samples" aggregate);
  check int "two turns did not report a cost" 2
    (int_field "cost_unreported_samples" aggregate);
  check (float 0.0001) "sum covers only the reported cost" 0.25
    (float_field "total_cost_usd" aggregate);
  check int "tokens of unreported-cost turns still add up" 3010
    (int_field "total_tokens" aggregate)

let test_all_unreported_cost_leaves_total_unknown () =
  let ts = Unix.gettimeofday () -. 1.0 in
  let aggregate =
    run_keeper_aggregate ~prefix:"keeper_cost_unreported"
      ~keeper_name:"subscription-keeper"
      [
        turn_row ~ts ~cost:`Null ~latency_ms:200 ~total_tokens:1000;
        turn_row ~ts ~cost:`Null ~latency_ms:300 ~total_tokens:2000;
      ]
  in
  check_partition aggregate;
  check int "no turn reported a cost" 0
    (int_field "cost_reported_samples" aggregate);
  check int "both turns left their cost out" 2
    (int_field "cost_unreported_samples" aggregate);
  (match Yojson.Safe.Util.member "total_cost_usd" aggregate with
   | `Null -> ()
   | other ->
       fail
         ("total cost must stay unknown when no turn reported one, got: "
          ^ Yojson.Safe.to_string other));
  check int "tokens are still counted" 3000 (int_field "total_tokens" aggregate)

let row_with ~ts ~latency_ms ~cost ~usage =
  Keeper_metrics_record.fields Keeper_metrics_record.Turn
  @ [ ("ts_unix", `Float ts); ("channel", `String "turn"); ("latency_ms", `Int latency_ms) ]
  @ (match cost with
     | Some cost -> [ ("cost_usd", cost) ]
     | None -> [])
  @ [ ("usage", usage) ]

let reported_usage ~input ~output =
  `Assoc
    [ "input_tokens", `Int input
    ; "output_tokens", `Int output
    ; "total_tokens", `Int (input + output)
    ]

(* The writer puts [null] in all three token fields when the runtime reported
   no usage. *)
let unreported_usage =
  `Assoc
    [ "input_tokens", `Null; "output_tokens", `Null; "total_tokens", `Null ]

let null_field key json =
  match Yojson.Safe.Util.member key json with
  | `Null -> ()
  | other ->
      fail
        (Printf.sprintf "field %s must be null, got: %s"
           key (Yojson.Safe.to_string other))

(* #38106: a turn whose runtime reported no token usage is counted, not
   summed as 0 tokens. *)
let test_unreported_tokens_are_counted_not_summed_as_zero () =
  let ts = Unix.gettimeofday () -. 1.0 in
  let aggregate =
    run_keeper_aggregate ~prefix:"keeper_tokens_mixed" ~keeper_name:"mixed-tokens"
      [
        row_with ~ts ~latency_ms:100 ~cost:(Some (`Float 0.25))
          ~usage:(reported_usage ~input:7 ~output:3);
        row_with ~ts ~latency_ms:200 ~cost:(Some `Null) ~usage:unreported_usage;
      ]
  in
  check int "both turns are samples" 2 (int_field "sample_count" aggregate);
  check_partition aggregate;
  check int "one turn reported tokens" 1
    (int_field "tokens_reported_samples" aggregate);
  check int "one turn did not report tokens" 1
    (int_field "tokens_unreported_samples" aggregate);
  check int "no token field was unreadable" 0
    (int_field "tokens_unread_samples" aggregate);
  check int "input sum covers only the reported turn" 7
    (int_field "total_input_tokens" aggregate);
  check int "output sum covers only the reported turn" 3
    (int_field "total_output_tokens" aggregate);
  check int "total sum covers only the reported turn" 10
    (int_field "total_tokens" aggregate)

let test_all_unreported_tokens_leave_totals_unknown () =
  let ts = Unix.gettimeofday () -. 1.0 in
  let aggregate =
    run_keeper_aggregate ~prefix:"keeper_tokens_unreported"
      ~keeper_name:"no-usage-keeper"
      [
        row_with ~ts ~latency_ms:100 ~cost:(Some `Null) ~usage:unreported_usage;
        row_with ~ts ~latency_ms:200 ~cost:(Some `Null) ~usage:unreported_usage;
      ]
  in
  check_partition aggregate;
  check int "no turn reported tokens" 0
    (int_field "tokens_reported_samples" aggregate);
  check int "both turns left their tokens out" 2
    (int_field "tokens_unreported_samples" aggregate);
  null_field "total_input_tokens" aggregate;
  null_field "total_output_tokens" aggregate;
  null_field "total_tokens" aggregate

(* The row-kind check already keeps only turn rows, so a turn that took 0 ms
   and reported no cost is still a turn: its tokens and latency count. *)
let test_zero_latency_uncosted_turn_is_a_sample () =
  let ts = Unix.gettimeofday () -. 1.0 in
  let aggregate =
    run_keeper_aggregate ~prefix:"keeper_zero_latency" ~keeper_name:"fast-keeper"
      [
        row_with ~ts ~latency_ms:0 ~cost:(Some `Null)
          ~usage:(reported_usage ~input:40 ~output:2);
      ]
  in
  check int "the turn is a sample" 1 (int_field "sample_count" aggregate);
  check_partition aggregate;
  check int "its cost is counted as unreported" 1
    (int_field "cost_unreported_samples" aggregate);
  check int "its tokens add up" 42 (int_field "total_tokens" aggregate);
  check (float 0.0001) "its latency is in the percentiles" 0.0
    (float_field "p50_latency_ms" aggregate)

(* An integer [cost_usd] is a reported value. A row without the key is kept:
   its cost is counted as unread, and its tokens still add up. *)
let test_int_cost_is_reported_and_missing_cost_is_unread () =
  let ts = Unix.gettimeofday () -. 1.0 in
  let aggregate =
    run_keeper_aggregate ~prefix:"keeper_cost_shapes" ~keeper_name:"shape-keeper"
      [
        row_with ~ts ~latency_ms:100 ~cost:(Some (`Int 2))
          ~usage:(reported_usage ~input:1 ~output:1);
        row_with ~ts ~latency_ms:100 ~cost:None
          ~usage:(reported_usage ~input:5 ~output:5);
      ]
  in
  check int "both rows are samples" 2 (int_field "sample_count" aggregate);
  check_partition aggregate;
  check int "the integer cost is reported" 1
    (int_field "cost_reported_samples" aggregate);
  check int "the missing cost is unread" 1
    (int_field "cost_unread_samples" aggregate);
  check int "the missing cost is not an unreported cost" 0
    (int_field "cost_unreported_samples" aggregate);
  check (float 0.0001) "the integer cost is summed" 2.0
    (float_field "total_cost_usd" aggregate);
  check int "tokens of the row without a cost still add up" 12
    (int_field "total_tokens" aggregate)

(* A [usage] the writer never produces (here: tokens as strings) is unread,
   not summed as 0 and not reported as a runtime that gave no usage. *)
let test_unreadable_usage_is_unread () =
  let ts = Unix.gettimeofday () -. 1.0 in
  let aggregate =
    run_keeper_aggregate ~prefix:"keeper_tokens_unread" ~keeper_name:"odd-usage"
      [
        row_with ~ts ~latency_ms:100 ~cost:(Some (`Float 0.5))
          ~usage:
            (`Assoc
              [ "input_tokens", `String "7"
              ; "output_tokens", `String "3"
              ; "total_tokens", `String "10"
              ]);
      ]
  in
  check int "the row is a sample" 1 (int_field "sample_count" aggregate);
  check_partition aggregate;
  check int "its tokens are unread" 1 (int_field "tokens_unread_samples" aggregate);
  check int "its tokens are not unreported" 0
    (int_field "tokens_unreported_samples" aggregate);
  null_field "total_tokens" aggregate;
  check (float 0.0001) "its cost still adds up" 0.5
    (float_field "total_cost_usd" aggregate)

let () =
  run "dashboard_keeper_cost_aggregates"
    [
      ( "keeper cost aggregates",
        [
          test_case "accepts only current turn rows" `Quick
            test_only_current_turn_rows_count_as_cost_samples;
          test_case "unreported cost is counted, not summed as zero" `Quick
            test_unreported_cost_is_counted_not_summed_as_zero;
          test_case "all-unreported cost leaves the total unknown" `Quick
            test_all_unreported_cost_leaves_total_unknown;
          test_case "unreported tokens are counted, not summed as zero" `Quick
            test_unreported_tokens_are_counted_not_summed_as_zero;
          test_case "all-unreported tokens leave the totals unknown" `Quick
            test_all_unreported_tokens_leave_totals_unknown;
          test_case "zero-latency uncosted turn is a sample" `Quick
            test_zero_latency_uncosted_turn_is_a_sample;
          test_case "integer cost is reported, missing cost is unread" `Quick
            test_int_cost_is_reported_and_missing_cost_is_unread;
          test_case "unreadable usage is unread" `Quick
            test_unreadable_usage_is_unread;
        ] );
    ]
