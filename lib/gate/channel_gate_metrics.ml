(** Channel_gate_metrics -- per-channel connector diagnostics.
    See [channel_gate_metrics.mli]. *)

type outcome =
  | Success
  | Duplicate
  | Validation_error of string
  | Keeper_error of string
  | Accepted_keeper_error of string
  | Dispatch_unavailable
  | Internal_error of string

(* Closed sum mirroring the in-module producer surface (5 sites in this
   file).  [Ek_none] replaces the [Error_kind ""] marker previously
   used to encode the no-error state for [Success] and [Duplicate]
   outcomes. *)
type error_kind =
  | Ek_none
  | Ek_validation
  | Ek_keeper
  | Ek_dispatch_unavailable
  | Ek_internal

let error_kind_to_string = function
  | Ek_none -> ""
  | Ek_validation -> "validation"
  | Ek_keeper -> "keeper"
  | Ek_dispatch_unavailable -> "dispatch_unavailable"
  | Ek_internal -> "internal"

let error_kind_of_string = function
  | "" -> Some Ek_none
  | "validation" -> Some Ek_validation
  | "keeper" -> Some Ek_keeper
  | "dispatch_unavailable" -> Some Ek_dispatch_unavailable
  | "internal" -> Some Ek_internal
  | _ -> None

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
  last_workspace_id : string;
  last_error : string;
  last_error_kind : error_kind;
  last_outcome : string;
  total_duration_ms : int;
  timed_count : int;
  max_duration_ms : int;
  slow_count : int;
  workspace_count : int;
}

type binding_stats = {
  channel : string;
  workspace_id : string;
  keeper : string;
  message_count : int;
  success_count : int;
  error_count : int;
  duplicate_count : int;
  last_activity_ts : float;
  last_success_ts : float;
  last_error_ts : float;
  last_error : string;
  last_error_kind : error_kind;
  last_outcome : string;
  total_duration_ms : int;
  timed_count : int;
  max_duration_ms : int;
}

type gate_event = {
  seq : int;
  timestamp : float;
  channel : string;
  workspace_id : string;
  keeper : string;
  outcome : string;
  error_kind : error_kind;
  error : string;
  duration_ms : int;
}

type binding_acc = {
  mutable msg_count : int;
  mutable success_count : int;
  mutable err_count : int;
  mutable duplicate_count : int;
  mutable last_ts : float;
  mutable last_success_ts : float;
  mutable last_error_ts : float;
  mutable keeper : string;
  mutable last_error : string;
  mutable last_error_kind : error_kind;
  mutable last_outcome : string;
  mutable total_dur_ms : int;
  mutable timed_count : int;
  mutable max_dur_ms : int;
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
  mutable last_workspace_id : string;
  mutable last_error : string;
  mutable last_error_kind : error_kind;
  mutable last_outcome : string;
  mutable total_dur_ms : int;
  mutable timed_count : int;
  mutable max_dur_ms : int;
  mutable slow_count : int;
  workspaces : (string, unit) Hashtbl.t;
  workspace_order : string Queue.t;
  bindings : (string, binding_acc) Hashtbl.t;
  binding_order : string Queue.t;
}

let slow_threshold_ms () = 10_000

let max_tracked_workspaces = 256
let max_recent_events = 128

let make_binding_acc () =
  {
    msg_count = 0;
    success_count = 0;
    err_count = 0;
    duplicate_count = 0;
    last_ts = 0.0;
    last_success_ts = 0.0;
    last_error_ts = 0.0;
    keeper = "";
    last_error = "";
    last_error_kind = Ek_none;
    last_outcome = "idle";
    total_dur_ms = 0;
    timed_count = 0;
    max_dur_ms = 0;
  }

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
    last_workspace_id = "";
    last_error = "";
    last_error_kind = Ek_none;
    last_outcome = "idle";
    total_dur_ms = 0;
    timed_count = 0;
    max_dur_ms = 0;
    slow_count = 0;
    workspaces = Hashtbl.create 8;
    workspace_order = Queue.create ();
    bindings = Hashtbl.create 8;
    binding_order = Queue.create ();
  }

