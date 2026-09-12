open Alcotest

module Decode = Masc.Tui_decode
module Layout = Masc_tui_observation_layout

let test_log_labels_preserve_observed_zeroes () =
  check string "turn kind" "turn" (Layout.log_kind_label Decode.Log_turn);
  check string "scheduled channel" "sched"
    (Layout.log_channel_label Decode.Log_channel_scheduled_autonomous);
  check string "observed zero latency" "0ms" (Layout.latency_label (Some 0));
  check string "observed zero cost" "$0.000" (Layout.cost_label (Some 0.0));
  check string "missing latency" "--" (Layout.latency_label None);
  check string "missing cost" "--" (Layout.cost_label None)

let test_usage_labels_preserve_each_side () =
  check string "both observed" "10/12"
    (Layout.usage_label ~input:(Some 10) ~output:(Some 12));
  check string "input only" "10/--"
    (Layout.usage_label ~input:(Some 10) ~output:None);
  check string "output only" "--/12"
    (Layout.usage_label ~input:None ~output:(Some 12));
  check string "both missing" "--/--"
    (Layout.usage_label ~input:None ~output:None)

let log_entry ~kind ~channel ~message_count ~input_tokens ~output_tokens
    ~latency_ms ~cost_usd ~work_kind =
  Decode.
    { le_kind = kind;
      le_ts = "2026-08-21T12:00:00Z";
      le_channel = channel;
      le_message_count = message_count;
      le_input_tokens = input_tokens;
      le_output_tokens = output_tokens;
      le_latency_ms = latency_ms;
      le_cost_usd = cost_usd;
      le_work_kind = work_kind;
      le_tools_used = [];
    }

