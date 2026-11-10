(** Tests for Tool_metrics_series — hourly and daily totals of tool calls.

    A series that puts a call in the wrong hour, or counts a day twice, draws a
    wrong chart without failing anywhere. These cases pin where each call lands
    and which numbers a bucket reports. *)

module S = Tool_metrics_series

let hour = 3600.0
let day = 86400.0
let seoul_offset_min = 540
let kolkata_offset_min = 330
let new_york_offset_min = -300
let st_johns_offset_min = -210

(* 2026-11-04 00:00:00 UTC *)
let utc_midnight = 1793750400.0

(* 2026-11-05 00:00:00 in Seoul, which is 2026-11-04 15:00:00 UTC. *)
let seoul_midnight = 1793804400.0

let window_exn ~since ~until ~width ~offset =
  match S.window ~since ~until ~width ~utc_offset_min:offset with
  | Ok window -> window
  | Error error -> Alcotest.failf "window: %s" error
;;

let sample ?(disposition = S.Completed) ~ts ~tool duration_ms : S.sample =
  { ts; tool_name = tool; disposition; duration_ms; result_bytes = None }
;;

let add_exn builder sample =
  match S.add builder sample with
  | Ok () -> ()
  | Error error -> Alcotest.failf "add: %s" error
;;

let series_of window samples =
  let builder = S.builder window in
  List.iter (add_exn builder) samples;
  S.finish builder
;;

let starts (series : S.t) = List.map (fun (bucket : S.bucket) -> bucket.start) series.buckets

let calls (series : S.t) =
  List.map (fun (bucket : S.bucket) -> bucket.summary.call_count) series.buckets
;;

let option_float = Alcotest.(option (float 0.0))
let minute_ms = 60_000.0

let long_counts (series : S.t) =
  List.map (fun (bucket : S.bucket) -> bucket.summary.long_count) series.buckets
;;

let long_times (series : S.t) =
  List.map (fun (bucket : S.bucket) -> bucket.summary.long_total_ms) series.buckets
;;

let test_window_rejects_what_it_cannot_chart () =
  let rejected label result =
    match result with
    | Ok _ -> Alcotest.failf "%s: expected an error" label
    | Error _ -> ()
  in
  let ask ?(width = S.Hour) ?(offset = 0) since until =
    S.window ~since ~until ~width ~utc_offset_min:offset
  in
  rejected "empty window" (ask utc_midnight utc_midnight);
  rejected "reversed window" (ask (utc_midnight +. hour) utc_midnight);
  rejected "not finite" (ask Float.nan utc_midnight);
  rejected "negative start" (ask (-1.0) utc_midnight);
  rejected
    "longer than the limit"
    (ask utc_midnight (utc_midnight +. (Float.of_int (S.max_window_days + 1) *. day)));
  rejected "offset east of +14h" (ask ~offset:((14 * 60) + 1) utc_midnight (utc_midnight +. hour));
  rejected "offset west of -14h" (ask ~offset:(-((14 * 60) + 1)) utc_midnight (utc_midnight +. hour));
  let longest = utc_midnight +. (Float.of_int S.max_window_days *. day) in
  match ask utc_midnight longest with
  | Ok _ -> ()
  | Error error -> Alcotest.failf "a window of the longest allowed length: %s" error
;;

let test_day_buckets_follow_the_viewers_clock () =
  let since = seoul_midnight -. day in
  let window =
    window_exn ~since ~until:(since +. (3.0 *. day)) ~width:S.Day ~offset:seoul_offset_min
  in
  let series =
    series_of
      window
      [ sample ~ts:(seoul_midnight -. 1.0) ~tool:"a" 10.0
      ; sample ~ts:seoul_midnight ~tool:"a" 20.0
      ]
  in
  Alcotest.(check (list (float 0.0)))
    "each bucket starts at midnight in Seoul"
    [ since; since +. day; since +. (2.0 *. day) ]
    (starts series);
  Alcotest.(check (list int))
    "the call before midnight and the call after it land in different days"
    [ 1; 1; 0 ]
    (calls series)
;;

let test_hour_buckets_follow_a_half_hour_offset () =
  (* Kolkata is UTC+05:30, so its hours start 30 minutes into a UTC hour. *)
  let since = utc_midnight +. (11.5 *. hour) in
  let window =
    window_exn ~since ~until:(since +. (3.0 *. hour)) ~width:S.Hour ~offset:kolkata_offset_min
  in
  let series =
    series_of
      window
      [ sample ~ts:(utc_midnight +. (12.0 *. hour) +. 600.0) ~tool:"a" 1.0
      ; sample ~ts:(utc_midnight +. (12.0 *. hour) +. 2400.0) ~tool:"a" 1.0
      ]
  in
  Alcotest.(check (list (float 0.0)))
    "buckets start at :30 UTC"
    [ since; since +. hour; since +. (2.0 *. hour) ]
    (starts series);
  Alcotest.(check (list int)) "12:10 UTC and 12:40 UTC are in different hours" [ 1; 1; 0 ] (calls series)
;;

(* West of Greenwich the offset is negative and a local day starts after UTC
   midnight. A bucket start that applied the offset with the wrong sign would
   be off by twice the offset here, and the east cases above would not show it. *)