let table : (string, stats_acc) Hashtbl.t = Hashtbl.create 16
let mu = Eio.Mutex.create ()
let start_time = Unix.gettimeofday ()
let recent_events : gate_event Queue.t = Queue.create ()
let next_event_seq = ref 0

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
  | Accepted_keeper_error _ -> "accepted_keeper_error"
  | Dispatch_unavailable -> "dispatch_unavailable"
  | Internal_error _ -> "internal_error"

let update_error_fields acc ~now ~kind ~message =
  acc.err_count <- acc.err_count + 1;
  acc.last_error_ts <- now;
  acc.last_error_kind <- kind;
  acc.last_error <- message

let update_binding_error_fields (acc : binding_acc) ~now ~kind ~message =
  acc.err_count <- acc.err_count + 1;
  acc.last_error_ts <- now;
  acc.last_error_kind <- kind;
  acc.last_error <- message

let remember_workspace acc workspace_id =
  acc.last_workspace_id <- workspace_id;
  if not (Hashtbl.mem acc.workspaces workspace_id) then begin
    if Hashtbl.length acc.workspaces >= max_tracked_workspaces
       && not (Queue.is_empty acc.workspace_order)
    then begin
      let evicted = Queue.take acc.workspace_order in
      Hashtbl.remove acc.workspaces evicted
    end;
    Hashtbl.replace acc.workspaces workspace_id ();
     Queue.add workspace_id acc.workspace_order
   end

let get_or_create_binding acc workspace_id =
  match Hashtbl.find_opt acc.bindings workspace_id with
  | Some binding -> binding
  | None ->
      if Hashtbl.length acc.bindings >= max_tracked_workspaces
         && not (Queue.is_empty acc.binding_order)
      then begin
        let evicted = Queue.take acc.binding_order in
        Hashtbl.remove acc.bindings evicted
      end;
      let binding = make_binding_acc () in
      Hashtbl.replace acc.bindings workspace_id binding;
      Queue.add workspace_id acc.binding_order;
      binding

let outcome_error_details = function
  | Validation_error message -> (Ek_validation, message)
  | Keeper_error message -> (Ek_keeper, message)
  | Accepted_keeper_error message -> (Ek_keeper, message)
  | Dispatch_unavailable ->
      (Ek_dispatch_unavailable, "keeper dispatch unavailable")
  | Internal_error message -> (Ek_internal, message)
  | Success | Duplicate -> (Ek_none, "")

let append_event ~channel ~workspace_id ~keeper ~duration_ms outcome ~timestamp =
  let error_kind, error = outcome_error_details outcome in
  incr next_event_seq;
  if Queue.length recent_events >= max_recent_events then ignore (Queue.take recent_events);
  Queue.add
    {
      seq = !next_event_seq;
      timestamp;
      channel;
      workspace_id;
      keeper;
      outcome = outcome_name outcome;
      error_kind;
      error;
      duration_ms;
    }
    recent_events

