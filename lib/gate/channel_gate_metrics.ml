(** Channel_gate_metrics -- per-channel connector diagnostics.
    See [channel_gate_metrics.mli]. *)

type outcome =
  | Success
  | Validation_error of string
  | Keeper_error of string
  | Dispatch_unavailable
  | Internal_error of string

let outcome_to_string = function
  | Success -> "success"
  | Validation_error _ -> "validation_error"
  | Keeper_error _ -> "keeper_error"
  | Dispatch_unavailable -> "dispatch_unavailable"
  | Internal_error _ -> "internal_error"

type error_kind =
  | Ek_validation
  | Ek_keeper
  | Ek_dispatch_unavailable
  | Ek_internal

let error_kind_to_string = function
  | Ek_validation -> "validation"
  | Ek_keeper -> "keeper"
  | Ek_dispatch_unavailable -> "dispatch_unavailable"
  | Ek_internal -> "internal"

let error_kind_of_string = function
  | "validation" -> Some Ek_validation
  | "keeper" -> Some Ek_keeper
  | "dispatch_unavailable" -> Some Ek_dispatch_unavailable
  | "internal" -> Some Ek_internal
  | _ -> None

type failure = {
  kind : error_kind;
  message : string;
}

(* The failure an outcome carries; [Success] carries none. *)
let outcome_failure = function
  | Success -> None
  | Validation_error message -> Some { kind = Ek_validation; message }
  | Keeper_error message -> Some { kind = Ek_keeper; message }
  | Dispatch_unavailable ->
      Some { kind = Ek_dispatch_unavailable; message = "keeper dispatch unavailable" }
  | Internal_error message -> Some { kind = Ek_internal; message }

type channel_stats = {
  channel : string;
  message_count : int;
  success_count : int;
  error_count : int;
  validation_error_count : int;
  keeper_error_count : int;
  dispatch_unavailable_count : int;
  internal_error_count : int;
  last_activity_ts : float;
  last_success_ts : float;
  last_error_ts : float;
  last_keeper : string;
  last_workspace_id : string;
  last_error : failure option;
  last_outcome : outcome;
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
  last_activity_ts : float;
  last_success_ts : float;
  last_error_ts : float;
  last_error : failure option;
  last_outcome : outcome;
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
  outcome : outcome;
  duration_ms : int;
}

type binding_acc = {
  msg_count : int;
  success_count : int;
  err_count : int;
  last_ts : float;
  last_success_ts : float;
  last_error_ts : float;
  keeper : string;
  last_error : failure option;
  last_outcome : outcome;
  total_dur_ms : int;
  timed_count : int;
  max_dur_ms : int;
}

type stats_acc = {
  msg_count : int;
  success_count : int;
  err_count : int;
  validation_error_count : int;
  keeper_error_count : int;
  dispatch_unavailable_count : int;
  internal_error_count : int;
  last_ts : float;
  last_success_ts : float;
  last_error_ts : float;
  last_keeper : string;
  last_workspace_id : string;
  last_error : failure option;
  last_outcome : outcome;
  total_dur_ms : int;
  timed_count : int;
  max_dur_ms : int;
  slow_count : int;
  workspaces : (string, unit) Hashtbl.t;
  workspace_order : string Queue.t;
  bindings : (string, binding_acc) Hashtbl.t;
  binding_order : string Queue.t;
}

let slow_threshold_ms () = 10_000

let max_tracked_workspaces = 256
let max_recent_events = 128

let make_binding_acc ~last_outcome =
  {
    msg_count = 0;
    success_count = 0;
    err_count = 0;
    last_ts = 0.0;
    last_success_ts = 0.0;
    last_error_ts = 0.0;
    keeper = "";
    last_error = None;
    last_outcome;
    total_dur_ms = 0;
    timed_count = 0;
    max_dur_ms = 0;
  }