let test_log_rows_keep_stable_columns () =
  let turn =
    log_entry ~kind:Decode.Log_turn ~channel:Decode.Log_channel_turn
      ~message_count:(Some 7) ~input_tokens:(Some 10)
      ~output_tokens:(Some 12) ~latency_ms:(Some 0) ~cost_usd:(Some 0.0)
      ~work_kind:(Some "tool_use")
  in
  let heartbeat =
    log_entry ~kind:Decode.Log_heartbeat
      ~channel:Decode.Log_channel_heartbeat ~message_count:None
      ~input_tokens:None ~output_tokens:None ~latency_ms:None ~cost_usd:None
      ~work_kind:None
  in
  let turn_row = Layout.plain_log_row ~time:"12:00:00" turn in
  let heartbeat_row = Layout.plain_log_row ~time:"12:00:00" heartbeat in
  (* One cell narrower than it was: the two spaces the row kept between the
     cost and the work kind were hand-written into both format strings, and
     the shared contract spaces every column alike. The counts still read as a
     block -- they are the four that are right-aligned. *)
  check int "fits the 80-column box interior" 75 (String.length turn_row);
  check int "missing values keep row width" (String.length turn_row)
    (String.length heartbeat_row);
  check string "kind column" "turn" (String.sub turn_row 11 4);
  (* Blank where the channel would repeat the kind, and still eight cells wide:
     the column holds its place so the numbers after it keep theirs. *)
  check string "channel column is blank where it repeats the kind" "        "
    (String.sub turn_row 16 8);
  check string "message column" "    7" (String.sub turn_row 25 5);
  check string "usage column" "        10/12" (String.sub turn_row 31 13);
  check string "latency column" "      0ms" (String.sub turn_row 45 9);
  check string "cost column" "   $0.000" (String.sub turn_row 55 9);
  check string "a heartbeat's channel is blank for the same reason" "        "
    (String.sub heartbeat_row 16 8);
  (* The one channel that says something the kind does not is drawn, in the
     same eight cells. *)
  let scheduled =
    log_entry ~kind:Decode.Log_turn
      ~channel:Decode.Log_channel_scheduled_autonomous ~message_count:(Some 7)
      ~input_tokens:(Some 10) ~output_tokens:(Some 12) ~latency_ms:(Some 0)
      ~cost_usd:(Some 0.0) ~work_kind:(Some "tool_use")
  in
  let scheduled_row = Layout.plain_log_row ~time:"12:00:00" scheduled in
  check int "a drawn channel does not change the width"
    (String.length turn_row) (String.length scheduled_row);
  check string "and it is the channel that disagrees with its kind" "sched   "
    (String.sub scheduled_row 16 8);
  (* The names and the readings come from one description now. The widths used
     to live in this module and the names in the renderer, so this is the
     property that says they cannot drift apart again. *)
  let header = Layout.plain_log_header in
  check int "the header is as wide as the rows" (String.length turn_row)
    (String.length header);
  List.iter
    (fun (label, offset) ->
      check string
        (Printf.sprintf "%s stands over its column" label)
        label
        (String.sub header offset (String.length label)))
    [ "TIME", 2; "KIND", 11; "CHANNEL", 16; "WORK", 65 ];
  (* A right-aligned name ends where its readings end. *)
  List.iter
    (fun (label, offset, width) ->
      check string
        (Printf.sprintf "%s ends with its column" label)
        label
        (String.sub header (offset + width - String.length label)
           (String.length label)))
    [ "MSGS", 25, 5; "IN/OUT", 31, 13; "LAT", 45, 9; "COST", 55, 9 ]

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
    [ Decode.Context_measurement_missing, "context measurement missing"
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

let test_context_header_item_is_measured_and_atomic () =
  let measured = observed ~ratio:0.5 ~maximum:200 () in
  check (option string) "exact fit" (Some "Context 50% used")
    (Layout.context_header_item ~max_cells:16 measured);
  (* The key travels with the figure where there is room for it: this line was
     the only place the pane said how full the context is, and there was no
     way in from it. *)
  check (option string) "wide enough carries the way in"
    (Some "Context 50% \xc2\xb7 100/200 tok \xc2\xb7 ^X")
    (Layout.context_header_item ~max_cells:40 measured);
  check (option string) "exactly wide enough" (Some "Context 50% used \xc2\xb7 ^X")
    (Layout.context_header_item ~max_cells:21 measured);
  (* The figure is what the line is for. One cell short of the key it drops
     the key, not the number. *)
  check (option string) "one cell short of the key keeps the figure"
    (Some "Context 50% used")
    (Layout.context_header_item ~max_cells:20 measured);
  let large = observed ~ratio:0.089 ~maximum:1_048_576 ~tokens:93_213 () in
  check (option string) "large token counts are grouped"
    (Some "Context 9% \xc2\xb7 93,213/1,048,576 tok \xc2\xb7 ^X")
    (Layout.context_header_item ~max_cells:38 large);
  check (option string) "one cell short omits the whole item" None
    (Layout.context_header_item ~max_cells:15 measured);
  check (option string) "partial measurement is omitted" None
    (Layout.context_header_item ~max_cells:40 (observed ()));
  check (option string) "non-positive maximum is omitted" None
    (Layout.context_header_item ~max_cells:40
       (observed ~ratio:0.5 ~maximum:0 ()));
  check (option string) "unavailable measurement is omitted" None
    (Layout.context_header_item ~max_cells:40
       (Decode.Context_unavailable Decode.Context_measurement_missing))

let () =
  run "tui_observation_layout"
    [ ( "operator rows"
      , [ test_case "zero and missing log labels" `Quick
            test_log_labels_preserve_observed_zeroes
        ; test_case "usage sides remain distinct" `Quick
            test_usage_labels_preserve_each_side
        ; test_case "complete rows keep stable columns" `Quick
            test_log_rows_keep_stable_columns
        ; test_case "context states remain distinct" `Quick
            test_context_summaries
        ; test_case "visible context percentage owns rounding" `Quick
            test_visible_context_percentage_rounding
        ; test_case "context header item is measured and atomic" `Quick
            test_context_header_item_is_measured_and_atomic
        ] )
    ]
