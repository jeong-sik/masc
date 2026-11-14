(** Decoder tests for the [/api/v1/tool-metrics/series] answer that the Usage
    view's Calls section draws. The first cases feed the decoder what the
    server's own [Tool_metrics_series.to_json] writes, so the two cannot drift
    apart. The rest pin what the decoder refuses: an answer that does not
    follow the series contract is an error, never a shorter or a flatter chart. *)

open Alcotest

module D = Masc.Tui_decode_tool_series
module S = Tool_metrics_series

let hour = 3600.0
let day = 86400.0

(* 2026-11-04 00:00:00 UTC *)
let utc_midnight = 1793750400.0

(* 2026-11-05 00:00:00 in Seoul, which is 2026-11-04 15:00:00 UTC. *)
let seoul_midnight = 1793804400.0
let seoul_offset_min = 540

(* A window ends one second before a bucket edge, so its last bucket is the one
   that holds the second before [until] whichever way an edge is counted. *)
let daily_until = seoul_midnight +. (2.0 *. 86400.0) -. 1.0

let sample ?(disposition = S.Completed) ~ts duration_ms : S.sample =
  { ts; tool_name = "tool_read_file"; disposition; duration_ms; result_bytes = None; failure_class = None; caller = None }
;;

let series_json ~width ~offset ~since ~until samples =
  let window =
    match S.window ~since ~until ~width ~utc_offset_min:offset with
    | Ok window -> window
    | Error error -> Alcotest.failf "window: %s" error
  in
  let builder = S.builder window in
  List.iter
    (fun sample ->
       match S.add builder sample with
       | Ok () -> ()
       | Error error -> Alcotest.failf "add: %s" error)
    samples;
  S.to_json ~generated_at:until (S.finish builder)
;;

(* Hour 0 ran two calls, one of which failed; hour 1 ran none; hour 2 ran one
   call that was deferred. *)
let hourly_json =
  series_json
    ~width:S.Hour
    ~offset:0
    ~since:utc_midnight
    ~until:(utc_midnight +. (3.0 *. hour) -. 1.0)
    [ sample ~ts:(utc_midnight +. 10.0) 10.0
    ; sample ~disposition:S.Failed ~ts:(utc_midnight +. 20.0) 30.0
    ; sample ~disposition:S.Deferred ~ts:(utc_midnight +. (2.0 *. hour) +. 5.0) 7.0
    ]
;;

let decode_ok json =
  match D.decode_tool_series json with
  | Ok series -> series
  | Error reason -> Alcotest.failf "the server's own series was refused: %s" reason
;;

let activity_testable =
  let pp formatter = function
    | D.Series_idle -> Format.pp_print_string formatter "idle"
    | D.Series_active calls ->
      Format.fprintf
        formatter
        "active calls=%d failures=%d deferred=%d p95=%g"
        calls.D.tsc_calls
        calls.D.tsc_failures
        calls.D.tsc_deferred
        calls.D.tsc_p95_ms
  in
  testable pp ( = )
;;

let test_hourly_series_keeps_counts_and_idle_buckets () =
  let series = decode_ok hourly_json in
  check bool "hour width" true (series.D.tsr_width = D.Series_hour);
  check int "offset" 0 series.D.tsr_utc_offset_min;
  check
    (list (float 0.0))
    "starts"
    [ utc_midnight; utc_midnight +. hour; utc_midnight +. (2.0 *. hour) ]
    (List.map (fun (bucket : D.tool_series_bucket) -> bucket.D.tsb_start) series.D.tsr_buckets);
  check
    (list activity_testable)
    "activity"
    [ D.Series_active
        { D.tsc_calls = 2; tsc_failures = 1; tsc_deferred = 0; tsc_p95_ms = 30.0 }
    ; D.Series_idle
    ; D.Series_active
        { D.tsc_calls = 1; tsc_failures = 0; tsc_deferred = 1; tsc_p95_ms = 7.0 }
    ]
    (List.map (fun (bucket : D.tool_series_bucket) -> bucket.D.tsb_activity) series.D.tsr_buckets)
;;

