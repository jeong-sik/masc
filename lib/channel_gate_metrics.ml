(** Channel_gate_metrics -- per-channel connector diagnostics.
    See [channel_gate_metrics.mli]. *)

type outcome =
  | Success
  | Duplicate
  | Validation_error of string
  | Keeper_error of string
  | Dispatch_unavailable
  | Internal_error of string

type channel_stats = {
  channel : string;
  message_count : int;
  success_count : int;
  error_count : int;
  duplicate_count : int;
  validation_error_count : int;
  keeper_error_count : int;
  dispatch_unavailable_count : int;
  internal_error_count : int;
  last_activity_ts : float;
  last_success_ts : float;
  last_error_ts : float;
  last_keeper : string;
  last_room_id : string;
  last_error : string;
  last_error_kind : string;
  last_outcome : string;
  total_duration_ms : int;
  timed_count : int;
  max_duration_ms : int;
  slow_count : int;
  room_count : int;
}

type stats_acc = {
  mutable msg_count : int;
  mutable success_count : int;
  mutable err_count : int;
  mutable duplicate_count : int;
  mutable validation_error_count : int;
  mutable keeper_error_count : int;
  mutable dispatch_unavailable_count : int;
  mutable internal_error_count : int;
  mutable last_ts : float;
  mutable last_success_ts : float;
  mutable last_error_ts : float;
  mutable last_keeper : string;
  mutable last_room_id : string;
  mutable last_error : string;
  mutable last_error_kind : string;
  mutable last_outcome : string;
  mutable total_dur_ms : int;
  mutable timed_count : int;
  mutable max_dur_ms : int;
  mutable slow_count : int;
  rooms : (string, unit) Hashtbl.t;
}

let slow_threshold_ms () =
  match Sys.getenv_opt "MASC_CHANNEL_GATE_SLOW_MS" with
  | Some s -> (try max 250 (min 120_000 (int_of_string (String.trim s))) with _ -> 10_000)
  | None -> 10_000

let make_acc () =
  {
    msg_count = 0;
    success_count = 0;
    err_count = 0;
    duplicate_count = 0;
    validation_error_count = 0;
    keeper_error_count = 0;
    dispatch_unavailable_count = 0;
    internal_error_count = 0;
    last_ts = 0.0;
    last_success_ts = 0.0;
    last_error_ts = 0.0;
    last_keeper = "";
    last_room_id = "";
    last_error = "";
    last_error_kind = "";
    last_outcome = "idle";
    total_dur_ms = 0;
    timed_count = 0;
    max_dur_ms = 0;
    slow_count = 0;
    rooms = Hashtbl.create 8;
  }

let table : (string, stats_acc) Hashtbl.t = Hashtbl.create 16
let mu = Eio.Mutex.create ()
let start_time = Unix.gettimeofday ()

let dedup_size_fn : (unit -> int) ref = ref (fun () -> 0)

let register_dedup_size_fn f = dedup_size_fn := f
let dedup_table_size () = !dedup_size_fn ()

let get_or_create_acc channel =
  match Hashtbl.find_opt table channel with
  | Some acc -> acc
  | None ->
      let acc = make_acc () in
      Hashtbl.replace table channel acc;
      acc

let outcome_name = function
  | Success -> "success"
  | Duplicate -> "duplicate"
  | Validation_error _ -> "validation_error"
  | Keeper_error _ -> "keeper_error"
  | Dispatch_unavailable -> "dispatch_unavailable"
  | Internal_error _ -> "internal_error"

let update_error_fields acc ~now ~kind ~message =
  acc.err_count <- acc.err_count + 1;
  acc.last_error_ts <- now;
  acc.last_error_kind <- kind;
  acc.last_error <- message

let record_attempt ~channel ~room_id ~keeper ~duration_ms outcome =
  Eio_guard.with_mutex mu (fun () ->
      let acc = get_or_create_acc channel in
      let now = Unix.gettimeofday () in
      acc.msg_count <- acc.msg_count + 1;
      acc.last_ts <- now;
      acc.last_outcome <- outcome_name outcome;
      if String.trim keeper <> "" then acc.last_keeper <- keeper;
      let trimmed_room = String.trim room_id in
      if trimmed_room <> "" then begin
        acc.last_room_id <- trimmed_room;
        Hashtbl.replace acc.rooms trimmed_room ()
      end;
      if duration_ms > 0 then begin
        acc.total_dur_ms <- acc.total_dur_ms + duration_ms;
        acc.timed_count <- acc.timed_count + 1;
        acc.max_dur_ms <- max acc.max_dur_ms duration_ms;
        if duration_ms >= slow_threshold_ms () then
          acc.slow_count <- acc.slow_count + 1
      end;
      match outcome with
      | Success ->
          acc.success_count <- acc.success_count + 1;
          acc.last_success_ts <- now
      | Duplicate ->
          acc.duplicate_count <- acc.duplicate_count + 1
      | Validation_error message ->
          acc.validation_error_count <- acc.validation_error_count + 1;
          update_error_fields acc ~now ~kind:"validation" ~message
      | Keeper_error message ->
          acc.keeper_error_count <- acc.keeper_error_count + 1;
          update_error_fields acc ~now ~kind:"keeper" ~message
      | Dispatch_unavailable ->
          acc.dispatch_unavailable_count <- acc.dispatch_unavailable_count + 1;
          update_error_fields acc ~now ~kind:"dispatch_unavailable"
            ~message:"keeper dispatch unavailable"
      | Internal_error message ->
          acc.internal_error_count <- acc.internal_error_count + 1;
          update_error_fields acc ~now ~kind:"internal" ~message)

