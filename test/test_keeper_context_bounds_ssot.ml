(* #9953: pin the SSOT context-window bounds so a regression that
   re-introduces a local [1_000_000] literal (or changes the ceiling
   inconsistently with the provider registry) is caught at test time.

   [min_keeper_context_tokens] / [max_keeper_context_tokens] are the
   only constants allowed to name these values.  [keeper_turn_up_args]
   must thread both through [Keeper_config]; new code that builds
   context caps must do the same. *)

module KC = Masc_mcp.Keeper_config

let test_min_matches_64k () =
  Alcotest.(check int) "min keeper context tokens" 64_000 KC.min_keeper_context_tokens
;;

let test_max_matches_1m () =
  Alcotest.(check int) "max keeper context tokens" 1_000_000 KC.max_keeper_context_tokens
;;

let test_min_below_max () =
  Alcotest.(check bool)
    "min < max (otherwise the override band collapses)"
    true
    (KC.min_keeper_context_tokens < KC.max_keeper_context_tokens)
;;

let () =
  Alcotest.run
    "keeper_context_bounds_ssot"
    [ ( "bounds"
      , [ Alcotest.test_case "min is 64k" `Quick test_min_matches_64k
        ; Alcotest.test_case "max is 1M" `Quick test_max_matches_1m
        ; Alcotest.test_case "min < max" `Quick test_min_below_max
        ] )
    ]
;;
