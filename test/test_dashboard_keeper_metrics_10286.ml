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

let summary_int field summary =
  match Yojson.Safe.Util.(summary |> member field) with
  | `Int value -> value
  | other -> failf "expected int field %s, got %s" field (Yojson.Safe.to_string other)

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
  check bool "observed review" true
    (summary_bool "observed_pr_review_tool_calls" summary);
  check bool "observed mutation" true
    (summary_bool "observed_pr_mutation_tool_calls" summary);
  check bool "observed git" true
    (summary_bool "observed_git_tool_calls" summary);
  check bool "observed pr work" true
    (summary_bool "observed_pr_work_tool_calls" summary)

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
        ] );
    ]