let record_attempt ~channel ~workspace_id ~keeper ~duration_ms outcome =
  Eio_guard.with_mutex mu (fun () ->
      let trimmed_channel = String.trim channel in
      let channel_key =
        if trimmed_channel = "" then "unknown"
        else String.lowercase_ascii trimmed_channel
      in
      let acc = get_or_create_acc channel_key in
      let now = Unix.gettimeofday () in
      let trimmed_keeper = String.trim keeper in
      acc.msg_count <- acc.msg_count + 1;
      acc.last_ts <- now;
      acc.last_outcome <- outcome_name outcome;
      if trimmed_keeper <> "" then acc.last_keeper <- trimmed_keeper;
      let trimmed_workspace = String.trim workspace_id in
      let binding =
        if trimmed_workspace = "" then None
        else begin
          remember_workspace acc trimmed_workspace;
          let binding = get_or_create_binding acc trimmed_workspace in
          binding.msg_count <- binding.msg_count + 1;
          binding.last_ts <- now;
          binding.last_outcome <- outcome_name outcome;
          if trimmed_keeper <> "" then binding.keeper <- trimmed_keeper;
          Some binding
        end
      in
      if duration_ms > 0 then begin
        acc.total_dur_ms <- acc.total_dur_ms + duration_ms;
        acc.timed_count <- acc.timed_count + 1;
        acc.max_dur_ms <- max acc.max_dur_ms duration_ms;
        if duration_ms >= slow_threshold_ms () then
          acc.slow_count <- acc.slow_count + 1
      end;
      (match binding with
       | Some binding when duration_ms > 0 ->
           binding.total_dur_ms <- binding.total_dur_ms + duration_ms;
           binding.timed_count <- binding.timed_count + 1;
           binding.max_dur_ms <- max binding.max_dur_ms duration_ms
       | Some _ | None -> ());
      (match outcome with
      | Success ->
          acc.success_count <- acc.success_count + 1;
          acc.last_success_ts <- now;
          (match binding with
           | Some binding ->
               binding.success_count <- binding.success_count + 1;
               binding.last_success_ts <- now
           | None -> ())
      | Duplicate ->
          acc.duplicate_count <- acc.duplicate_count + 1;
          (match binding with
           | Some binding -> binding.duplicate_count <- binding.duplicate_count + 1
           | None -> ())
      | Validation_error message ->
          acc.validation_error_count <- acc.validation_error_count + 1;
          update_error_fields acc ~now
            ~kind:(Ek_validation) ~message;
          (match binding with
           | Some binding ->
               update_binding_error_fields binding ~now
                 ~kind:(Ek_validation) ~message
           | None -> ())
      | Keeper_error message ->
          acc.keeper_error_count <- acc.keeper_error_count + 1;
          update_error_fields acc ~now ~kind:(Ek_keeper)
            ~message;
          (match binding with
           | Some binding ->
               update_binding_error_fields binding ~now
                 ~kind:(Ek_keeper) ~message
           | None -> ())
      | Accepted_keeper_error message ->
          acc.keeper_error_count <- acc.keeper_error_count + 1;
          update_error_fields acc ~now ~kind:Ek_keeper ~message;
          (match binding with
           | Some binding ->
               update_binding_error_fields binding ~now ~kind:Ek_keeper ~message
           | None -> ())
      | Dispatch_unavailable ->
          acc.dispatch_unavailable_count <- acc.dispatch_unavailable_count + 1;
          update_error_fields acc ~now
            ~kind:(Ek_dispatch_unavailable)
            ~message:"keeper dispatch unavailable";
          (match binding with
           | Some binding ->
               update_binding_error_fields binding ~now
                 ~kind:(Ek_dispatch_unavailable)
                 ~message:"keeper dispatch unavailable"
           | None -> ())
      | Internal_error message ->
          acc.internal_error_count <- acc.internal_error_count + 1;
          update_error_fields acc ~now ~kind:(Ek_internal)
            ~message;
          (match binding with
           | Some binding ->
               update_binding_error_fields binding ~now
                 ~kind:(Ek_internal) ~message
           | None -> ()));
      append_event ~channel:channel_key ~workspace_id:trimmed_workspace ~keeper:trimmed_keeper
        ~duration_ms outcome ~timestamp:now)

let record_internal_error_exn ~channel ~workspace_id ~keeper ~duration_ms _exn =
  record_attempt ~channel ~workspace_id ~keeper ~duration_ms
    (Internal_error "internal error")

let snapshot () : channel_stats list =
  Eio_guard.with_mutex_ro mu (fun () ->
      Hashtbl.fold
        (fun channel (acc : stats_acc) rows ->
          ({
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
            last_workspace_id = acc.last_workspace_id;
            last_error = acc.last_error;
            last_error_kind = acc.last_error_kind;
            last_outcome = acc.last_outcome;
            total_duration_ms = acc.total_dur_ms;
            timed_count = acc.timed_count;
            max_duration_ms = acc.max_dur_ms;
            slow_count = acc.slow_count;
            workspace_count = Hashtbl.length acc.workspaces;
          } : channel_stats)
          :: rows)
        table [])
  |> List.sort (fun (a : channel_stats) (b : channel_stats) ->
         let by_messages = compare b.message_count a.message_count in
         if by_messages <> 0 then by_messages
         else String.compare a.channel b.channel)

