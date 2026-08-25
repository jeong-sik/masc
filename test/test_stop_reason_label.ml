(** Drift-guard for AGENT_CORE stop-reason projections consumed by MASC. The metric
    label path must collapse [Unknown _] to ["unknown"]; the wire path must
    preserve provider raw values for round-trip/event payloads. *)

let label = Alcotest.(check string)
let to_label = Keeper_hooks_agent_core_types.stop_reason_to_label

let response stop_reason : Agent_core.Types.api_response =
  { id = "resp-stop-reason"
  ; model = "model-stop-reason"
  ; content = []
  ; usage = None
  ; stop_reason
  ; telemetry = None
  }

let test_all_variants () =
  label "EndTurn" "end_turn" (to_label Agent_core.Types.EndTurn);
  label "StopToolUse" "tool_use" (to_label Agent_core.Types.StopToolUse);
  label "MaxTokens" "max_tokens" (to_label Agent_core.Types.MaxTokens);
  label "StopSequence" "stop_sequence"
    (to_label Agent_core.Types.StopSequence);
  label "Refusal" "refusal" (to_label Agent_core.Types.Refusal);
  label "ContentFilter" "content_filter"
    (to_label Agent_core.Types.ContentFilter);
  label "RepetitionTruncation" "repetition_truncation"
    (to_label Agent_core.Types.RepetitionTruncation);
  label "PauseTurn" "pause_turn" (to_label Agent_core.Types.PauseTurn);
  label "Compaction" "compaction" (to_label Agent_core.Types.Compaction);
  label "ContextWindowExceeded" "model_context_window_exceeded"
    (to_label Agent_core.Types.ContextWindowExceeded);
  label "UnmatchedToolCalls" "unmatched_tool_calls"
    (to_label Agent_core.Types.UnmatchedToolCalls);
  label "Unknown" "unknown" (to_label (Agent_core.Types.Unknown "anything"))

let test_agent_completed_stop_reason_wire_uses_agent_core_string () =
  let fields =
    Masc.Keeper_event_bridge_error_json.agent_completed_response_fields
      (response (Agent_core.Types.Unknown "provider_raw_stop"))
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
        ; Alcotest.test_case "agent_completed uses AGENT_CORE wire string" `Quick
            test_agent_completed_stop_reason_wire_uses_agent_core_string
        ] )
    ]
