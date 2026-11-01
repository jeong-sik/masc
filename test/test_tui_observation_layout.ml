open Alcotest

module Decode = Masc.Tui_decode
module Layout = Masc_tui_observation_layout

let observed ?ratio ?(tokens = 100) ?maximum () =
  Decode.Context_observed
    { ratio;
      tokens;
      maximum;
      observed_at = "2026-08-21T12:00:00Z";
      turn_ref = "trace-current#4";
    }

let test_context_summaries () =
  (match Layout.context_summary (observed ~ratio:0.5 ~maximum:200 ()) with
   | Layout.Context_measured summary ->
       check (float 0.001) "ratio" 0.5 summary.ratio;
       check int "maximum" 200 summary.maximum
   | Layout.Context_partial _ | Layout.Context_unavailable _ ->
       fail "measured context lost");
  (match Layout.context_summary (observed ()) with
   | Layout.Context_partial summary ->
       check int "partial tokens" 100 summary.tokens;
       check string "partial turn ref" "trace-current#4" summary.turn_ref
   | Layout.Context_measured _ | Layout.Context_unavailable _ ->
       fail "partial context lost");
  let reasons =
    [ Decode.Context_measurement_missing
    ; Decode.Context_turn_record_undecodable
    ; Decode.Context_turn_record_read_failed
    ; Decode.Context_turn_record_without_usage
    ; Decode.Context_turn_record_trace_mismatch
    ; Decode.Context_conversation_cumulative_usage
        { raw_input_tokens = Some 2_041_883; context_window = None }
    ; Decode.Context_usage_scope_unavailable
        { raw_input_tokens = Some 190_412; context_window = Some 200_000 }
    ; Decode.Context_tokens_exceed_window
        { raw_input_tokens = 214_000; context_window = 200_000 }
    ]
  in
  List.iter
    (fun reason ->
      match Layout.context_summary (Decode.Context_unavailable reason) with
      | Layout.Context_unavailable _ -> ()
      | Layout.Context_measured _ | Layout.Context_partial _ ->
          fail "unavailable context became observed")
    reasons

let () =
  run "tui_observation_layout"
    [ ( "operator rows"
      , [ test_case "context states remain distinct" `Quick
            test_context_summaries
        ] )
    ]
