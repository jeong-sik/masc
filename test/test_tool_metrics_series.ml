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
  { ts; tool_name = tool; disposition; duration_ms }
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

let insert_exn ~masc_root ~record_id ~ts ~tool_name ~disposition duration_ms =
  match
    Tool_metrics_store.insert
      ~masc_root
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
        ; Alcotest.test_case "percentiles match Tool_metrics" `Quick test_percentiles_match_tool_metrics
        ; Alcotest.test_case "top tools are ordered by time spent" `Quick test_top_tools_are_ordered_by_time_spent
        ; Alcotest.test_case "names parse into closed types" `Quick test_names_parse_into_closed_types
        ; Alcotest.test_case
            "json carries null for a bucket with no calls"
            `Quick
            test_json_carries_null_for_a_bucket_with_no_calls
        ] )
    ; ( "store"
      , [ Alcotest.test_case "read_series groups the stored calls" `Quick test_read_series_groups_the_stored_calls
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
