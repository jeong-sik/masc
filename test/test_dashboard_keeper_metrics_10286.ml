open Alcotest

module Detail = Dashboard_http_keeper_detail
module Keeper_metrics_record = Masc.Keeper_metrics_record

let metric ?(channel = "turn") tools =
  let kind =
    if String.equal channel "heartbeat"
    then Keeper_metrics_record.Heartbeat
    else Keeper_metrics_record.Turn
  in
  `Assoc
    (Keeper_metrics_record.fields kind
    @ [
      ("ts", `String "2026-07-30T00:00:00Z");
      ("ts_unix", `Float 1.0);
      ("channel", `String channel);
      ("trace_id", `String "trace-current");
      ("latency_ms", `Int 1);
      ("turn_mode", `String "tool_use");
      ("tools_used", `List (List.map (fun tool -> `String tool) tools));
      ("tool_call_count", `Int (List.length tools));
    ])

let sparse_tool_event () =
  `Assoc
    [
      ("ts_unix", `Float 3.0);
      ("channel", `String "tool_event");
      ("tool_call_count", `Int 0);
      ("tools_used", `List []);
    ]

let current_turn_metric () =
  `Assoc
    (Keeper_metrics_record.fields Keeper_metrics_record.Turn
    @ [
      ("ts", `String "2026-07-30T00:00:00Z");
      ("ts_unix", `Float 10.0);
      ("channel", `String "turn");
      ("trace_id", `String "trace-current");
      ("latency_ms", `Int 20);
      ("turn_mode", `String "text_response");
      (* Retired persisted fields must not regain authority. *)
      ("context_ratio", `Float 0.75);
      ("context_tokens", `Int 750);
      ("context_max", `Int 1000);
      ("message_count", `Int 12);
      ( "usage",
        `Assoc
          [
            ("input_tokens", `Int 120);
            ("output_tokens", `Int 80);
            ("total_tokens", `Int 200);
          ] );
      ( "ctx_composition",
        `Assoc
          [
            ("actual_input_tokens", `Int 120);
            ( "attribution",
              `Assoc
                [
                  ("status", `String "attributed");
                  ("runtime_profile", `String "runtime.current");
                  ("attributed_bytes", `Int 640);
                  ("segments", `Assoc []);
                ] );
          ] );
      ( "runtime",
        `Assoc
          [
            ("runtime_id", `String "runtime.current");
            ("outcome", `String "completed");
          ] );
      ("tool_call_count", `Int 0);
      ("tools_used", `List []);
    ])

let summary_int field summary =
  match Yojson.Safe.Util.(summary |> member field) with
  | `Int value -> value
  | other -> failf "expected int field %s, got %s" field (Yojson.Safe.to_string other)

let summary_missing field summary =
  Yojson.Safe.Util.(summary |> member field) = `Null

let retired_pr_work_summary_fields =
  [
    "pr_" ^ "review_read_tool_call_count";
    "pr_" ^ "review_mutation_tool_call_count";
    "pr_" ^ "review_tool_call_count";
    "pr_" ^ "work_git_tool_call_count";
    "pr_" ^ "work_tool_call_count";
    "pr_" ^ "work_signal_count";
    "observed_pr_" ^ "review_tool_calls";
    "observed_pr_" ^ "mutation_tool_calls";
    "observed_" ^ "git_tool_calls";
    "observed_pr_" ^ "work_tool_calls";
    "observed_pr_" ^ "review_work";
    "observed_pr_" ^ "mutation_work";
    "observed_" ^ "git_work";
    "observed_pr_" ^ "work";
  ]

let test_metrics_window_does_not_classify_execute_as_pr_work () =
  let _, summary =
    Detail.compute_metrics_window
      ~parsed_metrics:
        [
          metric
            [
              "tool_execute";
              "tool_execute";
              "tool_execute";
            ];
          metric ~channel:"heartbeat" [ "tool_execute" ];
        ]
      ~compact:false
      ~series_points:80
  in
  check int "tool calls remain generic" 3 (summary_int "tool_call_count" summary);
  List.iter
    (fun field -> check bool field true (summary_missing field summary))
    retired_pr_work_summary_fields