let test_buckets_west_of_utc_start_after_utc_midnight () =
  let new_york_midnight = utc_midnight +. (5.0 *. hour) in
  let day_since = new_york_midnight -. day in
  let days =
    series_of
      (window_exn ~since:day_since ~until:(day_since +. (3.0 *. day)) ~width:S.Day ~offset:new_york_offset_min)
      [ sample ~ts:(new_york_midnight -. 1.0) ~tool:"a" 10.0
      ; sample ~ts:new_york_midnight ~tool:"a" 20.0
      ]
  in
  Alcotest.(check (list (float 0.0)))
    "each day starts at midnight in New York, 05:00 UTC"
    [ day_since; day_since +. day; day_since +. (2.0 *. day) ]
    (starts days);
  Alcotest.(check (list int)) "the calls on either side of local midnight land in different days" [ 1; 1; 0 ] (calls days);
  (* St. John's is UTC-03:30, so its hours start 30 minutes into a UTC hour. *)
  let hour_since = utc_midnight +. (11.5 *. hour) in
  let hours =
    series_of
      (window_exn ~since:hour_since ~until:(hour_since +. (3.0 *. hour)) ~width:S.Hour ~offset:st_johns_offset_min)
      [ sample ~ts:(utc_midnight +. (12.0 *. hour) +. 600.0) ~tool:"a" 1.0
      ; sample ~ts:(utc_midnight +. (12.0 *. hour) +. 2400.0) ~tool:"a" 1.0
      ]
  in
  Alcotest.(check (list (float 0.0)))
    "hours start at :30 UTC"
    [ hour_since; hour_since +. hour; hour_since +. (2.0 *. hour) ]
    (starts hours);
  Alcotest.(check (list int)) "12:10 UTC and 12:40 UTC are in different hours" [ 1; 1; 0 ] (calls hours)
;;

let test_a_window_that_starts_mid_bucket_includes_that_bucket () =
  let since = utc_midnight +. (0.5 *. hour) in
  let until = utc_midnight +. (4.5 *. hour) in
  let window = window_exn ~since ~until ~width:S.Hour ~offset:0 in
  let series =
    series_of
      window
      [ sample ~ts:since ~tool:"a" 1.0; sample ~ts:(Float.pred until) ~tool:"a" 1.0 ]
  in
  Alcotest.(check (list (float 0.0)))
    "the first and the last bucket are whole hours"
    [ utc_midnight
    ; utc_midnight +. hour
    ; utc_midnight +. (2.0 *. hour)
    ; utc_midnight +. (3.0 *. hour)
    ; utc_midnight +. (4.0 *. hour)
    ]
    (starts series);
  Alcotest.(check (list int)) "the two edge calls count" [ 1; 0; 0; 0; 1 ] (calls series)
;;

let test_a_bucket_with_no_calls_has_no_latency () =
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. (2.0 *. hour)) ~width:S.Hour ~offset:0
  in
  let series = series_of window [ sample ~ts:(utc_midnight +. hour) ~tool:"a" 40.0 ] in
  match series.buckets with
  | [ idle; busy ] ->
    Alcotest.(check int) "idle bucket has zero calls" 0 idle.summary.call_count;
    Alcotest.(check option_float) "idle p50" None idle.summary.p50_ms;
    Alcotest.(check option_float) "idle p95" None idle.summary.p95_ms;
    Alcotest.(check option_float) "idle max" None idle.summary.max_ms;
    Alcotest.(check option_float) "busy p95" (Some 40.0) busy.summary.p95_ms
  | other -> Alcotest.failf "expected two buckets, got %d" (List.length other)
;;

let test_samples_outside_the_window_or_with_bad_durations_are_refused () =
  let until = utc_midnight +. hour in
  let window = window_exn ~since:utc_midnight ~until ~width:S.Hour ~offset:0 in
  let builder = S.builder window in
  let refused label sample =
    match S.add builder sample with
    | Ok () -> Alcotest.failf "%s: expected an error" label
    | Error _ -> ()
  in
  refused "before the window" (sample ~ts:(utc_midnight -. 1.0) ~tool:"a" 1.0);
  refused "at the end, which is excluded" (sample ~ts:until ~tool:"a" 1.0);
  refused "negative duration" (sample ~ts:utc_midnight ~tool:"a" (-1.0));
  refused "duration not finite" (sample ~ts:utc_midnight ~tool:"a" Float.nan);
  add_exn builder (sample ~ts:utc_midnight ~tool:"a" 5.0);
  let series = S.finish builder in
  Alcotest.(check int) "only the accepted call is counted" 1 series.total.call_count
;;

let test_failed_and_deferred_calls_are_counted_and_timed () =
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. hour) ~width:S.Hour ~offset:0
  in
  let series =
    series_of
      window
      [ sample ~ts:utc_midnight ~tool:"a" 10.0
      ; sample ~disposition:S.Failed ~ts:utc_midnight ~tool:"a" 30.0
      ; sample ~disposition:S.Failed ~ts:utc_midnight ~tool:"a" 50.0
      ; sample ~disposition:S.Deferred ~ts:utc_midnight ~tool:"a" 70.0
      ]
  in
  let total = series.total in
  Alcotest.(check (list int))
    "calls, failed, deferred"
    [ 4; 2; 1 ]
    [ total.call_count; total.failure_count; total.deferred_count ];
  Alcotest.(check (float 0.0)) "every disposition adds its duration" 160.0 total.total_ms;
  Alcotest.(check option_float) "max" (Some 70.0) total.max_ms
