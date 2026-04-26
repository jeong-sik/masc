open Alcotest
module Metrics = Masc_mcp.Dashboard_http_keeper_metrics

let test_contains_ci_preserves_literal_ascii_semantics () =
  check
    bool
    "ascii case-insensitive hit"
    true
    (Metrics.contains_ci "keeper Tool Surface" "tool");
  check bool "literal metachar needle" true (Metrics.contains_ci "keeper.a+b" ".a+");
  check bool "empty needle stays false" false (Metrics.contains_ci "keeper" "");
  check bool "longer needle false" false (Metrics.contains_ci "keeper" "keeper-agent")
;;

let test_similarity_normalization_semantics () =
  check
    string
    "normalizes punctuation and ascii case"
    "hello world 가 힣 123"
    (Metrics.normalize_similarity_text "Hello,\tWORLD!! 가-힣 123");
  check
    (float 0.0001)
    "jaccard after normalization"
    1.0
    (Metrics.jaccard_similarity_text "KEEPER, tool-use" "keeper tool use")
;;

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
;;

let () =
  run
    "dashboard_keeper_metrics_10286"
    [ ( "contains_ci"
      , [ test_case
            "preserves literal ascii semantics"
            `Quick
            test_contains_ci_preserves_literal_ascii_semantics
        ] )
    ; ( "similarity"
      , [ test_case
            "normalization semantics"
            `Quick
            test_similarity_normalization_semantics
        ; test_case
            "preview stats semantics"
            `Quick
            test_proactive_preview_similarity_stats_semantics
        ] )
    ]
;;