let test_metrics_series_preserves_current_turn_telemetry () =
  let items, summary =
    Detail.compute_metrics_window
      ~parsed_metrics:
        [
          current_turn_metric ();
          sparse_tool_event ();
        ]
      ~compact:false
      ~series_points:80
  in
  check int "series skips sparse rows" 1 (List.length items);
  check bool "sparse rows do not create PR work signals" true
    (summary_missing ("pr_" ^ "work_signal_count") summary);
  match items with
  | [ row ] ->
      let open Yojson.Safe.Util in
      check bool "retired context ratio ignored" true
        (row |> member "context_ratio" = `Null);
      check int "current usage retained" 120
        (row |> member "usage" |> member "input_tokens" |> to_int);
      check int "current composition retained" 640
        (row
        |> member "ctx_composition"
        |> member "attribution"
        |> member "attributed_bytes"
        |> to_int);
      check string "current runtime retained" "completed"
        (row |> member "runtime" |> member "outcome" |> to_string)
  | other ->
      failf "expected one metrics series row, got %d" (List.length other)

let test_metrics_window_omits_retired_labels () =
  let row =
    `Assoc
      (Keeper_metrics_record.fields Keeper_metrics_record.Turn
      @ [
        ("ts", `String "2026-07-30T00:00:00Z");
        ("ts_unix", `Float 20.0);
        ("channel", `String "turn");
        ("trace_id", `String "trace-a");
        ("latency_ms", `Int 20);
        ("turn_mode", `String "text_response");
        ("tool_call_count", `Int 0);
        ("tools_used", `List []);
        ("message_count", `Int 4);
      ])
  in
  let items, summary =
    Detail.compute_metrics_window
      ~parsed_metrics:[ row ]
      ~compact:false
      ~series_points:80
  in
  let has_field key = function
    | `Assoc fields -> List.mem_assoc key fields
    | _ -> false
  in
  check bool "summary generation_equipment omitted" true
    (summary_missing "generation_equipment" summary);
  match items with
  | [ item ] ->
      check bool "series model_used omitted" false
        (has_field "model_used" item);
      check bool "series generation omitted" false
        (has_field "generation" item)
  | other ->
      failf "expected one metrics series row, got %d" (List.length other)

(* #32971 Root B: the Turn row the producer writes today carries neither
   [generation] (removed by #29590) nor [handoff_performed] (removed by
   #31522). While the window required both, every Turn row fell through the
   tuple match and the series and the turn counters read zero for a Keeper
   with hundreds of turns. *)
let test_producer_shaped_turn_rows_enter_the_window () =
  let items, summary =
    Detail.compute_metrics_window
      ~parsed_metrics:[ metric [ "tool_execute" ]; metric [ "tool_read" ] ]
      ~compact:false
      ~series_points:80
  in
  check int "producer-shaped rows reach the series" 2 (List.length items);
  check int "turn_points counts them" 2 (summary_int "turn_points" summary);
  check int "sample_points counts them" 2 (summary_int "sample_points" summary);
  check int "tool calls accumulate" 2 (summary_int "tool_call_count" summary)
;;

let () =
  run "dashboard_keeper_metrics_10286"
    [
      ( "metrics_window",
        [
          test_case "does not classify Execute as PR work" `Quick
            test_metrics_window_does_not_classify_execute_as_pr_work;
          test_case "preserves current turn telemetry" `Quick
            test_metrics_series_preserves_current_turn_telemetry;
          test_case "producer-shaped turn rows enter the window" `Quick
            test_producer_shaped_turn_rows_enter_the_window;
          test_case "omits retired labels" `Quick
            test_metrics_window_omits_retired_labels;
        ] );
    ]
