open Alcotest

module Metrics = Dashboard_http_keeper_metrics
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
            ("attributed_bytes", `Int 640);
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

let test_contains_ci_preserves_literal_ascii_semantics () =
  check bool "ascii case-insensitive hit" true
    (Metrics.contains_ci "keeper Tool Surface" "tool");
  check bool "literal metachar needle" true
    (Metrics.contains_ci "keeper.a+b" ".a+");
  check bool "empty needle stays false" false
    (Metrics.contains_ci "keeper" "");
  check bool "longer needle false" false
    (Metrics.contains_ci "keeper" "keeper-agent")

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
        (row |> member "ctx_composition" |> member "attributed_bytes" |> to_int);
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
  check bool "summary handoff_count omitted" true
    (summary_missing "handoff_count" summary);
  check bool "summary generation_equipment omitted" true
    (summary_missing "generation_equipment" summary);
  match items with
  | [ item ] ->
      check bool "series model_used omitted" false
        (has_field "model_used" item);
      check bool "series generation omitted" false
        (has_field "generation" item);
      check bool "series handoff_performed omitted" false
        (has_field "handoff_performed" item);
      check bool "series handoff omitted" false (has_field "handoff" item)
  | other ->
      failf "expected one metrics series row, got %d" (List.length other)

let with_temp_history content f =
  let path = Filename.temp_file "khist" ".jsonl" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ()) (fun () -> f path)

(* Regression: keeper history rows persist message text as typed
   [content_blocks], not a flat [content] string. Reading flat [content]
   decoded "" for every row, so the dashboard keeper conversation feed and the
   k2k mention graph were entirely empty. *)
let test_history_summary_decodes_content_blocks () =
  let rows =
    String.concat
      "\n"
      [ {|{"role":"assistant","content_blocks":[{"type":"text","text":"hello from albini"}],"ts_unix":1.0}|}
      ; {|{"role":"user","content_blocks":[{"type":"text","text":"ping @fixture-keeper please"}],"ts_unix":2.0}|}
      ]
    ^ "\n"
  in
  with_temp_history rows (fun path ->
      let conversation, _k2k_recent, _k2k_mentions, raw_count, _frag, _filtered =
        Metrics.keeper_history_summary_json
          ~all_keeper_names:[ "albini"; "fixture-keeper" ]
          ~keeper_name:"albini"
          ~history_path:path
          ~filter_fragments:false
      in
      check int "raw_count counts content_blocks rows" 2 raw_count;
      match conversation with
      | `List (first :: _ as items) ->
          check int "conversation length" 2 (List.length items);
          let content =
            first
            |> Yojson.Safe.Util.member "content"
            |> Yojson.Safe.Util.to_string
          in
          check
            string
            "first row content extracted from blocks"
            "hello from albini"
            content
      | _ -> fail "expected non-empty conversation list")

let test_history_summary_routes_by_source_not_content () =
  let row ~role ~source ~content ~ts_unix =
    `Assoc
      [
        ("role", `String role);
        ("source", `String source);
        ( "content_blocks",
          `List
            [
              `Assoc
                [ ("type", `String "text"); ("text", `String content) ];
            ] );
        ("ts_unix", `Float ts_unix);
      ]
    |> Yojson.Safe.to_string
  in
  let user_content =
    "## Current World State\n### Namespace State\nthis is user-authored text"
  in
  let rows =
    String.concat
      "\n"
      [
        row ~role:"user" ~source:"direct_user" ~content:user_content
          ~ts_unix:1.0;
        row ~role:"user" ~source:"world_state_prompt"
          ~content:"ordinary internal prompt text" ~ts_unix:2.0;
      ]
    ^ "\n"
  in
  with_temp_history rows (fun path ->
      let conversation, _k2k_recent, _k2k_mentions, raw_count, _frag, _filtered =
        Metrics.keeper_history_summary_json
          ~all_keeper_names:[ "albini" ]
          ~keeper_name:"albini"
          ~history_path:path
          ~filter_fragments:false
      in
      check int "only the explicit internal source is excluded" 1 raw_count;
      match conversation with
      | `List [ item ] ->
          check string "message prose does not control routing" user_content
            Yojson.Safe.Util.(item |> member "content" |> to_string)
      | other ->
          failf "expected one user-authored history item, got %s"
            (Yojson.Safe.to_string other))

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
      ( "contains_ci",
        [
          test_case "preserves literal ascii semantics" `Quick
            test_contains_ci_preserves_literal_ascii_semantics;
        ] );
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
      ( "history_summary",
        [
          test_case "decodes content_blocks rows" `Quick
            test_history_summary_decodes_content_blocks;
          test_case "routes by source, not content" `Quick
            test_history_summary_routes_by_source_not_content;
        ] );
    ]
