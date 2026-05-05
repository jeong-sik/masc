open Alcotest

module Metrics = Masc_mcp.Dashboard_http_keeper_metrics
module Detail = Masc_mcp.Dashboard_http_keeper_detail

let metric ?(channel = "turn") tools =
  `Assoc
    [
      ("ts_unix", `Float 1.0);
      ("channel", `String channel);
      ("tools_used", `List (List.map (fun tool -> `String tool) tools));
      ("tool_call_count", `Int (List.length tools));
    ]

let pr_review_action ?(success = true) action =
  `Assoc
    [
      ("ts_unix", `Float 2.0);
      ("channel", `String "tool_event");
      ("metric_event", `String "keeper_pr_review_action");
      ("pr_review_action", `String action);
      ("pr_review_action_success", `Bool success);
      ("tool_call_count", `Int 0);
      ("tools_used", `List []);
    ]

let pr_work_action ?(success = true) action =
  `Assoc
    [
      ("ts_unix", `Float 3.0);
      ("channel", `String "tool_event");
      ("metric_event", `String "keeper_pr_work_action");
      ("pr_work_action", `String action);
      ("pr_work_action_success", `Bool success);
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

let summary_bool field summary =
  match Yojson.Safe.Util.(summary |> member field) with
  | `Bool value -> value
  | other -> failf "expected bool field %s, got %s" field (Yojson.Safe.to_string other)

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

let test_metrics_window_exposes_observed_pr_work () =
  let _, summary, _, _ =
    Detail.compute_metrics_window
      ~parsed_metrics:
        [
          metric
            [
              "keeper_pr_review_read";
              "keeper_pr_review_comment";
              "keeper_pr_review_reply";
              "keeper_preflight_check";
              "masc_worktree_create";
              "masc_code_git";
            ];
          pr_review_action "COMMENT";
          pr_review_action "APPROVE";
          pr_review_action "REQUEST_CHANGES";
          pr_review_action "REPLY";
          pr_review_action ~success:false "APPROVE";
          pr_work_action "GIT_ADD";
          pr_work_action "GIT_COMMIT";
          pr_work_action "GIT_PUSH";
          pr_work_action "PR_CREATE";
          pr_work_action ~success:false "GIT_PUSH";
          metric ~channel:"heartbeat" [ "keeper_pr_review_comment"; "masc_code_git" ];
        ]
      ~generation:0
      ~compact:false
      ~series_points:80
      ~metrics_window_max_bytes:200_000
      ~primary_model_norm:""
      ~primary_model:""
  in
  check int "review read tool calls" 1
    (summary_int "pr_review_read_tool_call_count" summary);
  check int "review mutation tool calls" 2
    (summary_int "pr_review_mutation_tool_call_count" summary);
  check int "review tool calls" 3
    (summary_int "pr_review_tool_call_count" summary);
  check int "git/preflight tool calls" 3
    (summary_int "pr_work_git_tool_call_count" summary);
  check int "pr work tool call count" 6
    (summary_int "pr_work_tool_call_count" summary);
  check int "review action attempts" 5
    (summary_int "pr_review_action_attempt_count" summary);
  check int "review action successes" 4
    (summary_int "pr_review_action_success_count" summary);
  check int "comment actions" 1
    (summary_int "pr_review_comment_action_count" summary);
  check int "approve actions" 1
    (summary_int "pr_review_approve_action_count" summary);
  check int "request changes actions" 1
    (summary_int "pr_review_request_changes_action_count" summary);
  check int "reply actions" 1
    (summary_int "pr_review_reply_action_count" summary);
  check int "pr work action attempts" 5
    (summary_int "pr_work_action_attempt_count" summary);
  check int "pr work action successes" 4
    (summary_int "pr_work_action_success_count" summary);
  check int "git add actions" 1
    (summary_int "pr_git_add_action_count" summary);
  check int "git commit actions" 1
    (summary_int "pr_git_commit_action_count" summary);
  check int "git push actions" 1
    (summary_int "pr_git_push_action_count" summary);
  check int "pr create actions" 1
    (summary_int "pr_create_action_count" summary);
  check int "pr work signal count" 14
    (summary_int "pr_work_signal_count" summary);
  check bool "observed review" true
    (summary_bool "observed_pr_review_tool_calls" summary);
  check bool "observed mutation" true
    (summary_bool "observed_pr_mutation_tool_calls" summary);
  check bool "observed git" true
    (summary_bool "observed_git_tool_calls" summary);
  check bool "observed pr work tool calls" true
    (summary_bool "observed_pr_work_tool_calls" summary);
  check bool "observed review work" true
    (summary_bool "observed_pr_review_work" summary);
  check bool "observed mutation work" true
    (summary_bool "observed_pr_mutation_work" summary);
  check bool "observed approve" true
    (summary_bool "observed_pr_approve_work" summary);
  check bool "observed request changes" true
    (summary_bool "observed_pr_request_changes_work" summary);
  check bool "observed reply" true
    (summary_bool "observed_pr_reply_work" summary);
  check bool "observed pr create" true
    (summary_bool "observed_pr_create_work" summary);
  check bool "observed pr push" true
    (summary_bool "observed_pr_push_work" summary);
  check bool "observed pr commit" true
    (summary_bool "observed_pr_commit_work" summary);
  check bool "observed git" true (summary_bool "observed_git_work" summary);
  check bool "observed pr work" true
    (summary_bool "observed_pr_work" summary)

let test_metrics_window_action_rows_drive_observed_pr_work () =
  let _, summary, _, _ =
    Detail.compute_metrics_window
      ~parsed_metrics:[ pr_review_action "COMMENT"; pr_work_action "GIT_PUSH" ]
      ~generation:0
      ~compact:false
      ~series_points:80
      ~metrics_window_max_bytes:200_000
      ~primary_model_norm:""
      ~primary_model:""
  in
  check int "no review tools" 0
    (summary_int "pr_review_tool_call_count" summary);
  check int "no git tools" 0
    (summary_int "pr_work_git_tool_call_count" summary);
  check int "review action successes" 1
    (summary_int "pr_review_action_success_count" summary);
  check int "work action successes" 1
    (summary_int "pr_work_action_success_count" summary);
  check int "pr work signal count" 2
    (summary_int "pr_work_signal_count" summary);
  check bool "observed review via action" true
    (summary_bool "observed_pr_review_work" summary);
  check bool "observed mutation via action" true
    (summary_bool "observed_pr_mutation_work" summary);
  check bool "observed git via action" true
    (summary_bool "observed_git_work" summary);
  check bool "observed pr work via action" true
    (summary_bool "observed_pr_work" summary)

let test_24h_context_ignores_sparse_tool_events () =
  let rows, summary =
    Metrics.keeper_metrics_24h_json
      ~metrics_lines:
        [
          json_line (context_snapshot ~context_ratio:0.75 ());
          json_line (pr_review_action "COMMENT");
          json_line (pr_work_action "GIT_PUSH");
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
  check bool "review action row is sparse" false
    (Metrics.metrics_row_has_context_snapshot (pr_review_action "COMMENT"));
  check bool "work action row is sparse" false
    (Metrics.metrics_row_has_context_snapshot (pr_work_action "GIT_PUSH"))

let test_metrics_series_ignores_sparse_tool_events () =
  let items, summary, _, _ =
    Detail.compute_metrics_window
      ~parsed_metrics:
        [
          context_snapshot ~context_ratio:0.55 ();
          pr_review_action "COMMENT";
          pr_work_action "GIT_PUSH";
        ]
      ~generation:0
      ~compact:false
      ~series_points:80
      ~metrics_window_max_bytes:200_000
      ~primary_model_norm:""
      ~primary_model:""
  in
  check int "series skips sparse rows" 1 (List.length items);
  check int "actions still count" 2
    (summary_int "pr_work_signal_count" summary);
  match items with
  | [ row ] ->
      check (float 0.0001) "context sample preserved" 0.55
        (summary_float "context_ratio" row)
  | other ->
      failf "expected one metrics series row, got %d" (List.length other)

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
          test_case "exposes observed PR work signals" `Quick
            test_metrics_window_exposes_observed_pr_work;
          test_case "action rows drive observed PR work signals" `Quick
            test_metrics_window_action_rows_drive_observed_pr_work;
          test_case "24h context ignores sparse tool events" `Quick
            test_24h_context_ignores_sparse_tool_events;
          test_case "classifies sparse tool events" `Quick
            test_context_snapshot_classifier_rejects_sparse_tool_events;
          test_case "series ignores sparse tool events" `Quick
            test_metrics_series_ignores_sparse_tool_events;
        ] );
    ]