;;

(* The line between a short and a long call is one minute, the line of the
   Execute wait census. A call of exactly one minute is long, and so is a long
   call that failed or returned a receipt. *)
let test_a_call_of_one_minute_is_long () =
  Alcotest.(check (float 0.0)) "the line is one minute" minute_ms S.long_call_threshold_ms;
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. hour) ~width:S.Hour ~offset:0
  in
  let series =
    series_of
      window
      [ sample ~ts:utc_midnight ~tool:"a" (minute_ms -. 1.0)
      ; sample ~ts:utc_midnight ~tool:"a" minute_ms
      ; sample ~disposition:S.Failed ~ts:utc_midnight ~tool:"a" (2.0 *. minute_ms)
      ; sample ~disposition:S.Deferred ~ts:utc_midnight ~tool:"a" (3.0 *. minute_ms)
      ]
  in
  let total = series.total in
  Alcotest.(check int) "every call is counted" 4 total.call_count;
  Alcotest.(check int) "the call just under a minute is short" 3 total.long_count;
  Alcotest.(check (float 0.0))
    "the time of the long calls leaves the short call out"
    (6.0 *. minute_ms)
    total.long_total_ms;
  Alcotest.(check (float 0.0))
    "the total time still has the short call"
    ((6.0 *. minute_ms) +. (minute_ms -. 1.0))
    total.total_ms
;;

let test_long_calls_are_counted_per_bucket_and_per_tool () =
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. (3.0 *. hour)) ~width:S.Hour ~offset:0
  in
  let series =
    series_of
      window
      [ sample ~ts:utc_midnight ~tool:"wait" (5.0 *. minute_ms)
      ; sample ~ts:utc_midnight ~tool:"wait" (2.0 *. minute_ms)
      ; sample ~ts:utc_midnight ~tool:"read" 40.0
      ; sample ~ts:(utc_midnight +. (2.0 *. hour)) ~tool:"build" minute_ms
      ]
  in
  Alcotest.(check (list int)) "long calls per hour, none in the idle hour" [ 2; 0; 1 ] (long_counts series);
  Alcotest.(check (list (float 0.0)))
    "time inside the long calls per hour"
    [ 7.0 *. minute_ms; 0.0; minute_ms ]
    (long_times series);
  Alcotest.(check (list (pair string int)))
    "long calls per tool, longest total first"
    [ "wait", 2; "build", 1; "read", 0 ]
    (List.map (fun (tool : S.tool_usage) -> tool.name, tool.usage.long_count) series.top_by_time);
  Alcotest.(check int) "the window total adds the hours" 3 series.total.long_count
;;

(* The retained snapshot's p50 and p95 come from [Tool_metrics]. A series over
   the same calls has to report the same numbers, or the same tool reads
   differently on two panels. *)
let test_percentiles_match_tool_metrics () =
  let random = Random.State.make [| 0x5e51e5; 0x32009 |] in
  let durations = List.init 5_000 (fun _ -> Float.of_int (Random.State.int random 10_000)) in
  let installed =
    Tool_metrics.replace_samples (fun add ->
      List.iter
        (fun duration_ms ->
           add { Tool_metrics.tool_name = "parity"; disposition = Tool_metrics.Completed; duration_ms })
        durations;
      (Ok () : (unit, string) result))
  in
  (match installed with
   | Ok () -> ()
   | Error error -> Alcotest.failf "install samples: %s" error);
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. hour) ~width:S.Hour ~offset:0
  in
  let series =
    series_of window (List.map (fun duration_ms -> sample ~ts:utc_midnight ~tool:"parity" duration_ms) durations)
  in
  let expected =
    match Tool_metrics.stats_for "parity" with
    | Some stats -> stats
    | None -> Alcotest.fail "Tool_metrics has no stats for the tool"
  in
  Alcotest.(check option_float) "p50" (Some expected.p50_ms) series.total.p50_ms;
  Alcotest.(check option_float) "p95" (Some expected.p95_ms) series.total.p95_ms;
  Tool_metrics.clear ()
;;

let test_top_tools_are_ordered_by_time_spent () =
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. hour) ~width:S.Hour ~offset:0
  in
  let quiet =
    List.init 22 (fun index -> sample ~ts:utc_midnight ~tool:(Printf.sprintf "quiet-%02d" index) 1.0)
  in
  let series =
    series_of
      window
      (quiet
       @ [ sample ~ts:utc_midnight ~tool:"tie-b" 10.0
         ; sample ~ts:utc_midnight ~tool:"tie-a" 10.0
         ; sample ~ts:utc_midnight ~tool:"slow" 1_000.0
         ])
  in
  Alcotest.(check int) "keeps the limit" S.top_tool_limit (List.length series.top_by_time);
  Alcotest.(check (list string))
    "longest first, equal time by name"
    [ "slow"; "tie-a"; "tie-b" ]
    (List.filteri (fun index _ -> index < 3) (List.map (fun (tool : S.tool_usage) -> tool.name) series.top_by_time));
  Alcotest.(check int) "the total still counts every tool" 25 series.total.call_count
