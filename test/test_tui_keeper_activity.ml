open Alcotest

module Activity = Masc_tui_keeper_activity
module Decode = Masc.Tui_decode

let entry ?(kind = Decode.Log_turn) ?(input = None) ?(output = None) ?(cost = None)
    ?(tools = []) ts =
  {
    Decode.le_kind = kind;
    le_ts = ts;
    le_channel = Decode.Log_channel_turn;
    le_message_count = None;
    le_input_tokens = input;
    le_output_tokens = output;
    le_latency_ms = None;
    le_cost_usd = cost;
    le_work_kind = None;
    le_tools_used = tools;
  }

(* 2026-08-23T12:00:00Z *)
let fixed_now = 1787486400.

let test_cutoff_is_an_iso_instant_the_rows_compare_against () =
  check string "24h before the fixed instant" "2026-08-22T12:00:00Z"
    (Activity.cutoff_of ~now:fixed_now ~hours:24);
  check string "1h before the fixed instant" "2026-08-23T11:00:00Z"
    (Activity.cutoff_of ~now:fixed_now ~hours:1)

let test_rows_before_the_cutoff_are_excluded () =
  let since = "2026-08-22T12:00:00Z" in
  let window =
    Activity.summarize ~since
      [ entry ~input:(Some 10) "2026-08-21T23:59:59Z"
      ; entry ~input:(Some 100) "2026-08-22T12:00:00Z"
      ; entry ~input:(Some 1000) "2026-08-23T09:00:00Z"
      ]
  in
  check int "counts only rows at or after the cutoff" 2 window.Activity.aw_turns;
  check int "sums only those rows" 1100 window.Activity.aw_input_tokens

let test_turns_and_heartbeats_are_counted_apart () =
  let since = "2026-08-22T12:00:00Z" in
  let window =
    Activity.summarize ~since
      [ entry ~kind:Decode.Log_heartbeat "2026-08-23T01:00:00Z"
      ; entry ~kind:Decode.Log_heartbeat "2026-08-23T02:00:00Z"
      ; entry "2026-08-23T03:00:00Z"
      ]
  in
  check int "turns" 1 window.Activity.aw_turns;
  check int "heartbeats" 2 window.Activity.aw_heartbeats

let test_tool_calls_rank_by_count_then_name () =
  let since = "2026-08-22T12:00:00Z" in
  let window =
    Activity.summarize ~since
      [ entry ~tools:[ "b_tool"; "a_tool"; "b_tool" ] "2026-08-23T01:00:00Z"
      ; entry ~tools:[ "a_tool"; "c_tool"; "d_tool" ] "2026-08-23T02:00:00Z"
      ]
  in
  check int "every call counts, repeats included" 6 window.Activity.aw_tool_calls;
  let ranked =
    List.map (fun t -> t.Activity.tu_name, t.Activity.tu_calls) window.Activity.aw_top_tools
  in
  check (list (pair string int)) "top three, ties broken by name"
    [ "a_tool", 2; "b_tool", 2; "c_tool", 1 ]
    ranked

let test_a_window_that_does_not_reach_the_cutoff_says_so () =
  let since = "2026-08-22T12:00:00Z" in
  let short =
    Activity.summarize ~since
      [ entry "2026-08-23T10:00:00Z"; entry "2026-08-23T11:00:00Z" ]
  in
  check bool "no row predates the cutoff, so the span is not covered" false
    short.Activity.aw_covered;
  check (option string) "reports the oldest row it did reach"
    (Some "2026-08-23T10:00:00Z") short.Activity.aw_oldest_ts;
  let full =
    Activity.summarize ~since
      [ entry "2026-08-22T06:00:00Z"; entry "2026-08-23T11:00:00Z" ]
  in
  check bool "a row before the cutoff proves the span is covered" true
    full.Activity.aw_covered

let test_absent_usage_does_not_invent_a_zero_turn () =
  let since = "2026-08-22T12:00:00Z" in
  let window =
    Activity.summarize ~since
      [ entry "2026-08-23T01:00:00Z"
      ; entry ~input:(Some 5) ~output:(Some 7) ~cost:(Some 0.25) "2026-08-23T02:00:00Z"
      ]
  in
  check int "input" 5 window.Activity.aw_input_tokens;
  check int "output" 7 window.Activity.aw_output_tokens;
  check (float 0.0001) "cost" 0.25 window.Activity.aw_cost_usd;
  check int "the row without usage is still a turn" 2 window.Activity.aw_turns

let test_no_rows_is_not_a_covered_window () =
  let window = Activity.summarize ~since:"2026-08-22T12:00:00Z" [] in
  check bool "an empty read covers nothing" false window.Activity.aw_covered;
  check int "no turns" 0 window.Activity.aw_turns;
  check (option string) "no oldest row" None window.Activity.aw_oldest_ts

let () =
  run "keeper_activity"
    [ ( "window",
        [ test_case "cutoff is an ISO instant rows compare against" `Quick
            test_cutoff_is_an_iso_instant_the_rows_compare_against
        ; test_case "rows before the cutoff are excluded" `Quick
            test_rows_before_the_cutoff_are_excluded
        ; test_case "turns and heartbeats are counted apart" `Quick
            test_turns_and_heartbeats_are_counted_apart
        ; test_case "tool calls rank by count then name" `Quick
            test_tool_calls_rank_by_count_then_name
        ; test_case "a window that does not reach the cutoff says so" `Quick
            test_a_window_that_does_not_reach_the_cutoff_says_so
        ; test_case "absent usage does not invent a zero turn" `Quick
            test_absent_usage_does_not_invent_a_zero_turn
        ; test_case "no rows is not a covered window" `Quick
            test_no_rows_is_not_a_covered_window
        ] )
    ]
