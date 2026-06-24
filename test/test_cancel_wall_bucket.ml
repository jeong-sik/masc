(** Drift-guard for [Cancel_wall_bucket.of_wall] — pins the five
    wall-clock bucket boundaries (60/300/600/1800s) and labels shared by
    [keeper_llm_bridge] and [masc_oas_bridge]. If a boundary or label
    moves, the two cancel-metric sources stop being unionable; this test
    fails before that drift can ship. *)

let label = Alcotest.(check string)

let test_boundaries () =
  label "0 -> fast" "fast" (Cancel_wall_bucket.of_wall 0.0);
  label "59.999 -> fast" "fast" (Cancel_wall_bucket.of_wall 59.999);
  label "60 -> short_tail" "short_tail" (Cancel_wall_bucket.of_wall 60.0);
  label "299.999 -> short_tail" "short_tail"
    (Cancel_wall_bucket.of_wall 299.999);
  label "300 -> mid_tail" "mid_tail" (Cancel_wall_bucket.of_wall 300.0);
  label "599.999 -> mid_tail" "mid_tail" (Cancel_wall_bucket.of_wall 599.999);
  label "600 -> long_mid" "long_mid" (Cancel_wall_bucket.of_wall 600.0);
  label "1799.999 -> long_mid" "long_mid"
    (Cancel_wall_bucket.of_wall 1799.999);
  label "1800 -> long_tail" "long_tail" (Cancel_wall_bucket.of_wall 1800.0);
  label "100000 -> long_tail" "long_tail"
    (Cancel_wall_bucket.of_wall 100000.0)

let () =
  Alcotest.run "cancel_wall_bucket"
    [ ( "of_wall boundaries"
      , [ Alcotest.test_case "five bucket thresholds" `Quick test_boundaries ]
      )
    ]
