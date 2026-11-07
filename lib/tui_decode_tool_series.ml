open Tui_decode_fields

open Result.Syntax

type tool_series_width =
  | Series_hour
  | Series_day

let series_width_seconds = function
  | Series_hour -> 3_600
  | Series_day -> 86_400

type tool_series_calls = {
  tsc_calls : int;
  tsc_failures : int;
  tsc_deferred : int;
  tsc_p95_ms : float;
}

type tool_series_activity =
  | Series_idle
  | Series_active of tool_series_calls

type tool_series_bucket = {
  tsb_start : float;
  tsb_activity : tool_series_activity;
}

type tool_series = {
  tsr_generated_at : float;
  tsr_width : tool_series_width;
  tsr_utc_offset_min : int;
  tsr_buckets : tool_series_bucket list;
}

let series_width_name = function
  | Series_hour -> "hour"
  | Series_day -> "day"

let width_of_string = function
  | "hour" -> Ok Series_hour
  | "day" -> Ok Series_day
  | other -> Error (Printf.sprintf "unknown series bucket width '%s'" other)

let finite_float key value =
  if Float.is_finite value then Ok value
  else Error (Printf.sprintf "field '%s' must be finite" key)

let required_finite_float json key =
  match required_nullable_float_field json key with
  | Error reason -> Error reason
  | Ok None -> Error (Printf.sprintf "field '%s' must not be null" key)
  | Ok (Some value) -> finite_float key value

(* The server leaves p95 out of a bucket that ran no call, because there is no
   call to take it from. The four combinations are read as exactly that rule:
   a count of calls and a p95 that disagree about whether the bucket was idle
   have no meaning. *)
let decode_activity json =
  let* calls = required_nonnegative_int_field json "call_count" in
  let* failures = required_nonnegative_int_field json "failure_count" in
  let* deferred = required_nonnegative_int_field json "deferred_count" in
  let* p95 = required_nullable_float_field json "p95_ms" in
  match calls, p95 with
  | 0, None ->
      if failures = 0 && deferred = 0 then Ok Series_idle
      else Error "a bucket with no call counts failed or deferred calls"
  | 0, Some _ -> Error "a bucket with no call carries a p95"
  | _, None -> Error "a bucket with calls carries no p95"
  | _, Some p95_ms ->
      let* p95_ms = finite_float "p95_ms" p95_ms in
      if p95_ms < 0.0 then Error "field 'p95_ms' must be non-negative"
      else if failures + deferred > calls then
        Error "a bucket counts more failed and deferred calls than calls"
      else
        Ok
          (Series_active
             { tsc_calls = calls
             ; tsc_failures = failures
             ; tsc_deferred = deferred
             ; tsc_p95_ms = p95_ms
             })

let decode_bucket json =
  let* start = required_finite_float json "start" in
  let* activity = decode_activity json in
  Ok { tsb_start = start; tsb_activity = activity }

(* Buckets are read in order, so the step to the next one is checked against the
   previous start and a gap names where it opens. *)
let rec check_steps ~step = function
  | [] | [ _ ] -> Ok ()
  | first :: (second :: _ as rest) ->
      if Float.equal (second.tsb_start -. first.tsb_start) step then
        check_steps ~step rest
      else
        Error
          (Printf.sprintf
             "buckets are not one step apart: %.0f is followed by %.0f"
             first.tsb_start second.tsb_start)

let decode_tool_series json =
  let* generated_at = required_finite_float json "generated_at" in
  let* window = required_object_field json "window" in
  let* width_text = required_string_field window "bucket" in
  let* width = width_of_string width_text in
  let* bucket_seconds = required_int_field window "bucket_seconds" in
  let* () =
    if bucket_seconds = series_width_seconds width then Ok ()
    else
      Error
        (Printf.sprintf "bucket_seconds %d is not the step of a %s bucket"
           bucket_seconds width_text)
  in
  let* utc_offset_min = required_int_field window "utc_offset_min" in
  let* items = required_list_field json "buckets" in
  let* buckets = decode_list "buckets" decode_bucket items in
  let* () =
    check_steps ~step:(float_of_int (series_width_seconds width)) buckets
  in
  match buckets with
  | [] -> Error "the series has no bucket"
  | _ :: _ ->
      Ok
        { tsr_generated_at = generated_at
        ; tsr_width = width
        ; tsr_utc_offset_min = utc_offset_min
        ; tsr_buckets = buckets
        }
