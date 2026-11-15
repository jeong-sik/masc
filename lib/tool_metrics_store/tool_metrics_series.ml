type disposition =
  | Completed
  | Deferred
  | Failed

let disposition_of_string = function
  | "completed" -> Ok Completed
  | "deferred" -> Ok Deferred
  | "failed" -> Ok Failed
  | other -> Error ("unknown tool metric disposition: " ^ other)
;;

type width =
  | Hour
  | Day

let width_of_string = function
  | "hour" -> Ok Hour
  | "day" -> Ok Day
  | other -> Error (Printf.sprintf "bucket must be hour or day, got %s" other)
;;

let string_of_width = function
  | Hour -> "hour"
  | Day -> "day"
;;

let seconds_per_minute = Float.to_int Masc_time_constants.minute

let seconds_of_width = function
  | Hour -> Float.to_int Masc_time_constants.hour
  | Day -> Float.to_int Masc_time_constants.day
;;

let minutes_per_hour = 60
let max_window_days = 31
let max_window_s = Float.of_int max_window_days *. Masc_time_constants.day
let max_utc_offset_hours = 14
let max_utc_offset_min = max_utc_offset_hours * minutes_per_hour

(* Timestamps are turned into whole seconds with [Float.to_int]. Past this
   bound the conversion stops being exact, so no window may reach it. *)
let max_timestamp_s = 1e12
let top_tool_limit = 20
let top_caller_limit = 20
let median = 0.50
let tail = 0.95
let milliseconds_per_second = 1000.0

(* A call that ran this long or longer is a long call. One minute is the line
   of the Execute wait census (docs/evidence/execute-waits-2026-11). *)
let long_call_threshold_ms = Masc_time_constants.minute *. milliseconds_per_second

type window =
  { since : float
  ; until : float
  ; span_s : float
  ; width : width
  ; utc_offset_s : int
  ; first_index : int
  ; bucket_count : int
  }

(* [numerator / denominator] rounded toward negative infinity. [denominator] is
   positive. *)
let floor_div numerator denominator =
  let quotient = numerator / denominator in
  if numerator mod denominator < 0 then quotient - 1 else quotient
;;

(* The number of the bucket that holds [ts] when every bucket is
   [width_s] seconds wide and the clock runs [utc_offset_s] ahead of UTC. *)
let bucket_index ~width_s ~utc_offset_s ts =
  floor_div (Float.to_int (Float.floor ts) + utc_offset_s) width_s
;;

let window ~since ~until ~width ~utc_offset_min =
  if not (Float.is_finite since && Float.is_finite until)
  then Error "window bounds must be finite numbers"
  else if since < 0.0 || until > max_timestamp_s
  then Error "window bounds are outside the supported timestamp range"
  else if until <= since
  then Error "window must end after it starts"
  else if until -. since > max_window_s
  then Error (Printf.sprintf "window is longer than %d days" max_window_days)
  else if abs utc_offset_min > max_utc_offset_min
  then Error (Printf.sprintf "utc offset is beyond %d hours" max_utc_offset_hours)
  else (
    let width_s = seconds_of_width width in
    let utc_offset_s = utc_offset_min * seconds_per_minute in
    let first_index = bucket_index ~width_s ~utc_offset_s since in
    (* [until] is excluded, so the last bucket is the one of the float just
       below it. *)
    let last_index = bucket_index ~width_s ~utc_offset_s (Float.pred until) in
    Ok
      { since
      ; until
      ; span_s = until -. since
      ; width
      ; utc_offset_s
      ; first_index
      ; bucket_count = last_index - first_index + 1
      })
;;

let window_bounds window = window.since, window.until

let sliding_window ~span_s ~until ~width ~utc_offset_min =
  Result.map (fun window -> { window with span_s })
    (window ~since:(until -. span_s) ~until ~width ~utc_offset_min)
;;

