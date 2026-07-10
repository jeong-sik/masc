(** Drift-guard for OAS stop-reason projections consumed by MASC. The metric
    label path must collapse [Unknown _] to ["unknown"]; the wire path must
    preserve provider raw values for round-trip/event payloads. *)

let label = Alcotest.(check string)
let to_label = Keeper_hooks_oas_types.stop_reason_to_label

let response stop_reason : Agent_sdk.Types.api_response =
  { id = "resp-stop-reason"
  ; model = "model-stop-reason"
  ; content = []
  ; usage = None
  ; stop_reason
  ; telemetry = None
  }

let test_all_variants () =
  label "EndTurn" "end_turn" (to_label Agent_sdk.Types.EndTurn);
  label "StopToolUse" "tool_use" (to_label Agent_sdk.Types.StopToolUse);
  label "MaxTokens" "max_tokens" (to_label Agent_sdk.Types.MaxTokens);
  label "StopSequence" "stop_sequence"
    (to_label Agent_sdk.Types.StopSequence);
  label "Refusal" "refusal" (to_label Agent_sdk.Types.Refusal);
  label "ContentFilter" "content_filter"
    (to_label Agent_sdk.Types.ContentFilter);
  label "RepetitionTruncation" "repetition_truncation"
    (to_label Agent_sdk.Types.RepetitionTruncation);
  label "PauseTurn" "pause_turn" (to_label Agent_sdk.Types.PauseTurn);
  label "Compaction" "compaction" (to_label Agent_sdk.Types.Compaction);
  label "ContextWindowExceeded" "model_context_window_exceeded"
    (to_label Agent_sdk.Types.ContextWindowExceeded);
  label "UnmatchedToolCalls" "unmatched_tool_calls"
    (to_label Agent_sdk.Types.UnmatchedToolCalls);
  label "Unknown" "unknown" (to_label (Agent_sdk.Types.Unknown "anything"))

let test_agent_completed_stop_reason_wire_uses_oas_string () =
  let fields =
    Masc.Keeper_event_bridge_error_json.agent_completed_result_fields
      (Ok (response (Agent_sdk.Types.Unknown "provider_raw_stop")))
  in
  match List.assoc_opt "stop_reason" fields with
  | Some (`String value) ->
      label "raw unknown wire value" "provider_raw_stop" value
  | Some other ->
      Alcotest.failf "stop_reason field was not a string: %s"
        (Yojson.Safe.to_string other)
  | None -> Alcotest.fail "missing stop_reason field"

let () =
  Alcotest.run "stop_reason_label"
    [ ( "stop_reason_to_label"
      , [ Alcotest.test_case "all nine variants" `Quick test_all_variants
        ; Alcotest.test_case "agent_completed uses OAS wire string" `Quick
            test_agent_completed_stop_reason_wire_uses_oas_string
        ] )
    ]
