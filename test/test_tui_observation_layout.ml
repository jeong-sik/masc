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
      (* Drawn under a row labelled "Context:", so the reason does not open
         with that word again -- its four siblings never did. *)
    [ Decode.Context_measurement_missing, "measurement missing"
    ; Decode.Context_turn_record_undecodable, "turn record undecodable"
    ; Decode.Context_turn_record_read_failed, "turn record read failed"
    ; ( Decode.Context_turn_record_without_usage
      , "turn record has no provider usage" )
    ; ( Decode.Context_turn_record_trace_mismatch
      , "turn record belongs to a prior trace" )
      (* The three that carry a number. The pane draws them in the same row
         as the occupancy reading, and the two differ by an order of
         magnitude -- an operator read 190k and 2m out of one row and could
         not tell which was which (#33791). So what each of these has to do
         is say what its number counts; a bare count in that row is the
         defect. *)
    ; ( Decode.Context_conversation_cumulative_usage
          { raw_input_tokens = Some 2_041_883; context_window = None }
      , "cumulative usage 2041883 tokens (window unknown); occupancy not \
         observed" )
    ; ( Decode.Context_usage_scope_unavailable
          { raw_input_tokens = Some 190_412; context_window = Some 200_000 }
      , "usage scope unavailable (input 190412, window 200000)" )
    ; ( Decode.Context_tokens_exceed_window
          { raw_input_tokens = 214_000; context_window = 200_000 }
      , "per-request usage exceeds window: 214000 / 200000 tokens" )
    ]
  in
  List.iter
    (fun (reason, expected) ->
      match Layout.context_summary (Decode.Context_unavailable reason) with
      | Layout.Context_unavailable label ->
          check string "exact unavailable label" expected label
      | Layout.Context_measured _ | Layout.Context_partial _ ->
          fail "unavailable context became observed")
    reasons

let test_visible_context_percentage_rounding () =
  let check_projection label ratio percentage pressure =
    check int (label ^ " visible percentage") percentage
      (Layout.percentage_tenths ratio);
    check bool (label ^ " pressure") true
      (Layout.context_pressure ratio = pressure)
  in
  check_projection "49.99% rounds to warning" 0.4999 500 Layout.Pressure;
  check_projection "49.94% stays quiet" 0.4994 499 Layout.Quiet;
  check_projection "79.99% rounds to danger" 0.7999 800 Layout.Danger;
  check_projection "79.94% stays warning" 0.7994 799 Layout.Pressure

let () =
  run "tui_observation_layout"
    [ ( "operator rows"
      , [ test_case "context states remain distinct" `Quick
            test_context_summaries
        ; test_case "visible context percentage owns rounding" `Quick
            test_visible_context_percentage_rounding
        ;] )
    ]