let make_acc ~last_outcome =
  {
    msg_count = 0;
    success_count = 0;
    err_count = 0;
    validation_error_count = 0;
    keeper_error_count = 0;
    dispatch_unavailable_count = 0;
    internal_error_count = 0;
    last_ts = 0.0;
    last_success_ts = 0.0;
    last_error_ts = 0.0;
    last_keeper = "";
    last_workspace_id = "";
    last_error = None;
    last_outcome;
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

(* A channel or binding is created by the attempt that first names it, so it
   starts out holding that attempt's outcome; there is no "no attempt yet"
   value to carry. A new one reaches its table only once that attempt has been
   folded in, at the end of [record_attempt]. *)
let acc_for channel ~outcome =
  match Hashtbl.find_opt table channel with
  | Some acc -> acc
  | None -> make_acc ~last_outcome:outcome

let update_error_fields acc ~now ~failure =
  { acc with
    err_count = acc.err_count + 1
  ; last_error_ts = now
  ; last_error = Some failure
  }

let update_binding_error_fields (acc : binding_acc) ~now ~failure =
  { acc with
    err_count = acc.err_count + 1
  ; last_error_ts = now
  ; last_error = Some failure
  }

let count_failure (acc : stats_acc) = function
  | Ek_validation -> { acc with validation_error_count = acc.validation_error_count + 1 }
  | Ek_keeper -> { acc with keeper_error_count = acc.keeper_error_count + 1 }
  | Ek_dispatch_unavailable ->
      { acc with dispatch_unavailable_count = acc.dispatch_unavailable_count + 1 }
  | Ek_internal -> { acc with internal_error_count = acc.internal_error_count + 1 }

(* The workspace set and its eviction queue are containers held by [acc];
   they keep mutating in place. Only [last_workspace_id] is a field, so it
   comes back on the returned record. *)
let remember_workspace acc workspace_id =
  if not (Hashtbl.mem acc.workspaces workspace_id) then begin
    if Hashtbl.length acc.workspaces >= max_tracked_workspaces
       && not (Queue.is_empty acc.workspace_order)
    then begin
      let evicted = Queue.take acc.workspace_order in
      Hashtbl.remove acc.workspaces evicted
    end;
    Hashtbl.replace acc.workspaces workspace_id ();
     Queue.add workspace_id acc.workspace_order
   end;
  { acc with last_workspace_id = workspace_id }

let binding_for acc workspace_id ~outcome =
  match Hashtbl.find_opt acc.bindings workspace_id with
  | Some binding -> binding
  | None -> make_binding_acc ~last_outcome:outcome

(* A binding first seen here takes a slot, evicting the oldest when full. *)
let store_binding acc workspace_id binding =
  if not (Hashtbl.mem acc.bindings workspace_id) then begin
    if Hashtbl.length acc.bindings >= max_tracked_workspaces
       && not (Queue.is_empty acc.binding_order)
    then begin
      let evicted = Queue.take acc.binding_order in
      Hashtbl.remove acc.bindings evicted
    end;
    Queue.add workspace_id acc.binding_order
  end;
  Hashtbl.replace acc.bindings workspace_id binding

let append_event ~channel ~workspace_id ~keeper ~duration_ms outcome ~timestamp =
  incr next_event_seq;
  if Queue.length recent_events >= max_recent_events then ignore (Queue.take recent_events);
  Queue.add
    {
      seq = !next_event_seq;
      timestamp;
      channel;
      workspace_id;
      keeper;
      outcome;
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
      (* [acc] and [binding] are values now, so every step below rebinds them
         and the two tables are written once at the end. The nested [bindings]
         / [workspaces] tables are shared handles carried by [{ acc with ... }],
         so their in-place updates land whichever copy is held. *)
      let acc = acc_for channel_key ~outcome in
      let now = Unix.gettimeofday () in
      let trimmed_keeper = String.trim keeper in
      let acc =
        { acc with
          msg_count = acc.msg_count + 1
        ; last_ts = now
        ; last_outcome = outcome
        ; last_keeper =
            (if trimmed_keeper <> "" then trimmed_keeper else acc.last_keeper)
        }
      in
      let trimmed_workspace = String.trim workspace_id in
      let acc, binding =
        if trimmed_workspace = "" then acc, None
        else begin
          let acc = remember_workspace acc trimmed_workspace in
          let binding = binding_for acc trimmed_workspace ~outcome in
          let binding =
            { binding with
              msg_count = binding.msg_count + 1
            ; last_ts = now
            ; last_outcome = outcome
            ; keeper =
                (if trimmed_keeper <> "" then trimmed_keeper else binding.keeper)
            }
          in
          acc, Some binding
        end
      in
      let acc =
        if duration_ms > 0 then
          { acc with
            total_dur_ms = acc.total_dur_ms + duration_ms
          ; timed_count = acc.timed_count + 1
          ; max_dur_ms = max acc.max_dur_ms duration_ms
          ; slow_count =
              (if duration_ms >= slow_threshold_ms () then acc.slow_count + 1
               else acc.slow_count)
          }
        else acc
      in
      let binding =
        match binding with
        | Some binding when duration_ms > 0 ->
            Some
              { binding with
                total_dur_ms = binding.total_dur_ms + duration_ms
              ; timed_count = binding.timed_count + 1
              ; max_dur_ms = max binding.max_dur_ms duration_ms
              }
        | (Some _ | None) as binding -> binding
      in
      let acc, binding =
        match outcome_failure outcome with
        | None ->
            ( { acc with
                success_count = acc.success_count + 1
              ; last_success_ts = now
              },
              Option.map
                (fun (binding : binding_acc) ->
                  { binding with
                    success_count = binding.success_count + 1
                  ; last_success_ts = now
                  })
                binding )
        | Some failure ->
            ( update_error_fields (count_failure acc failure.kind) ~now ~failure,
              Option.map
                (fun (binding : binding_acc) ->
                  update_binding_error_fields binding ~now ~failure)
                binding )
      in
      (match binding with
       | Some binding when trimmed_workspace <> "" ->
           store_binding acc trimmed_workspace binding
       | Some _ | None -> ());
      Hashtbl.replace table channel_key acc;
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

let iso_of_ts ts =
  if ts <= 0.0 then "never" else Time_codec.rfc3339_of_unix ts

let percent numerator denominator =
  if denominator <= 0 then 0
  else
    int_of_float
      (Float.round
         ((float_of_int numerator *. 100.0) /. float_of_int denominator))


let success_rate_pct_counts ~success_count ~message_count =
  percent success_count message_count

let success_rate_pct (stats : channel_stats) =
  success_rate_pct_counts ~success_count:stats.success_count
    ~message_count:stats.message_count

let slow_rate_pct (stats : channel_stats) =
  percent stats.slow_count stats.timed_count

(* Returns the shared status type rather than a word of this module's own.
   The ladder below distinguishes a channel that carried nothing from one that
   lost everything; spelling those as free strings let both arrive at readers
   as [Unknown], flattening the worst rung into the middle one (#27560). *)
let health_of_counts ~message_count ~error_count ~success_count ~timed_count ~slow_count
  : Health_status.t =
  if message_count = 0 then Health_status.Idle
  else if error_count = 0 then Health_status.Ok
  else if success_count = 0 then Health_status.Error
  else
    let err_rate =
      percent error_count message_count
    in
    let slow_rate = percent slow_count timed_count in
    if err_rate >= 50 then Health_status.Error
    else if err_rate >= 10 || slow_rate >= 25 then Health_status.Degraded
    else Health_status.Ok

let health_of_stats (stats : channel_stats) =
  health_of_counts ~message_count:stats.message_count
    ~error_count:stats.error_count ~success_count:stats.success_count
    ~timed_count:stats.timed_count ~slow_count:stats.slow_count

let binding_success_rate_pct (stats : binding_stats) =
  success_rate_pct_counts ~success_count:stats.success_count
    ~message_count:stats.message_count

let binding_health (stats : binding_stats) =
  health_of_counts ~message_count:stats.message_count
    ~error_count:stats.error_count ~success_count:stats.success_count
    ~timed_count:stats.timed_count ~slow_count:0

(* The status JSON spells "no failure" as two empty strings. *)
let failure_fields = function
  | None -> ("", "")
  | Some { kind; message } -> (error_kind_to_string kind, message)

let gate_event_to_json (event : gate_event) =
  let error_kind, error = failure_fields (outcome_failure event.outcome) in
  `Assoc
    [
      ("seq", `Int event.seq);
      ("timestamp", `String (iso_of_ts event.timestamp));
      ("channel", `String event.channel);
      ("workspace_id", `String event.workspace_id);
      ("keeper", `String event.keeper);
      ("outcome", `String (outcome_to_string event.outcome));
      ("error_kind", `String error_kind);
      ("error", `String error);
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
              last_activity_ts = binding.last_ts;
              last_success_ts = binding.last_success_ts;
              last_error_ts = binding.last_error_ts;
              last_error = binding.last_error;
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
  let channel_json (stats : channel_stats) =
    let last_error_kind, last_error = failure_fields stats.last_error in
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
        ("validation_error_count", `Int stats.validation_error_count);
        ("keeper_error_count", `Int stats.keeper_error_count);
        ("dispatch_unavailable_count", `Int stats.dispatch_unavailable_count);
        ("internal_error_count", `Int stats.internal_error_count);
        ("last_activity", `String (iso_of_ts stats.last_activity_ts));
        ("last_success", `String (iso_of_ts stats.last_success_ts));
        ("last_error_at", `String (iso_of_ts stats.last_error_ts));
        ("last_keeper", `String stats.last_keeper);
        ("last_workspace_id", `String stats.last_workspace_id);
        ("last_error", `String last_error);
        ("last_error_kind", `String last_error_kind);
        ("last_outcome", `String (outcome_to_string stats.last_outcome));
        ("avg_duration_ms", `Int avg_dur);
        ("max_duration_ms", `Int stats.max_duration_ms);
        ("slow_count", `Int stats.slow_count);
        ("slow_rate_pct", `Int (slow_rate_pct stats));
        ("success_rate_pct", `Int (success_rate_pct stats));
        ("workspace_count", `Int stats.workspace_count);
        ("health", `String (Health_status.to_string (health_of_stats stats)));
      ]
  in
  let binding_json (stats : binding_stats) =
    let last_error_kind, last_error = failure_fields stats.last_error in
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
        ("last_activity", `String (iso_of_ts stats.last_activity_ts));
        ("last_success", `String (iso_of_ts stats.last_success_ts));
        ("last_error_at", `String (iso_of_ts stats.last_error_ts));
        ("last_error", `String last_error);
        ("last_error_kind", `String last_error_kind);
        ("last_outcome", `String (outcome_to_string stats.last_outcome));
        ("avg_duration_ms", `Int avg_dur);
        ("max_duration_ms", `Int stats.max_duration_ms);
        ("success_rate_pct", `Int (binding_success_rate_pct stats));
        ("health", `String (Health_status.to_string (binding_health stats)));
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
      ("success_rate_pct", `Int (percent total_success total));
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