let take_up_to limit rows =
  let rec loop remaining acc items =
    match (remaining, items) with
    | remaining, _ when remaining <= 0 -> List.rev acc
    | _, [] -> List.rev acc
    | remaining, item :: rest -> loop (remaining - 1) (item :: acc) rest
  in
  loop limit [] rows

let events_locked ?channel ?keeper ?workspace_id ~limit () =
  let matches expected actual =
    match expected with
    | None -> true
    | Some value -> String.equal (String.trim value) actual
  in
  let normalized_channel =
    channel
    |> Option.map (fun value ->
           let trimmed = String.trim value in
           String.lowercase_ascii trimmed)
  in
  let normalized_keeper = keeper |> Option.map String.trim in
  let normalized_workspace_id = workspace_id |> Option.map String.trim in
  let latest_seq = !next_event_seq in
  let filtered =
    Queue.fold
      (fun acc event ->
        if
          matches normalized_channel event.channel
          && matches normalized_keeper event.keeper
          && matches normalized_workspace_id event.workspace_id
        then event :: acc
        else acc)
      [] recent_events
    |> take_up_to limit
  in
  (latest_seq, filtered)

let events ?channel ?keeper ?workspace_id ~limit () =
  Eio_guard.with_mutex_ro mu (fun () ->
      events_locked ?channel ?keeper ?workspace_id ~limit ())

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


let effective_attempt_count_counts ~message_count ~duplicate_count =
  max 0 (message_count - duplicate_count)

let success_rate_pct_counts ~success_count ~message_count ~duplicate_count =
  percent success_count
    (effective_attempt_count_counts ~message_count ~duplicate_count)

let success_rate_pct (stats : channel_stats) =
  success_rate_pct_counts ~success_count:stats.success_count
    ~message_count:stats.message_count ~duplicate_count:stats.duplicate_count

let slow_rate_pct (stats : channel_stats) =
  percent stats.slow_count stats.timed_count

let health_of_counts ~message_count ~error_count ~success_count ~duplicate_count
    ~timed_count ~slow_count =
  if message_count = 0 then "idle"
  else if error_count = 0 then "healthy"
  else if success_count = 0 then "failing"
  else
    let err_rate =
      percent error_count
        (effective_attempt_count_counts ~message_count ~duplicate_count)
    in
    let slow_rate = percent slow_count timed_count in
    if err_rate >= 50 then "failing"
    else if err_rate >= 10 || slow_rate >= 25 then "degraded"
    else "healthy"

let health_of_stats (stats : channel_stats) =
  health_of_counts ~message_count:stats.message_count
    ~error_count:stats.error_count ~success_count:stats.success_count
    ~duplicate_count:stats.duplicate_count ~timed_count:stats.timed_count
    ~slow_count:stats.slow_count

let binding_success_rate_pct (stats : binding_stats) =
  success_rate_pct_counts ~success_count:stats.success_count
    ~message_count:stats.message_count ~duplicate_count:stats.duplicate_count

let binding_health (stats : binding_stats) =
  health_of_counts ~message_count:stats.message_count
    ~error_count:stats.error_count ~success_count:stats.success_count
    ~duplicate_count:stats.duplicate_count ~timed_count:stats.timed_count
    ~slow_count:0

let gate_event_to_json (event : gate_event) =
  `Assoc
    [
      ("seq", `Int event.seq);
      ("timestamp", `String (iso_of_ts event.timestamp));
      ("channel", `String event.channel);
      ("workspace_id", `String event.workspace_id);
      ("keeper", `String event.keeper);
      ("outcome", `String event.outcome);
      ("error_kind", `String (error_kind_to_string event.error_kind));
      ("error", `String event.error);
      ("duration_ms", `Int event.duration_ms);
    ]

