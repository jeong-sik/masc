(** Channel_gate_metrics -- per-channel message counters and status.
    See [channel_gate_metrics.mli]. *)

type channel_stats = {
  channel : string;
  message_count : int;
  error_count : int;
  last_activity_ts : float;
  last_keeper : string;
  total_duration_ms : int;
}

(* Mutable internal record for accumulation. *)
type stats_acc = {
  mutable msg_count : int;
  mutable err_count : int;
  mutable last_ts : float;
  mutable last_keeper : string;
  mutable total_dur_ms : int;
}

let table : (string, stats_acc) Hashtbl.t = Hashtbl.create 16
let mu = Eio.Mutex.create ()
let start_time = Unix.gettimeofday ()

let record_message ~channel ~keeper ~duration_ms ~success =
  Eio_guard.with_mutex mu (fun () ->
    let acc =
      match Hashtbl.find_opt table channel with
      | Some a -> a
      | None ->
          let a = {
            msg_count = 0; err_count = 0;
            last_ts = 0.0; last_keeper = ""; total_dur_ms = 0;
          } in
          Hashtbl.replace table channel a;
          a
    in
    acc.msg_count <- acc.msg_count + 1;
    acc.last_ts <- Unix.gettimeofday ();
    acc.last_keeper <- keeper;
    acc.total_dur_ms <- acc.total_dur_ms + duration_ms;
    if not success then acc.err_count <- acc.err_count + 1)

let snapshot () =
  Eio_guard.with_mutex_ro mu (fun () ->
    Hashtbl.fold (fun ch acc lst ->
      { channel = ch;
        message_count = acc.msg_count;
        error_count = acc.err_count;
        last_activity_ts = acc.last_ts;
        last_keeper = acc.last_keeper;
        total_duration_ms = acc.total_dur_ms;
      } :: lst
    ) table [])
  |> List.sort (fun a b -> compare b.message_count a.message_count)

let total_messages () =
  Eio_guard.with_mutex_ro mu (fun () ->
    Hashtbl.fold (fun _ acc sum -> sum + acc.msg_count) table 0)

(** Callback for dedup table size.  Set by channel_gate at init
    to break the module dependency cycle. *)
let dedup_size_fn : (unit -> int) ref = ref (fun () -> 0)

let register_dedup_size_fn f = dedup_size_fn := f

let dedup_table_size () = !dedup_size_fn ()

let iso_of_ts ts =
  if ts <= 0.0 then "never"
  else
    let t = Unix.gmtime ts in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
      t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

let snapshot_json () =
  let channels = snapshot () in
  let total = List.fold_left (fun s c -> s + c.message_count) 0 channels in
  let channel_json c =
    let avg_dur =
      if c.message_count > 0 then c.total_duration_ms / c.message_count else 0
    in
    `Assoc [
      ("channel", `String c.channel);
      ("message_count", `Int c.message_count);
      ("error_count", `Int c.error_count);
      ("last_activity", `String (iso_of_ts c.last_activity_ts));
      ("last_keeper", `String c.last_keeper);
      ("avg_duration_ms", `Int avg_dur);
    ]
  in
  `Assoc [
    ("channels", `List (List.map channel_json channels));
    ("total_messages", `Int total);
    ("dedup_table_size", `Int (dedup_table_size ()));
    ("uptime_seconds", `Int (int_of_float (Unix.gettimeofday () -. start_time)));
  ]
