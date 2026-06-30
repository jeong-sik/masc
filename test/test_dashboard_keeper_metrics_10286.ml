open Alcotest

module Metrics = Dashboard_http_keeper_metrics
module Detail = Dashboard_http_keeper_detail

let metric ?(channel = "turn") tools =
  `Assoc
    [
      ("ts_unix", `Float 1.0);
      ("channel", `String channel);
      ("tools_used", `List (List.map (fun tool -> `String tool) tools));
      ("tool_call_count", `Int (List.length tools));
    ]

let sparse_tool_event () =
  `Assoc
    [
      ("ts_unix", `Float 3.0);
      ("channel", `String "tool_event");
      ("tool_call_count", `Int 0);
      ("tools_used", `List []);
    ]

let context_snapshot ?(ts_unix = 10.0) ?(context_ratio = 0.75) () =
  `Assoc
    [
      ("ts_unix", `Float ts_unix);
      ("channel", `String "turn");
      ("context_ratio", `Float context_ratio);
      ("context_tokens", `Int 750);
      ("context_max", `Int 1000);
      ("message_count", `Int 12);
      ("tool_call_count", `Int 0);
      ("tools_used", `List []);
    ]

let json_line json = Yojson.Safe.to_string json

let summary_int field summary =
  match Yojson.Safe.Util.(summary |> member field) with
  | `Int value -> value
  | other -> failf "expected int field %s, got %s" field (Yojson.Safe.to_string other)

let summary_float field summary =
  match Yojson.Safe.Util.(summary |> member field) with
  | `Float value -> value
  | `Int value -> float_of_int value
  | other -> failf "expected float field %s, got %s" field (Yojson.Safe.to_string other)

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

let test_similarity_normalization_semantics () =
  check string "normalizes punctuation and ascii case"
    "hello world 가 힣 123"
    (Metrics.normalize_similarity_text "Hello,\tWORLD!! 가-힣 123");
  check (float 0.0001) "jaccard after normalization" 1.0
    (Metrics.jaccard_similarity_text "KEEPER, tool-use" "keeper tool use")

let test_proactive_preview_similarity_stats_semantics () =
  let sample_count, pair_count, avg, max_sim, warn =
    Metrics.proactive_preview_similarity_stats
      ~window:3
      ~warn_threshold:0.90
      [ "alpha beta"; "ALPHA, beta!!"; "gamma" ]
  in
  check int "sample count" 3 sample_count;
  check int "pair count" 2 pair_count;
  check (float 0.0001) "avg" 0.5 avg;
  check (float 0.0001) "max" 1.0 max_sim;
  check bool "warn" true warn

let test_metrics_window_does_not_classify_execute_as_pr_work () =
  let _, summary, _, _ =
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
      ~generation:0
      ~compact:false
      ~series_points:80
      ~metrics_window_max_bytes:200_000
      ~primary_model_norm:""
      ~primary_model:""
  in
  check int "tool calls remain generic" 3 (summary_int "tool_call_count" summary);
  List.iter
    (fun field -> check bool field true (summary_missing field summary))
    retired_pr_work_summary_fields

let test_24h_context_ignores_sparse_tool_events () =
  let rows, summary =
    Metrics.keeper_metrics_24h_json
      ~metrics_lines:
        [
          json_line (context_snapshot ~context_ratio:0.75 ());
          json_line (sparse_tool_event ());
        ]
      ~now_ts:100.0
  in
  check int "sample points skip sparse rows" 1
    (summary_int "sample_points" summary);
  match rows with
  | `List [ row ] ->
      check int "bucket sample points" 1
        (summary_int "sample_points" row);
      check (float 0.0001) "context avg ignores sparse rows" 0.75
        (summary_float "context_ratio_avg" row)
  | other ->
      failf "expected one 24h bucket, got %s" (Yojson.Safe.to_string other)

let test_context_snapshot_classifier_rejects_sparse_tool_events () =
  check bool "context row qualifies" true
    (Metrics.metrics_row_has_context_snapshot (context_snapshot ()));
  check bool "tool event row is sparse" false
    (Metrics.metrics_row_has_context_snapshot (sparse_tool_event ()))

let test_metrics_series_ignores_sparse_tool_events () =
  let items, summary, _, _ =
    Detail.compute_metrics_window
      ~parsed_metrics:
        [
          context_snapshot ~context_ratio:0.55 ();
          sparse_tool_event ();
        ]
      ~generation:0
      ~compact:false
      ~series_points:80
      ~metrics_window_max_bytes:200_000
      ~primary_model_norm:""
      ~primary_model:""
  in
  check int "series skips sparse rows" 1 (List.length items);
  check bool "sparse rows do not create PR work signals" true
    (summary_missing ("pr_" ^ "work_signal_count") summary);
  match items with
  | [ row ] ->
      check (float 0.0001) "context sample preserved" 0.55
        (summary_float "context_ratio" row)
  | other ->
      failf "expected one metrics series row, got %d" (List.length other)

let test_metrics_window_redacts_model_and_handoff_labels () =
  let row =
    `Assoc
      [
        ("ts_unix", `Float 20.0);
        ("channel", `String "turn");
        ("context_ratio", `Float 0.42);
        ("context_tokens", `Int 420);
        ("context_max", `Int 1000);
        ("message_count", `Int 4);
        ("model_used", `String "openai:gpt-5.4");
        ( "handoff",
          `Assoc
            [
              ("performed", `Bool true);
              ("to_model", `String "anthropic:claude-sonnet");
              ("prev_trace_id", `String "trace-a");
              ("new_trace_id", `String "trace-b");
              ("new_generation", `Int 2);
            ] );
      ]
  in
  let items, summary, last_handoff, _ =
    Detail.compute_metrics_window
      ~parsed_metrics:[ row ]
      ~generation:0
      ~compact:false
      ~series_points:80
      ~metrics_window_max_bytes:200_000
      ~primary_model_norm:"gpt-5.4"
      ~primary_model:"openai:gpt-5.4"
  in
  let open Yojson.Safe.Util in
  check string "primary model preserved" "openai:gpt-5.4"
    (summary |> member "primary_model" |> to_string);
  (match summary |> member "top_models" |> to_list with
  | [ top ] ->
      check string "model bucket is runtime" "runtime"
        (top |> member "model" |> to_string);
      check int "model bucket count" 1 (top |> member "count" |> to_int)
  | other ->
      failf "expected one runtime model bucket, got %d" (List.length other));
  (match items with
  | [ item ] ->
      check bool "series model_used redacted" true
        (item |> member "model_used" = `Null);
      check bool "series handoff_to_model redacted" true
        (item |> member "handoff_to_model" = `Null);
      check bool "nested handoff to_model redacted" true
        (item |> member "handoff" |> member "to_model" = `Null)
  | other ->
      failf "expected one metrics series row, got %d" (List.length other));
  (match last_handoff with
  | Some handoff ->
      check bool "last handoff to_model redacted" true
        (handoff |> member "to_model" = `Null)
  | None -> fail "expected last handoff summary")

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
      ; {|{"role":"user","content_blocks":[{"type":"text","text":"ping @taskmaster please"}],"ts_unix":2.0}|}
      ]
    ^ "\n"
  in
  with_temp_history rows (fun path ->
      let conversation, _k2k_recent, _k2k_mentions, raw_count, _frag, _filtered =
        Metrics.keeper_history_summary_json
          ~all_keeper_names:[ "albini"; "taskmaster" ]
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

let () =
  run "dashboard_keeper_metrics_10286"
    [
      ( "contains_ci",
        [
          test_case "preserves literal ascii semantics" `Quick
            test_contains_ci_preserves_literal_ascii_semantics;
        ] );
      ( "similarity",
        [
          test_case "normalization semantics" `Quick
            test_similarity_normalization_semantics;
          test_case "preview stats semantics" `Quick
            test_proactive_preview_similarity_stats_semantics;
        ] );
      ( "metrics_window",
        [
          test_case "does not classify Execute as PR work" `Quick
            test_metrics_window_does_not_classify_execute_as_pr_work;
          test_case "24h context ignores sparse tool events" `Quick
            test_24h_context_ignores_sparse_tool_events;
          test_case "classifies sparse tool events" `Quick
            test_context_snapshot_classifier_rejects_sparse_tool_events;
          test_case "series ignores sparse tool events" `Quick
            test_metrics_series_ignores_sparse_tool_events;
          test_case "redacts model and handoff labels" `Quick
            test_metrics_window_redacts_model_and_handoff_labels;
        ] );
      ( "history_summary",
        [
          test_case "decodes content_blocks rows" `Quick
            test_history_summary_decodes_content_blocks;
        ] );
    ]