let snapshot_locked () =
  let channels =
    Hashtbl.fold
      (fun channel (acc : stats_acc) rows ->
        ({
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
          last_workspace_id = acc.last_workspace_id;
          last_error = acc.last_error;
          last_error_kind = acc.last_error_kind;
          last_outcome = acc.last_outcome;
          total_duration_ms = acc.total_dur_ms;
          timed_count = acc.timed_count;
          max_duration_ms = acc.max_dur_ms;
          slow_count = acc.slow_count;
          workspace_count = Hashtbl.length acc.workspaces;
        } : channel_stats)
        :: rows)
      table []
    |> List.sort (fun (a : channel_stats) (b : channel_stats) ->
           let by_messages = compare b.message_count a.message_count in
           if by_messages <> 0 then by_messages
           else String.compare a.channel b.channel)
  in
  let bindings =
    Hashtbl.fold
      (fun channel acc rows ->
        Hashtbl.fold
          (fun workspace_id binding binding_rows ->
            {
              channel;
              workspace_id;
              keeper = binding.keeper;
              message_count = binding.msg_count;
              success_count = binding.success_count;
              error_count = binding.err_count;
              duplicate_count = binding.duplicate_count;
              last_activity_ts = binding.last_ts;
              last_success_ts = binding.last_success_ts;
              last_error_ts = binding.last_error_ts;
              last_error = binding.last_error;
              last_error_kind = binding.last_error_kind;
              last_outcome = binding.last_outcome;
              total_duration_ms = binding.total_dur_ms;
              timed_count = binding.timed_count;
              max_duration_ms = binding.max_dur_ms;
            }
            :: binding_rows)
          acc.bindings rows)
      table []
    |> List.sort (fun a b ->
           let by_activity = Float.compare b.last_activity_ts a.last_activity_ts in
           if by_activity <> 0 then by_activity
           else
             let by_channel = String.compare a.channel b.channel in
             if by_channel <> 0 then by_channel
             else String.compare a.workspace_id b.workspace_id)
  in
  let _latest_seq, recent = events_locked ~limit:max_recent_events () in
  (channels, bindings, recent)

let snapshot_json () =
  let channels, bindings, recent_events =
    Eio_guard.with_mutex_ro mu snapshot_locked
  in
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
        ("last_workspace_id", `String stats.last_workspace_id);
        ("last_error", `String stats.last_error);
        ("last_error_kind", `String (error_kind_to_string stats.last_error_kind));
        ("last_outcome", `String stats.last_outcome);
        ("avg_duration_ms", `Int avg_dur);
        ("max_duration_ms", `Int stats.max_duration_ms);
        ("slow_count", `Int stats.slow_count);
        ("slow_rate_pct", `Int (slow_rate_pct stats));
        ("success_rate_pct", `Int (success_rate_pct stats));
        ("workspace_count", `Int stats.workspace_count);
        ("health", `String (health_of_stats stats));
      ]
  in
  let binding_json (stats : binding_stats) =
    let avg_dur =
      if stats.timed_count > 0 then stats.total_duration_ms / stats.timed_count
      else 0
    in
    `Assoc
      [
        ("channel", `String stats.channel);
        ("workspace_id", `String stats.workspace_id);
        ("keeper", `String stats.keeper);
        ("message_count", `Int stats.message_count);
        ("success_count", `Int stats.success_count);
        ("error_count", `Int stats.error_count);
        ("duplicate_count", `Int stats.duplicate_count);
        ("last_activity", `String (iso_of_ts stats.last_activity_ts));
        ("last_success", `String (iso_of_ts stats.last_success_ts));
        ("last_error_at", `String (iso_of_ts stats.last_error_ts));
        ("last_error", `String stats.last_error);
        ("last_error_kind", `String (error_kind_to_string stats.last_error_kind));
        ("last_outcome", `String stats.last_outcome);
        ("avg_duration_ms", `Int avg_dur);
        ("max_duration_ms", `Int stats.max_duration_ms);
        ("success_rate_pct", `Int (binding_success_rate_pct stats));
        ("health", `String (binding_health stats));
      ]
  in
  `Assoc
    [
      ("channels", `List (List.map channel_json channels));
      ("bindings", `List (List.map binding_json bindings));
      ("recent_events", `List (List.map gate_event_to_json recent_events));
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

let events_json ?channel ?keeper ?workspace_id ~limit () =
  let latest_seq, rows = events ?channel ?keeper ?workspace_id ~limit () in
  `Assoc
    [
      ("events", `List (List.map gate_event_to_json rows));
      ("latest_seq", `Int latest_seq);
      ("total", `Int (List.length rows));
    ]
