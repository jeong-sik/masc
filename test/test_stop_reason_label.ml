(** Drift-guard for [Keeper_hooks_oas_types.stop_reason_to_label] — pins
    the label for all nine [Agent_sdk.Types.stop_reason] variants. The
    function unifies what were two byte-for-output-identical matches in
    [keeper_hooks_oas] (finish-reason hook field) and
    [keeper_hooks_oas_response_metrics] (metric label); this test fails if
    a label drifts from the shared SSOT. *)

let label = Alcotest.(check string)
let to_label = Keeper_hooks_oas_types.stop_reason_to_label

let test_all_variants () =
  label "EndTurn" "end_turn" (to_label Agent_sdk.Types.EndTurn);
  label "StopToolUse" "tool_use" (to_label Agent_sdk.Types.StopToolUse);
  label "MaxTokens" "max_tokens" (to_label Agent_sdk.Types.MaxTokens);
  label "StopSequence" "stop_sequence"
    (to_label Agent_sdk.Types.StopSequence);
  label "Refusal" "refusal" (to_label Agent_sdk.Types.Refusal);
  label "PauseTurn" "pause_turn" (to_label Agent_sdk.Types.PauseTurn);
  label "Compaction" "compaction" (to_label Agent_sdk.Types.Compaction);
  label "ContextWindowExceeded" "model_context_window_exceeded"
    (to_label Agent_sdk.Types.ContextWindowExceeded);
  label "Unknown" "unknown" (to_label (Agent_sdk.Types.Unknown "anything"))

let () =
  Alcotest.run "stop_reason_label"
    [ ( "stop_reason_to_label"
      , [ Alcotest.test_case "all nine variants" `Quick test_all_variants ] )
    ]
