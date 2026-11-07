(** What the Usage view's Calls section asks the server for and keeps of the
    answer. The section draws the last 24 hours, 7 days or 14 days. Asked for
    exactly those hours, the server answers one bucket more, with a first
    bucket that holds only part of its hour or day, and a chart that kept it
    would draw a short bar for the oldest bucket. These cases pin the request,
    which buckets are kept and which answers are refused, and they ask the
    server's own series code what a request of that length gets. What the
    section looks like is not tested here: a screen is shown by a capture, not
    by a test of its text (docs/constitution.xml). *)

open Alcotest

module Calls = Masc_tui_usage_calls
module Series = Masc.Tui_decode_tool_series
module Server = Tool_metrics_series

let hour = 3600.0
let day = 86400.0

(* 2026-11-04 00:00:00 UTC *)
let utc_midnight = 1793750400.0

let series ~width ~offset ~step ~count =
  { Series.tsr_generated_at = utc_midnight +. (float_of_int count *. step)
  ; tsr_width = width
  ; tsr_utc_offset_min = offset
  ; tsr_buckets =
      List.init count (fun index ->
        { Series.tsb_start = utc_midnight +. (float_of_int index *. step)
        ; tsb_activity = Series.Series_idle
        })
  }
;;

let starts (calls : Calls.t) =
  List.map (fun (bucket : Series.tool_series_bucket) -> bucket.Series.tsb_start)
    calls.Calls.series.Series.tsr_buckets
;;

let kept_exn window answer =
  match Calls.of_series window answer with
  | Ok calls -> calls
  | Error reason -> Alcotest.failf "the answer was refused: %s" reason
;;

let test_windows_follow_the_days_the_usage_view_cycles_through () =
  List.iter
    (fun (days, window) ->
       check bool (Printf.sprintf "%d days" days) true
         (Calls.window_of_days days = Some window))
    [ 1, Calls.Last_day; 7, Calls.Last_week; 14, Calls.Last_fortnight ];
  List.iter
    (fun days ->
       check bool (Printf.sprintf "%d days has no window" days) true
         (Calls.window_of_days days = None))
    [ -1; 0; 2; 3; 8; 13; 15; 30 ]
;;

let windows = [ Calls.Last_day; Calls.Last_week; Calls.Last_fortnight ]

let test_the_request_asks_for_the_hours_of_the_window () =
  check (list int) "buckets drawn" [ 24; 7; 14 ] (List.map Calls.bucket_count windows);
  check (list int) "hours asked for" [ 24; 168; 336 ] (List.map Calls.since_hours windows)
;;

(* The server's own answer to the request the section sends, on a clock in the
   middle of a bucket, one second after an edge and one second before one. *)
let test_the_server_answers_the_request_with_one_partial_bucket_more () =
  let server_width = function
    | Series.Series_hour -> Server.Hour
    | Series.Series_day -> Server.Day
  in
  List.iter
    (fun window ->
       List.iter
         (fun into_day ->
            let until = utc_midnight +. (10.0 *. day) +. into_day in
            let since = until -. (float_of_int (Calls.since_hours window) *. hour) in
            let shape =
              match
                Server.window ~since ~until ~width:(server_width (Calls.width window))
                  ~utc_offset_min:0
              with
              | Ok shape -> shape
              | Error error -> Alcotest.failf "window: %s" error
            in
            let json = Server.to_json ~generated_at:until (Server.finish (Server.builder shape)) in
            let answer =
              match Series.decode_tool_series json with
              | Ok answer -> answer
              | Error reason -> Alcotest.failf "the server's own series was refused: %s" reason
            in
            let label = Printf.sprintf "%d buckets drawn, clock %g s into the day"
                (Calls.bucket_count window) into_day in
            let held = List.map (fun (bucket : Series.tool_series_bucket) -> bucket.Series.tsb_start)
                answer.Series.tsr_buckets in
            check int (label ^ ": the answer holds one more") (Calls.bucket_count window + 1)
              (List.length held);
            check bool (label ^ ": the first bucket starts before the request") true
              (List.hd held < since);
            let calls = kept_exn window answer in
            check int (label ^ ": the window is kept") (Calls.bucket_count window)
              (List.length (starts calls));
            check bool (label ^ ": every kept bucket starts inside the request") true
              (List.for_all (fun start -> start >= since) (starts calls)))
         [ (19.0 *. hour) +. 1770.0; (19.0 *. hour) +. 1.0; (20.0 *. hour) -. 1.0 ])
    windows
;;

let test_the_partial_first_bucket_of_an_answer_is_dropped () =
  let hours = kept_exn Calls.Last_day (series ~width:Series.Series_hour ~offset:0 ~step:hour ~count:25) in
  check int "buckets kept" 24 (List.length (starts hours));
  check (float 0.0) "the partial first bucket is gone" (utc_midnight +. hour)
    (List.hd (starts hours));
  check (float 0.0) "the newest bucket stays"
    (utc_midnight +. (24.0 *. hour))
    (List.hd (List.rev (starts hours)));
  let week = kept_exn Calls.Last_week (series ~width:Series.Series_day ~offset:0 ~step:day ~count:8) in
  check int "a week keeps seven days" 7 (List.length (starts week));
  let longer = kept_exn Calls.Last_day (series ~width:Series.Series_hour ~offset:0 ~step:hour ~count:26) in
  check (float 0.0) "a longer answer is cut from the old end too" (utc_midnight +. (2.0 *. hour))
    (List.hd (starts longer));
  let exact = kept_exn Calls.Last_day (series ~width:Series.Series_hour ~offset:0 ~step:hour ~count:24) in
  check int "an answer of exactly the window is kept whole" 24 (List.length (starts exact))
;;

let test_answers_that_do_not_fit_the_window_are_refused () =
  List.iter
    (fun (label, window, answer) ->
       check bool label true (Result.is_error (Calls.of_series window answer)))
    [ "days for a day window", Calls.Last_day,
      series ~width:Series.Series_day ~offset:0 ~step:day ~count:26
    ; "hours for a week window", Calls.Last_week,
      series ~width:Series.Series_hour ~offset:0 ~step:hour ~count:26
    ; "edges that follow Seoul", Calls.Last_week,
      series ~width:Series.Series_day ~offset:540 ~step:day ~count:9
    ; "one bucket short of the window", Calls.Last_day,
      series ~width:Series.Series_hour ~offset:0 ~step:hour ~count:23
    ; "no bucket at all", Calls.Last_fortnight,
      series ~width:Series.Series_day ~offset:0 ~step:day ~count:0
    ]
;;

let () =
  run
    "Tui_usage_calls"
    [ ( "window"
      , [ test_case "windows follow the days the Usage view cycles through" `Quick
            test_windows_follow_the_days_the_usage_view_cycles_through
        ; test_case "the request asks for the hours of the window" `Quick
            test_the_request_asks_for_the_hours_of_the_window
        ; test_case "the server answers the request with one partial bucket more" `Quick
            test_the_server_answers_the_request_with_one_partial_bucket_more
        ; test_case "the partial first bucket of an answer is dropped" `Quick
            test_the_partial_first_bucket_of_an_answer_is_dropped
        ; test_case "answers that do not fit the window are refused" `Quick
            test_answers_that_do_not_fit_the_window_are_refused
        ] )
    ]
;;