let next_change_at window ~oldest_sample ~next_sample =
  let span = window.span_s in
  let width_s = seconds_of_width window.width in
  let edge index = Float.of_int ((index * width_s) - window.utc_offset_s) in
  (* Rounding the sum and subtracting the span can leave the original
     timestamp on the included side. Advance in representable epoch values,
     rather than guessing an epsilon that changes with the clock's scale. *)
  let rec first_at ~crosses at =
    if at > window.until && crosses (at -. span) then at
    else first_at ~crosses (Float.succ at)
  in
  let left_edge = edge (window.first_index + 1) in
  let left_change = first_at ~crosses:(fun since -> since >= left_edge)
      (left_edge +. span) in
  let right_change = Float.succ (edge (window.first_index + window.bucket_count)) in
  let deadline = min left_change right_change in
  let deadline = match oldest_sample with
    | None -> deadline
    | Some ts -> min deadline (first_at ~crosses:(fun since -> since > ts) (ts +. span)) in
  match next_sample with
  | None -> deadline
  | Some ts -> min deadline (Float.succ ts)
;;

type sample =
  { ts : float
  ; tool_name : string
  ; disposition : disposition
  ; duration_ms : float
  ; result_bytes : int option
  ; failure_class : Tool_result.tool_failure_class option
  ; caller : string option
  }

(* Durations of one set of calls, kept in a flat float array that doubles when
   it is full. *)
module Durations = struct
  type t =
    { mutable data : Float.Array.t
    ; mutable length : int
    }

  let initial_capacity = 16
  let create () = { data = Float.Array.make initial_capacity 0.0; length = 0 }

  let add durations value =
    if durations.length = Float.Array.length durations.data
    then (
      let grown = Float.Array.make (2 * durations.length) 0.0 in
      Float.Array.blit durations.data 0 grown 0 durations.length;
      durations.data <- grown);
    Float.Array.set durations.data durations.length value;
    durations.length <- durations.length + 1
  ;;

  let sorted durations =
    let copy = Float.Array.sub durations.data 0 durations.length in
    Float.Array.sort Float.compare copy;
    copy
  ;;
end

(* The sample at rank [round ((n - 1) * p)], the rule of [Tool_metrics]. *)
let percentile sorted p =
  let count = Float.Array.length sorted in
  if count = 0
  then None
  else (
    let rank = Float.to_int (Float.round (Float.of_int (count - 1) *. p)) in
    Some (Float.Array.get sorted (max 0 (min (count - 1) rank))))
;;

type failure_class_counts =
  { dependency_unavailable : int
  ; policy_rejection : int
  ; runtime_failure : int
  ; workflow_rejection : int
  ; operator_cancelled : int
  }

let no_failure_classes =
  { dependency_unavailable = 0
  ; policy_rejection = 0
  ; runtime_failure = 0
  ; workflow_rejection = 0
  ; operator_cancelled = 0
  }
;;

(* One constructor, one counter: a new [Tool_result.tool_failure_class] stops
   this match from compiling until it has a counter. *)
let count_failure_class counts (failure_class : Tool_result.tool_failure_class) =
  match failure_class with
  | Tool_result.Dependency_unavailable ->
    { counts with dependency_unavailable = counts.dependency_unavailable + 1 }
  | Tool_result.Policy_rejection ->
    { counts with policy_rejection = counts.policy_rejection + 1 }
  | Tool_result.Runtime_failure ->
    { counts with runtime_failure = counts.runtime_failure + 1 }
  | Tool_result.Workflow_rejection ->
    { counts with workflow_rejection = counts.workflow_rejection + 1 }
  | Tool_result.Operator_cancelled ->
    { counts with operator_cancelled = counts.operator_cancelled + 1 }
;;

type stat =
  { call_count : int
  ; failure_count : int
  ; failure_classes : failure_class_counts
  ; failure_unclassified_count : int
  ; deferred_count : int
  ; total_ms : float
  ; p50_ms : float option
  ; p95_ms : float option
  ; max_ms : float option
  ; long_count : int
  ; long_total_ms : float
  ; result_observed_count : int
  ; result_bytes_total : int
  ; result_bytes_max : int option
  }

type accumulator =
  { mutable calls : int
  ; mutable failed : int
  ; mutable failed_classes : failure_class_counts
  ; mutable failed_unclassified : int
  ; mutable deferred : int
  ; mutable sum_ms : float
  ; mutable peak_ms : float
  ; mutable long_calls : int
  ; mutable long_sum_ms : float
  ; mutable sized_calls : int
  ; mutable sum_bytes : int
  ; mutable peak_bytes : int
  ; durations : Durations.t
  }

let new_accumulator () =
  { calls = 0
  ; failed = 0
  ; failed_classes = no_failure_classes
  ; failed_unclassified = 0
  ; deferred = 0
  ; sum_ms = 0.0
  ; peak_ms = 0.0
  ; long_calls = 0
  ; long_sum_ms = 0.0
  ; sized_calls = 0
  ; sum_bytes = 0
  ; peak_bytes = 0
  ; durations = Durations.create ()
  }
;;

let record accumulator (sample : sample) =
  accumulator.calls <- accumulator.calls + 1;
  (match sample.disposition with
   | Completed -> ()
   | Deferred -> accumulator.deferred <- accumulator.deferred + 1
   | Failed ->
     accumulator.failed <- accumulator.failed + 1;
     (match sample.failure_class with
      | None -> accumulator.failed_unclassified <- accumulator.failed_unclassified + 1
      | Some failure_class ->
        accumulator.failed_classes
        <- count_failure_class accumulator.failed_classes failure_class));
  accumulator.sum_ms <- accumulator.sum_ms +. sample.duration_ms;
  if sample.duration_ms > accumulator.peak_ms
  then accumulator.peak_ms <- sample.duration_ms;
  if sample.duration_ms >= long_call_threshold_ms
  then (
    accumulator.long_calls <- accumulator.long_calls + 1;
    accumulator.long_sum_ms <- accumulator.long_sum_ms +. sample.duration_ms);
  (match sample.result_bytes with
   | None -> ()
   | Some bytes ->
     accumulator.sized_calls <- accumulator.sized_calls + 1;
     accumulator.sum_bytes <- accumulator.sum_bytes + bytes;
     if bytes > accumulator.peak_bytes then accumulator.peak_bytes <- bytes);
  Durations.add accumulator.durations sample.duration_ms
;;

let empty_stat =
  { call_count = 0
  ; failure_count = 0
  ; failure_classes = no_failure_classes
  ; failure_unclassified_count = 0
  ; deferred_count = 0
  ; total_ms = 0.0
  ; p50_ms = None
  ; p95_ms = None
  ; max_ms = None
  ; long_count = 0
  ; long_total_ms = 0.0
  ; result_observed_count = 0
  ; result_bytes_total = 0
  ; result_bytes_max = None
  }
;;

let stat_of_accumulator accumulator =
  if accumulator.calls = 0
  then empty_stat
  else (
    let sorted = Durations.sorted accumulator.durations in
    { call_count = accumulator.calls
    ; failure_count = accumulator.failed
    ; failure_classes = accumulator.failed_classes
    ; failure_unclassified_count = accumulator.failed_unclassified
    ; deferred_count = accumulator.deferred
    ; total_ms = accumulator.sum_ms
    ; p50_ms = percentile sorted median
    ; p95_ms = percentile sorted tail
    ; max_ms = Some accumulator.peak_ms
    ; long_count = accumulator.long_calls
    ; long_total_ms = accumulator.long_sum_ms
    ; result_observed_count = accumulator.sized_calls
    ; result_bytes_total = accumulator.sum_bytes
    ; result_bytes_max =
        (if accumulator.sized_calls = 0 then None else Some accumulator.peak_bytes)
    })
;;

type builder =
  { shape : window
  ; slots : accumulator array
  ; per_tool : (string, accumulator) Hashtbl.t
  ; per_caller : (string, accumulator) Hashtbl.t
  ; overall : accumulator
  }

let builder shape =
  { shape
  ; slots = Array.init shape.bucket_count (fun _ -> new_accumulator ())
  ; per_tool = Hashtbl.create 64
  ; per_caller = Hashtbl.create 16
  ; overall = new_accumulator ()
  }
;;

let accumulator_of table name =
  match Hashtbl.find_opt table name with
  | Some accumulator -> accumulator
  | None ->
    let accumulator = new_accumulator () in
    Hashtbl.replace table name accumulator;
    accumulator
;;

let negative_size (sample : sample) =
  match sample.result_bytes with
  | Some bytes -> bytes < 0
  | None -> false
;;

(* A class names why a call failed, so only a failed call has one. *)
let classed_without_failing (sample : sample) =
  match sample.disposition, sample.failure_class with
  | (Completed | Deferred), Some _ -> true
  | (Completed | Deferred), None | Failed, (Some _ | None) -> false
;;

let add builder (sample : sample) =
  let shape = builder.shape in
  if not (Float.is_finite sample.duration_ms) || sample.duration_ms < 0.0
  then
    Error
      (Printf.sprintf
         "tool %s has an invalid duration of %g ms"
         sample.tool_name
         sample.duration_ms)
  else if negative_size sample
  then
    Error
      (Printf.sprintf
         "tool %s has a negative result size of %d bytes"
         sample.tool_name
         (Option.value sample.result_bytes ~default:0))
  else if classed_without_failing sample
  then
    Error
      (Printf.sprintf
         "tool %s carries a failure class but did not fail"
         sample.tool_name)
  else if (not (Float.is_finite sample.ts))
          || sample.ts < shape.since
          || sample.ts >= shape.until
  then
    Error
      (Printf.sprintf
         "tool %s has a timestamp of %g, outside the window"
         sample.tool_name
         sample.ts)
  else (
    let slot =
      bucket_index
        ~width_s:(seconds_of_width shape.width)
        ~utc_offset_s:shape.utc_offset_s
        sample.ts
      - shape.first_index
    in
    record builder.slots.(slot) sample;
    record builder.overall sample;
    record (accumulator_of builder.per_tool sample.tool_name) sample;
    Option.iter
      (fun caller -> record (accumulator_of builder.per_caller caller) sample)
      sample.caller;
    Ok ())
;;

type bucket =
  { start : float
  ; summary : stat
  }

type tool_usage =
  { name : string
  ; usage : stat
  }

type caller_usage =
  { caller : string
  ; usage : stat
  }

type t =
  { window : window
  ; buckets : bucket list
  ; total : stat
  ; top_by_time : tool_usage list
  ; by_caller : caller_usage list
  ; caller_unobserved_count : int
  }

let finish builder =
  let shape = builder.shape in
  let width_s = seconds_of_width shape.width in
  let buckets =
    List.init shape.bucket_count (fun slot ->
      { start = Float.of_int (((shape.first_index + slot) * width_s) - shape.utc_offset_s)
      ; summary = stat_of_accumulator builder.slots.(slot)
      })
  in
  let longest_first (name_a, (a : accumulator)) (name_b, (b : accumulator)) =
    match Float.compare b.sum_ms a.sum_ms with
    | 0 -> String.compare name_a name_b
    | order -> order
  in
  let top_by_time =
    Hashtbl.fold (fun name accumulator rows -> (name, accumulator) :: rows) builder.per_tool []
    |> List.sort longest_first
    |> List.take top_tool_limit
    |> List.map (fun (name, accumulator) ->
      { name; usage = stat_of_accumulator accumulator })
  in
  let most_failures_first (name_a, (a : accumulator)) (name_b, (b : accumulator)) =
    match Int.compare b.failed a.failed with
    | 0 ->
      (match Int.compare b.calls a.calls with
       | 0 -> String.compare name_a name_b
       | order -> order)
    | order -> order
  in
  let callers =
    Hashtbl.fold (fun name accumulator rows -> (name, accumulator) :: rows) builder.per_caller []
  in
  let caller_observed_count =
    List.fold_left (fun sum (_, (accumulator : accumulator)) -> sum + accumulator.calls) 0 callers
  in
  let by_caller =
    callers
    |> List.sort most_failures_first
    |> List.take top_caller_limit
    |> List.map (fun (caller, accumulator) ->
      { caller; usage = stat_of_accumulator accumulator })
  in
  { window = shape
  ; buckets
  ; total = stat_of_accumulator builder.overall
  ; top_by_time
  ; by_caller
  ; caller_unobserved_count = builder.overall.calls - caller_observed_count
  }
;;

let float_or_null = function
  | None -> `Null
  | Some value -> `Float value
;;

let int_or_null = function
  | None -> `Null
  | Some value -> `Int value
;;

(* The keys are the spellings [Tool_result] gives each class, so the series
   and the keeper tool-call log name a class the same way. *)
let failure_classes_json (counts : failure_class_counts) : Yojson.Safe.t =
  let key = Tool_result.tool_failure_class_to_string in
  `Assoc
    [ key Tool_result.Dependency_unavailable, `Int counts.dependency_unavailable
    ; key Tool_result.Policy_rejection, `Int counts.policy_rejection
    ; key Tool_result.Runtime_failure, `Int counts.runtime_failure
    ; key Tool_result.Workflow_rejection, `Int counts.workflow_rejection
    ; key Tool_result.Operator_cancelled, `Int counts.operator_cancelled
    ]