;;

let test_names_parse_into_closed_types () =
  let is_error = function
    | Ok _ -> false
    | Error _ -> true
  in
  Alcotest.(check bool) "hour" true (S.width_of_string "hour" = Ok S.Hour);
  Alcotest.(check bool) "day" true (S.width_of_string "day" = Ok S.Day);
  Alcotest.(check bool) "week is not a width" true (is_error (S.width_of_string "week"));
  Alcotest.(check bool) "failed" true (S.disposition_of_string "failed" = Ok S.Failed);
  Alcotest.(check bool) "unknown disposition" true (is_error (S.disposition_of_string "skipped"))
;;

let test_json_carries_null_for_a_bucket_with_no_calls () =
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. (2.0 *. hour)) ~width:S.Hour ~offset:0
  in
  let series = series_of window [ sample ~ts:(utc_midnight +. hour) ~tool:"a" 40.0 ] in
  let json =
    S.to_json
      ~generated_at:utc_midnight
      ~tool_name:"a"
      ~public_names:(fun name -> [ "Public" ^ name ])
      series
  in
  let open Yojson.Safe.Util in
  let since, until = S.window_bounds window in
  Alcotest.(check (float 0.0)) "window since" since (json |> member "window" |> member "since" |> to_float);
  Alcotest.(check (float 0.0)) "window until" until (json |> member "window" |> member "until" |> to_float);
  Alcotest.(check string) "tool filter is echoed" "a" (json |> member "tool" |> to_string);
  Alcotest.(check (list string))
    "the tool row lists the public names"
    [ "Publica" ]
    (json |> member "top_by_time" |> to_list |> List.hd |> member "public_names" |> to_list |> List.map to_string);
  Alcotest.(check int) "bucket width in seconds" 3600 (json |> member "window" |> member "bucket_seconds" |> to_int);
  match json |> member "buckets" |> to_list with
  | [ idle; busy ] ->
    Alcotest.(check bool) "idle p95 is null" true (member "p95_ms" idle = `Null);
    Alcotest.(check (float 0.0)) "busy p95" 40.0 (member "p95_ms" busy |> to_float)
  | other -> Alcotest.failf "expected two buckets, got %d" (List.length other)
;;

(* A dashboard that read [long_count] as absent would draw no long call at
   all. Every row of the answer carries both numbers, zero for an idle hour,
   and the answer names the line they were counted from. *)
let test_json_counts_long_calls_in_every_row_and_names_the_line () =
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. (2.0 *. hour)) ~width:S.Hour ~offset:0
  in
  (* A short call beside the long one: the counts and the times of the long calls
     differ from those of all calls, so a field read from the wrong one shows. *)
  let series =
    series_of
      window
      [ sample ~ts:(utc_midnight +. hour) ~tool:"a" (1.5 *. minute_ms)
      ; sample ~ts:(utc_midnight +. hour) ~tool:"a" 30.0
      ]
  in
  let json = S.to_json ~generated_at:utc_midnight series in
  let open Yojson.Safe.Util in
  Alcotest.(check (float 0.0)) "the line a long call starts at" minute_ms (json |> member "long_call_ms" |> to_float);
  let long_fields row = member "long_count" row, member "long_total_ms" row in
  let json_value = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal in
  let json_pair = Alcotest.pair json_value json_value in
  let one_long = `Int 1, `Float (1.5 *. minute_ms) in
  Alcotest.check json_pair "window total" one_long (long_fields (member "total" json));
  (match json |> member "buckets" |> to_list with
   | [ idle; busy ] ->
     Alcotest.check json_pair "an idle hour is zero, not null" (`Int 0, `Float 0.0) (long_fields idle);
     Alcotest.check json_pair "a busy hour" one_long (long_fields busy)
   | other -> Alcotest.failf "expected two buckets, got %d" (List.length other));
  match json |> member "top_by_time" |> to_list with
  | [ row ] -> Alcotest.check json_pair "a tool row" one_long (long_fields row)
  | other -> Alcotest.failf "expected one tool row, got %d" (List.length other)
;;

let sized ?bytes ~ts ~tool duration_ms : S.sample =
  { (sample ~ts ~tool duration_ms) with result_bytes = bytes }
;;

let byte_totals (series : S.t) =
  List.map (fun (bucket : S.bucket) -> bucket.summary.result_bytes_total) series.buckets
;;

let observed_counts (series : S.t) =
  List.map (fun (bucket : S.bucket) -> bucket.summary.result_observed_count) series.buckets
;;

let byte_maxes (series : S.t) =
  List.map (fun (bucket : S.bucket) -> bucket.summary.result_bytes_max) series.buckets
;;

let tool_usage (series : S.t) name =
  match List.find_opt (fun (tool : S.tool_usage) -> String.equal tool.name name) series.top_by_time with
  | Some tool -> tool.usage
  | None -> Alcotest.failf "no row for tool %s" name
;;

let test_result_sizes_are_summed_where_they_are_known () =
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. (3.0 *. hour)) ~width:S.Hour ~offset:0
  in
  let series =
    series_of
      window
      [ sized ~bytes:100 ~ts:utc_midnight ~tool:"a" 10.0
      ; sized ~bytes:300 ~ts:utc_midnight ~tool:"a" 10.0
      ; sized ~ts:utc_midnight ~tool:"b" 10.0
      ; sized ~bytes:0 ~ts:(utc_midnight +. (2.0 *. hour)) ~tool:"b" 10.0
      ]
  in
  Alcotest.(check (list int)) "calls per hour" [ 3; 0; 1 ] (calls series);
  Alcotest.(check (list int)) "calls with a size per hour" [ 2; 0; 1 ] (observed_counts series);
  Alcotest.(check (list int)) "bytes per hour" [ 400; 0; 0 ] (byte_totals series);
  (* An hour whose only size is 0 is observed; an hour with no size is not. *)
  Alcotest.(check (list (option int)))
    "largest result per hour"
    [ Some 300; None; Some 0 ]
    (byte_maxes series);
  Alcotest.(check int) "calls with a size in the window" 3 series.total.result_observed_count;
  Alcotest.(check int) "bytes in the window" 400 series.total.result_bytes_total;
  let a = tool_usage series "a" in
  Alcotest.(check (pair int int)) "tool a: sized calls and bytes" (2, 400) (a.result_observed_count, a.result_bytes_total);
  let b = tool_usage series "b" in
  Alcotest.(check (pair int int)) "tool b: sized calls and bytes" (1, 0) (b.result_observed_count, b.result_bytes_total);
  Alcotest.(check (option int)) "tool b: a size of zero is a largest result of zero" (Some 0) b.result_bytes_max
;;

let test_a_negative_result_size_is_refused () =
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. hour) ~width:S.Hour ~offset:0
  in
  let builder = S.builder window in
  (match S.add builder (sized ~bytes:(-1) ~ts:utc_midnight ~tool:"a" 1.0) with
   | Error _ -> ()
   | Ok () -> Alcotest.fail "a negative size was counted");
  let series = S.finish builder in
  Alcotest.(check int) "nothing counted" 0 series.total.call_count
;;

let test_json_carries_result_sizes_and_null_for_unsized_buckets () =
  let window =
    window_exn ~since:utc_midnight ~until:(utc_midnight +. (2.0 *. hour)) ~width:S.Hour ~offset:0
  in
  let series =
    series_of
      window
      [ sized ~bytes:40 ~ts:(utc_midnight +. hour) ~tool:"a" 1.0
      ; sized ~bytes:60 ~ts:(utc_midnight +. hour) ~tool:"a" 1.0
      ; sized ~ts:(utc_midnight +. hour) ~tool:"a" 1.0
      ]
  in
  let json = S.to_json ~generated_at:utc_midnight series in
  let open Yojson.Safe.Util in
  let json_value = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal in
  let size_fields row =
    ( member "result_observed_count" row
    , member "result_bytes_total" row
    , member "result_bytes_max" row )
  in
  let triple = Alcotest.triple json_value json_value json_value in
  let busy = `Int 2, `Int 100, `Int 60 in
  Alcotest.check triple "window total" busy (size_fields (member "total" json));
  (match json |> member "buckets" |> to_list with
   | [ idle; busy_hour ] ->
     Alcotest.check triple "an hour with no call has no size, not a zero size" (`Int 0, `Int 0, `Null) (size_fields idle);
     Alcotest.check triple "an hour with sized calls" busy (size_fields busy_hour)
   | other -> Alcotest.failf "expected two buckets, got %d" (List.length other));
  match json |> member "top_by_time" |> to_list with
  | [ row ] -> Alcotest.check triple "a tool row" busy (size_fields row)
  | other -> Alcotest.failf "expected one tool row, got %d" (List.length other)
;;

(* The store: rows written by [insert] come back through [read_series]. *)

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_masc_root f =
  let base = Filename.temp_dir "tool-metrics-series-" "" in
  Fun.protect
    ~finally:(fun () ->
      Tool_metrics_store.reset_for_testing ();
      rm_rf base)
    (fun () ->
       Tool_metrics_store.reset_for_testing ();
       Eio_main.run (fun env ->
         Fs_compat.set_fs (Eio.Stdenv.fs env);
         Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
           f ~masc_root:(Filename.concat base ".masc"))))
;;

let insert_exn ?(result_bytes = 0) ~masc_root ~record_id ~ts ~tool_name ~disposition duration_ms =
  match
    Tool_metrics_store.insert
      ~masc_root
      ~result_bytes
      { Tool_metrics_store.record_id; ts; tool_name; disposition; duration_ms }
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "insert: %s" error
;;

let read_series_exn ~masc_root ~window ?tool_name () =
  match Tool_metrics_store.read_series ~masc_root ~window ?tool_name () with
  | Ok series -> series
  | Error error -> Alcotest.failf "read_series: %s" error
;;

let test_read_series_groups_the_stored_calls () =
  with_masc_root (fun ~masc_root ->
    let insert = insert_exn ~masc_root in
    insert ~record_id:"r1" ~ts:(utc_midnight +. 10.0) ~tool_name:"read" ~disposition:"completed" 100.0;
    insert ~record_id:"r2" ~ts:(utc_midnight +. 20.0) ~tool_name:"read" ~disposition:"failed" 300.0;
    insert ~record_id:"r3" ~ts:(utc_midnight +. hour +. 5.0) ~tool_name:"write" ~disposition:"completed" 50.0;
    (* Before the window and at its end: both are outside. *)
    insert ~record_id:"r4" ~ts:(utc_midnight -. 1.0) ~tool_name:"read" ~disposition:"completed" 1.0;
    insert ~record_id:"r5" ~ts:(utc_midnight +. (2.0 *. hour)) ~tool_name:"read" ~disposition:"completed" 1.0;
    let window =
      window_exn ~since:utc_midnight ~until:(utc_midnight +. (2.0 *. hour)) ~width:S.Hour ~offset:0
    in
    let all = read_series_exn ~masc_root ~window () in
    Alcotest.(check (list int)) "calls per hour" [ 2; 1 ] (calls all);
    Alcotest.(check int) "failed calls" 1 all.total.failure_count;
    Alcotest.(check (list string))
      "tools by time spent"
      [ "read"; "write" ]
      (List.map (fun (tool : S.tool_usage) -> tool.name) all.top_by_time);
    let only_write = read_series_exn ~masc_root ~window ~tool_name:"write" () in
    Alcotest.(check (list int)) "calls of one tool" [ 0; 1 ] (calls only_write))
;;

let test_read_series_counts_the_stored_long_calls () =
  with_masc_root (fun ~masc_root ->
    let insert = insert_exn ~masc_root in
    insert ~record_id:"short" ~ts:(utc_midnight +. 10.0) ~tool_name:"Execute" ~disposition:"completed" (minute_ms -. 1.0);
    insert ~record_id:"long" ~ts:(utc_midnight +. 20.0) ~tool_name:"Execute" ~disposition:"completed" minute_ms;
    insert
      ~record_id:"long-failed"
      ~ts:(utc_midnight +. hour +. 5.0)
      ~tool_name:"Execute"
      ~disposition:"failed"
      (10.0 *. minute_ms);
    let window =
      window_exn ~since:utc_midnight ~until:(utc_midnight +. (2.0 *. hour)) ~width:S.Hour ~offset:0
    in
    let series = read_series_exn ~masc_root ~window () in
    Alcotest.(check (list int)) "long calls per hour" [ 1; 1 ] (long_counts series);
    Alcotest.(check (float 0.0)) "time inside the long calls" (11.0 *. minute_ms) series.total.long_total_ms)
;;

(* A row written before sizes were kept, as the live database holds 800,000 of:
   an event without a row in the size table. *)
let insert_unsized_row_exn ~masc_root ~record_id ~ts ~tool_name duration_ms =
  let db = Sqlite3.db_open (Tool_metrics_store.database_path ~masc_root) in
  let sql =
    Printf.sprintf
      "INSERT INTO tool_metric_events (record_id, ts, tool_name, disposition, duration_ms) \
       VALUES ('%s', %f, '%s', 'completed', %f)"
      record_id
      ts
      tool_name
      duration_ms
  in
  let rc = Sqlite3.exec db sql in
  let closed = Sqlite3.db_close db in
  if not (Sqlite3.Rc.is_success rc && closed)
  then Alcotest.failf "insert unsized row: %s" (Sqlite3.Rc.to_string rc)
;;

let test_read_series_sums_stored_sizes_and_leaves_old_rows_unsized () =
  with_masc_root (fun ~masc_root ->
    insert_exn ~result_bytes:1000 ~masc_root ~record_id:"read-1" ~ts:(utc_midnight +. 10.0) ~tool_name:"read" ~disposition:"completed" 5.0;
    insert_exn ~result_bytes:50 ~masc_root ~record_id:"write-1" ~ts:(utc_midnight +. 20.0) ~tool_name:"write" ~disposition:"completed" 5.0;
    insert_unsized_row_exn ~masc_root ~record_id:"read-old" ~ts:(utc_midnight +. 30.0) ~tool_name:"read" 5.0;
    let window =
      window_exn ~since:utc_midnight ~until:(utc_midnight +. hour) ~width:S.Hour ~offset:0
    in
    let all = read_series_exn ~masc_root ~window () in
    Alcotest.(check int) "all three calls are counted" 3 all.total.call_count;
    Alcotest.(check int) "two calls have a size" 2 all.total.result_observed_count;
    Alcotest.(check int) "bytes of the sized calls" 1050 all.total.result_bytes_total;
    Alcotest.(check (option int)) "largest result" (Some 1000) all.total.result_bytes_max;
    let only_read = read_series_exn ~masc_root ~window ~tool_name:"read" () in
    Alcotest.(check int) "read: both calls" 2 only_read.total.call_count;
    Alcotest.(check int) "read: one call has a size" 1 only_read.total.result_observed_count;
    Alcotest.(check int) "read: bytes" 1000 only_read.total.result_bytes_total)
;;

let test_insert_keeps_the_first_size_of_a_record_id () =
  with_masc_root (fun ~masc_root ->
    let insert result_bytes =
      insert_exn ~result_bytes ~masc_root ~record_id:"same" ~ts:(utc_midnight +. 10.0) ~tool_name:"read" ~disposition:"completed" 5.0
    in
    insert 7;
    insert 99;
    let window =
      window_exn ~since:utc_midnight ~until:(utc_midnight +. hour) ~width:S.Hour ~offset:0
    in
    let series = read_series_exn ~masc_root ~window () in
    Alcotest.(check int) "one call" 1 series.total.call_count;
    Alcotest.(check int) "the first size stays" 7 series.total.result_bytes_total)
;;

let test_insert_refuses_a_negative_size () =
  with_masc_root (fun ~masc_root ->
    match
      Tool_metrics_store.insert
        ~masc_root
        ~result_bytes:(-1)
        { Tool_metrics_store.record_id = "negative"
        ; ts = utc_midnight
        ; tool_name = "read"
        ; disposition = "completed"
        ; duration_ms = 1.0
        }
    with
    | Error _ -> ()
    | Ok () -> Alcotest.fail "a negative size was stored")
;;

let test_read_series_without_a_database_is_empty_and_creates_none () =
  with_masc_root (fun ~masc_root ->
    let window =
      window_exn ~since:utc_midnight ~until:(utc_midnight +. hour) ~width:S.Hour ~offset:0
    in
    let series = read_series_exn ~masc_root ~window () in
    Alcotest.(check int) "no calls" 0 series.total.call_count;
    Alcotest.(check bool)
      "reading did not create the database"
      false
      (Sys.file_exists (Tool_metrics_store.database_path ~masc_root)))
;;

let sliding_exn ~span_s ~until ~width ~offset =
  match S.sliding_window ~span_s ~until ~width ~utc_offset_min:offset with
  | Ok window -> window
  | Error error -> Alcotest.failf "sliding window: %s" error
;;

let test_empty_window_deadline_changes_real_bucket_labels () =
  List.iter (fun (width, span_s, offset, origin) ->
    let until = origin +. (span_s /. 2.0) in
    let make until = sliding_exn ~span_s ~until ~width ~offset in
    let window = make until in
    let deadline = S.next_change_at window ~oldest_sample:None ~next_sample:None in
    let initial = series_of window [] in
    let before = series_of (make (Float.pred deadline)) [] in
    let after = series_of (make deadline) [] in
    Alcotest.(check bool) "quiet deadline is in the future" true (deadline > until);
    Alcotest.(check (list (float 0.0))) "no earlier bucket-label change"
      (starts initial) (starts before);
    Alcotest.(check bool) "empty payload bucket labels actually change" true
      (starts initial <> starts after))
    [S.Hour, hour, 0, utc_midnight; S.Day, day, seoul_offset_min, seoul_midnight]
;;

let test_row_expiry_respects_inclusive_lower_bound () =
  let until = utc_midnight +. 1800.0 in
  let ts = until -. hour +. 10.0 in
  let make until = sliding_exn ~span_s:hour ~until ~width:S.Hour ~offset:0 in
  let deadline = S.next_change_at (make until) ~oldest_sample:(Some ts) ~next_sample:None in
  let since_before, _ = S.window_bounds (make (Float.pred deadline)) in
  let since_after, _ = S.window_bounds (make deadline) in
  Alcotest.(check bool) "row still included just before expiry" true (since_before <= ts);
  Alcotest.(check bool) "first expiry passes row timestamp" true (since_after > ts)
;;

let test_snapshot_deadlines_follow_actual_filtered_rows () =
  with_masc_root (fun ~masc_root ->
    let now = utc_midnight +. 1800.0 in
    let old_ts = now -. hour +. 10.0 in
    let future_ts = now +. 7.0 in
    insert_exn ~masc_root ~record_id:"selected-old" ~ts:old_ts ~tool_name:"read"
      ~disposition:"completed" 1.0;
    insert_exn ~masc_root ~record_id:"selected-future" ~ts:future_ts ~tool_name:"read"
      ~disposition:"failed" 2.0;
    insert_exn ~masc_root ~record_id:"other-tool" ~ts:(now +. 1.0) ~tool_name:"write"
      ~disposition:"completed" 3.0;
    let observe until =
      let window = sliding_exn ~span_s:hour ~until ~width:S.Hour ~offset:0 in
      match Tool_metrics_store.observe_series ~masc_root ~window ~tool_name:"read" () with
      | Ok observation -> observation
      | Error error -> Alcotest.failf "observe series: %s" error in
    let initial = observe now in
    Alcotest.(check int) "only admitted selected row" 1 initial.series.total.call_count;
    Alcotest.(check (float 0.0)) "unrelated future row creates no deadline"
      (Float.succ future_ts) initial.next_change_at;
    let admitted = observe initial.next_change_at in
    Alcotest.(check int) "future row enters without a write" 2 admitted.series.total.call_count;
    let before_expiry = observe (Float.pred admitted.next_change_at) in
    Alcotest.(check int) "inclusive cutoff retains row" 2 before_expiry.series.total.call_count;
    let expired = observe admitted.next_change_at in
    Alcotest.(check int) "oldest row expires without a write" 1 expired.series.total.call_count;
    Alcotest.(check int) "remaining failure retained" 1 expired.series.total.failure_count)
;;

let test_missing_store_observation_has_only_bucket_deadline () =
  with_masc_root (fun ~masc_root ->
    let until = utc_midnight +. 1800.0 in
    let window = sliding_exn ~span_s:hour ~until ~width:S.Hour ~offset:0 in
    match Tool_metrics_store.observe_series ~masc_root ~window () with
    | Error error -> Alcotest.failf "missing store: %s" error
    | Ok observed ->
        Alcotest.(check int) "missing store has no samples" 0 observed.series.total.call_count;
        Alcotest.(check (float 0.0)) "only actual bucket-label deadline"
          (S.next_change_at window ~oldest_sample:None ~next_sample:None) observed.next_change_at;
        Alcotest.(check bool) "observation creates no database" false
          (Sys.file_exists (Tool_metrics_store.database_path ~masc_root)))
;;

let () =
  Alcotest.run
    "Tool_metrics_series"
    [ ( "window"
      , [ Alcotest.test_case "rejects what it cannot chart" `Quick test_window_rejects_what_it_cannot_chart
        ; Alcotest.test_case "day buckets follow the viewer's clock" `Quick test_day_buckets_follow_the_viewers_clock
        ; Alcotest.test_case "hour buckets follow a half-hour offset" `Quick test_hour_buckets_follow_a_half_hour_offset
        ; Alcotest.test_case
            "buckets west of UTC start after UTC midnight"
            `Quick
            test_buckets_west_of_utc_start_after_utc_midnight
        ; Alcotest.test_case
            "a window that starts mid-bucket includes that bucket"
            `Quick
            test_a_window_that_starts_mid_bucket_includes_that_bucket
        ] )
    ; ( "series"
      , [ Alcotest.test_case "a bucket with no calls has no latency" `Quick test_a_bucket_with_no_calls_has_no_latency
        ; Alcotest.test_case
            "samples outside the window or with bad durations are refused"
            `Quick
            test_samples_outside_the_window_or_with_bad_durations_are_refused
        ; Alcotest.test_case
            "failed and deferred calls are counted and timed"
            `Quick
            test_failed_and_deferred_calls_are_counted_and_timed
        ; Alcotest.test_case "a call of one minute is long" `Quick test_a_call_of_one_minute_is_long
        ; Alcotest.test_case
            "long calls are counted per bucket and per tool"
            `Quick
            test_long_calls_are_counted_per_bucket_and_per_tool
        ; Alcotest.test_case "percentiles match Tool_metrics" `Quick test_percentiles_match_tool_metrics
        ; Alcotest.test_case "top tools are ordered by time spent" `Quick test_top_tools_are_ordered_by_time_spent
        ; Alcotest.test_case "names parse into closed types" `Quick test_names_parse_into_closed_types
        ; Alcotest.test_case
            "json carries null for a bucket with no calls"
            `Quick
            test_json_carries_null_for_a_bucket_with_no_calls
        ; Alcotest.test_case
            "json counts long calls in every row and names the line"
            `Quick
            test_json_counts_long_calls_in_every_row_and_names_the_line
        ; Alcotest.test_case
            "result sizes are summed where they are known"
            `Quick
            test_result_sizes_are_summed_where_they_are_known
        ; Alcotest.test_case "a negative result size is refused" `Quick test_a_negative_result_size_is_refused
        ; Alcotest.test_case
            "json carries result sizes and null for unsized buckets"
            `Quick
            test_json_carries_result_sizes_and_null_for_unsized_buckets
        ] )
    ; ( "store"
      , [ Alcotest.test_case "read_series groups the stored calls" `Quick test_read_series_groups_the_stored_calls
        ; Alcotest.test_case "read_series counts the stored long calls" `Quick test_read_series_counts_the_stored_long_calls
        ; Alcotest.test_case
            "read_series sums stored sizes and leaves old rows unsized"
            `Quick
            test_read_series_sums_stored_sizes_and_leaves_old_rows_unsized
        ; Alcotest.test_case
            "insert keeps the first size of a record id"
            `Quick
            test_insert_keeps_the_first_size_of_a_record_id
        ; Alcotest.test_case "insert refuses a negative size" `Quick test_insert_refuses_a_negative_size
        ; Alcotest.test_case
            "read_series without a database is empty and creates none"
            `Quick
            test_read_series_without_a_database_is_empty_and_creates_none
        ; Alcotest.test_case "deadline follows actual filtered rows without new writes" `Quick
            test_snapshot_deadlines_follow_actual_filtered_rows
        ; Alcotest.test_case "missing store has only a bucket deadline" `Quick
            test_missing_store_observation_has_only_bucket_deadline
        ] )
    ; ( "quiet deadlines"
      , [ Alcotest.test_case "empty hour/day windows change emitted bucket labels" `Quick
            test_empty_window_deadline_changes_real_bucket_labels
        ; Alcotest.test_case "expiry preserves inclusive lower bound" `Quick
            test_row_expiry_respects_inclusive_lower_bound ] )
    ]
;;