let test_daily_series_follows_the_viewer_offset () =
  let series =
    decode_ok
      (series_json
         ~width:S.Day
         ~offset:seoul_offset_min
         ~since:seoul_midnight
         ~until:daily_until
         [ sample ~ts:(seoul_midnight +. 60.0) 5.0
         ; sample ~ts:(seoul_midnight +. day +. 60.0) 9.0
         ])
  in
  check bool "day width" true (series.D.tsr_width = D.Series_day);
  check int "offset" seoul_offset_min series.D.tsr_utc_offset_min;
  check
    (list (float 0.0))
    "starts"
    [ seoul_midnight; seoul_midnight +. day ]
    (List.map (fun (bucket : D.tool_series_bucket) -> bucket.D.tsb_start) series.D.tsr_buckets);
  check (float 0.0) "generated_at is the window's end" daily_until series.D.tsr_generated_at
;;

let rec edit path value json =
  match path, json with
  | [], _ -> value
  | key :: rest, `Assoc fields ->
    `Assoc
      (List.map
         (fun (name, member) ->
            if String.equal name key then name, edit rest value member else name, member)
         fields)
  | _ :: _, other -> other
;;

let edit_buckets change json =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (name, member) ->
            match name, member with
            | "buckets", `List items -> name, `List (change items)
            | _ -> name, member)
         fields)
  | other -> other
;;

let edit_bucket index key value =
  edit_buckets (List.mapi (fun at item -> if at = index then edit [ key ] value item else item))
;;

let drop_bucket index = edit_buckets (List.filteri (fun at _ -> at <> index))

let remove_member key = function
  | `Assoc fields -> `Assoc (List.filter (fun (name, _) -> not (String.equal name key)) fields)
  | other -> other
;;

let test_series_that_break_the_contract_are_refused () =
  List.iter
    (fun (label, json) ->
       check bool label true (Result.is_error (D.decode_tool_series json)))
    [ "a bucket width the server does not announce"
    , edit [ "window"; "bucket" ] (`String "week") hourly_json
    ; "a step that is not the width's"
    , edit [ "window"; "bucket_seconds" ] (`Int 60) hourly_json
    ; "a bucket missing from the middle", drop_bucket 1 hourly_json
    ; "calls with no p95", edit_bucket 0 "p95_ms" `Null hourly_json
    ; "an idle bucket with a p95", edit_bucket 1 "p95_ms" (`Float 1.0) hourly_json
    ; "an idle bucket that counts a failure", edit_bucket 1 "failure_count" (`Int 1) hourly_json
    ; "more failures than calls", edit_bucket 0 "failure_count" (`Int 5) hourly_json
    ; "a negative p95", edit_bucket 0 "p95_ms" (`Float (-1.0)) hourly_json
    ; "a p95 that is not a number", edit_bucket 0 "p95_ms" (`Float Float.nan) hourly_json
    ; "a negative count", edit_bucket 0 "call_count" (`Int (-2)) hourly_json
    ; "no buckets", edit [ "buckets" ] (`List []) hourly_json
    ; "no generated_at", remove_member "generated_at" hourly_json
    ; "no window", remove_member "window" hourly_json
    ]
;;

(* A request names the bucket with this word and the answer repeats it in
   [window.bucket]. The server must read the word back as the width the decoder
   then expects, or a Calls read would be refused whatever the data said. *)
let test_the_request_names_a_width_the_server_reads () =
  List.iter
    (fun (decoded, served) ->
       let word = D.series_width_name decoded in
       match S.width_of_string word with
       | Ok width ->
         check bool (word ^ " is the same width") true (width = served);
         check string (word ^ " is the word the server writes") word (S.string_of_width served)
       | Error reason -> Alcotest.failf "the server refuses '%s': %s" word reason)
    [ D.Series_hour, S.Hour; D.Series_day, S.Day ]
;;

let () =
  run
    "Tui_decode_tool_series"
    [ ( "decode"
      , [ test_case "the request names a width the server reads" `Quick
            test_the_request_names_a_width_the_server_reads
        ; test_case "hourly series keeps counts and idle buckets" `Quick
            test_hourly_series_keeps_counts_and_idle_buckets
        ; test_case "daily series follows the viewer offset" `Quick
            test_daily_series_follows_the_viewer_offset
        ; test_case "series that break the contract are refused" `Quick
            test_series_that_break_the_contract_are_refused
        ] )
    ]
;;