;;

let stat_fields stat : (string * Yojson.Safe.t) list =
  [ "call_count", `Int stat.call_count
  ; "failure_count", `Int stat.failure_count
  ; "failure_classes", failure_classes_json stat.failure_classes
  ; "failure_unclassified_count", `Int stat.failure_unclassified_count
  ; "deferred_count", `Int stat.deferred_count
  ; "total_ms", `Float stat.total_ms
  ; "p50_ms", float_or_null stat.p50_ms
  ; "p95_ms", float_or_null stat.p95_ms
  ; "max_ms", float_or_null stat.max_ms
  ; "long_count", `Int stat.long_count
  ; "long_total_ms", `Float stat.long_total_ms
  ; "result_observed_count", `Int stat.result_observed_count
  ; "result_bytes_total", `Int stat.result_bytes_total
  ; "result_bytes_max", int_or_null stat.result_bytes_max
  ]
;;

let to_json ~generated_at ?tool_name ?(public_names = fun _ -> []) series
  : Yojson.Safe.t
  =
  let window = series.window in
  let bucket_json (bucket : bucket) =
    `Assoc (("start", `Float bucket.start) :: stat_fields bucket.summary)
  in
  let tool_json (tool : tool_usage) =
    `Assoc
      (("name", `String tool.name)
       :: ( "public_names"
          , `List (List.map (fun name -> `String name) (public_names tool.name)) )
       :: stat_fields tool.usage)
  in
  let caller_json (row : caller_usage) =
    `Assoc (("caller", `String row.caller) :: stat_fields row.usage)
  in
  `Assoc
    [ "generated_at", `Float generated_at
    ; ( "source"
      , `Assoc [ "kind", `String "tool_metrics"; "persistence", `String "sqlite" ] )
    ; ( "window"
      , `Assoc
          [ "since", `Float window.since
          ; "until", `Float window.until
          ; "bucket", `String (string_of_width window.width)
          ; "bucket_seconds", `Int (seconds_of_width window.width)
          ; "utc_offset_min", `Int (window.utc_offset_s / seconds_per_minute)
          ] )
    ; ( "tool"
      , match tool_name with
        | None -> `Null
        | Some name -> `String name )
    ; "long_call_ms", `Float long_call_threshold_ms
    ; "total", `Assoc (stat_fields series.total)
    ; "buckets", `List (List.map bucket_json series.buckets)
    ; "top_by_time", `List (List.map tool_json series.top_by_time)
    ; "by_caller", `List (List.map caller_json series.by_caller)
    ; "caller_unobserved_count", `Int series.caller_unobserved_count
    ]
;;