let snapshot () =
  Eio_guard.with_mutex_ro mu (fun () ->
      Hashtbl.fold
        (fun channel acc rows ->
          {
            channel;
            message_count = acc.msg_count;
            success_count = acc.success_count;
            error_count = acc.err_count;
            duplicate_count = acc.duplicate_count;
            validation_error_count = acc.validation_error_count;
            keeper_error_count = acc.keeper_error_count;
            dispatch_unavailable_count = acc.dispatch_unavailable_count;
            internal_error_count = acc.internal_error_count;
            last_activity_ts = acc.last_ts;
            last_success_ts = acc.last_success_ts;
            last_error_ts = acc.last_error_ts;
            last_keeper = acc.last_keeper;
            last_room_id = acc.last_room_id;
            last_error = acc.last_error;
            last_error_kind = acc.last_error_kind;
            last_outcome = acc.last_outcome;
            total_duration_ms = acc.total_dur_ms;
            timed_count = acc.timed_count;
            max_duration_ms = acc.max_dur_ms;
            slow_count = acc.slow_count;
            room_count = Hashtbl.length acc.rooms;
          }
          :: rows)
        table [])
  |> List.sort (fun a b ->
         let by_messages = compare b.message_count a.message_count in
         if by_messages <> 0 then by_messages
         else String.compare a.channel b.channel)

let total_messages () =
  Eio_guard.with_mutex_ro mu (fun () ->
      Hashtbl.fold (fun _ acc sum -> sum + acc.msg_count) table 0)

let iso_of_ts ts =
  if ts <= 0.0 then "never"
  else
    let t = Unix.gmtime ts in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
      t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

let percent numerator denominator =
  if denominator <= 0 then 0
  else
    int_of_float
      (Float.round
         ((float_of_int numerator *. 100.0) /. float_of_int denominator))

let effective_attempt_count (stats : channel_stats) =
  max 0 (stats.message_count - stats.duplicate_count)

let success_rate_pct (stats : channel_stats) =
  percent stats.success_count (effective_attempt_count stats)

let slow_rate_pct (stats : channel_stats) =
  percent stats.slow_count stats.timed_count

let health_of_stats (stats : channel_stats) =
  if stats.message_count = 0 then "idle"
  else if stats.error_count = 0 then "healthy"
  else if stats.success_count = 0 then "failing"
  else
    let err_rate = percent stats.error_count (effective_attempt_count stats) in
    let slow_rate = slow_rate_pct stats in
    if err_rate >= 50 then "failing"
    else if err_rate >= 10 || slow_rate >= 25 then "degraded"
    else "healthy"

let snapshot_json () =
  let channels = snapshot () in
  let total =
    List.fold_left
      (fun sum (stats : channel_stats) -> sum + stats.message_count)
      0 channels
  in
  let total_success =
    List.fold_left
      (fun sum (stats : channel_stats) -> sum + stats.success_count)
      0 channels
  in
  let total_errors =
    List.fold_left
      (fun sum (stats : channel_stats) -> sum + stats.error_count)
      0 channels
  in
  let total_duplicates =
    List.fold_left
      (fun sum (stats : channel_stats) -> sum + stats.duplicate_count)
      0 channels
  in
  let channel_json (stats : channel_stats) =
    let avg_dur =
      if stats.timed_count > 0 then stats.total_duration_ms / stats.timed_count
      else 0
    in
    `Assoc
      [
        ("channel", `String stats.channel);
        ("message_count", `Int stats.message_count);
        ("success_count", `Int stats.success_count);
        ("error_count", `Int stats.error_count);
        ("duplicate_count", `Int stats.duplicate_count);
        ("validation_error_count", `Int stats.validation_error_count);
        ("keeper_error_count", `Int stats.keeper_error_count);
        ("dispatch_unavailable_count", `Int stats.dispatch_unavailable_count);
        ("internal_error_count", `Int stats.internal_error_count);
        ("last_activity", `String (iso_of_ts stats.last_activity_ts));
        ("last_success", `String (iso_of_ts stats.last_success_ts));
        ("last_error_at", `String (iso_of_ts stats.last_error_ts));
        ("last_keeper", `String stats.last_keeper);
        ("last_room_id", `String stats.last_room_id);
        ("last_error", `String stats.last_error);
        ("last_error_kind", `String stats.last_error_kind);
        ("last_outcome", `String stats.last_outcome);
        ("avg_duration_ms", `Int avg_dur);
        ("max_duration_ms", `Int stats.max_duration_ms);
        ("slow_count", `Int stats.slow_count);
        ("slow_rate_pct", `Int (slow_rate_pct stats));
        ("success_rate_pct", `Int (success_rate_pct stats));
        ("room_count", `Int stats.room_count);
        ("health", `String (health_of_stats stats));
      ]
  in
  `Assoc
    [
      ("channels", `List (List.map channel_json channels));
      ("total_messages", `Int total);
      ("total_success", `Int total_success);
      ("total_errors", `Int total_errors);
      ("total_duplicates", `Int total_duplicates);
      ( "success_rate_pct",
        `Int
          (percent total_success
             (max 0 (total - total_duplicates))) );
      ("dedup_table_size", `Int (dedup_table_size ()));
      ("uptime_seconds", `Int (int_of_float (Unix.gettimeofday () -. start_time)));
    ]
