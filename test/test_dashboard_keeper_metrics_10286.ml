open Alcotest

module Detail = Dashboard_http_keeper_detail
module Keeper_metrics_record = Masc.Keeper_metrics_record

let metric tools =
  `Assoc
    (Keeper_metrics_record.fields Keeper_metrics_record.Turn
    @ [
      ("ts", `String "2026-07-30T00:00:00Z");
      ("ts_unix", `Float 1.0);
      ("channel", `String "turn");
      ("trace_id", `String "trace-current");
      ("latency_ms", `Int 1);
      ("turn_mode", `String "tool_use");
      ("tools_used", `List (List.map (fun tool -> `String tool) tools));
      ("tool_call_count", `Int (List.length tools));
    ])

let summary_int field summary =
  match Yojson.Safe.Util.(summary |> member field) with
  | `Int value -> value
  | other -> failf "expected int field %s, got %s" field (Yojson.Safe.to_string other)

(* #32971 Root B: the Turn row the producer writes today carries neither
   [generation] (removed by #29590) nor [handoff_performed] (removed by
   #31522). While the window required both, every Turn row fell through the
   tuple match and the series and the turn counters read zero for a Keeper
   with hundreds of turns. *)
let test_producer_shaped_turn_rows_enter_the_window () =
  let items, summary =
    Detail.compute_metrics_window
      ~parsed_metrics:[ metric [ "tool_execute" ]; metric [ "tool_read" ] ]
      ~series_points:80
  in
  check int "producer-shaped rows reach the series" 2 (List.length items);
  check int "turn_points counts them" 2 (summary_int "turn_points" summary);
  check int "sample_points counts them" 2 (summary_int "sample_points" summary);
  check int "tool calls accumulate" 2 (summary_int "tool_call_count" summary)
;;

let () =
  run "dashboard_keeper_metrics_10286"
    [
      ( "metrics_window",
        [
          test_case "producer-shaped turn rows enter the window" `Quick
            test_producer_shaped_turn_rows_enter_the_window;
        ] );
    ]
