(* test/test_keeper_tool_selection_passive_streak.ml

   #14552 Phase 4: passive-streak metric for tool selection validation.
   Locks down the metric names and label contracts so Grafana rules
   cannot silently break on rename.

   The actual gauge/counter increment paths run inside the tool
   selection fiber in keeper_run_tools.ml — this test pins the
   contract surface only. *)

module KK = Masc_mcp.Keeper_metrics

let test_metric_names_stable () =
  Alcotest.(check string)
    "tool selection passive streak gauge canonical name"
    "masc_keeper_tool_selection_passive_streak"
    KK.metric_keeper_tool_selection_passive_streak;
  Alcotest.(check string)
    "tool selection passive streak exceeded counter canonical name"
    "masc_keeper_tool_selection_passive_streak_exceeded_total"
    KK.metric_keeper_tool_selection_passive_streak_exceeded
;;

let () =
  Alcotest.run
    "keeper_tool_selection_passive_streak"
    [ ( "contract"
      , [ Alcotest.test_case "metric names stable" `Quick
            test_metric_names_stable
        ] )
    ]
;;
