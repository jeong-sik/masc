module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_metrics_persist — JSONL disk persistence for tool metrics.

    Uses {!Dated_jsonl} for date-split storage under
    [data/tool-metrics/YYYY-MM/DD.jsonl].

    Design:
    - Each tool call is serialized as a single JSONL line.
    - Records are buffered in a bounded best-effort queue and flushed every 5 minutes.
    - On startup, existing day-files are read and replayed into Tool_metrics.
    - All I/O failures are caught and logged (best-effort persistence).

    @since 2.108.0 — Issue #3280 *)

let flush_interval_s = Env_config.InternalTimers.metrics_flush_sec

(* ── JSONL record format ────────────────────────────── *)

let record_to_json (r : Tool_result.result) : Yojson.Safe.t =
  `Assoc
    [ ("tool_name", `String (Tool_result.tool_name r))
    ; ("success", `Bool (Tool_result.is_success r))
    ; ("duration_ms", `Float (Tool_result.duration_ms r))
    ; ("ts", `Float (Time_compat.now ()))
    ]

type persisted_record = {
  tool_name : string;
  success : bool;
  duration_ms : float;
}

let parse_record (json : Yojson.Safe.t)
  : (persisted_record, string) Result.t =
  let tool_name = Safe_ops.json_string_opt "tool_name" json in
  let success = Safe_ops.json_bool_opt "success" json in
  let duration_ms = Safe_ops.json_float_opt "duration_ms" json in
  match tool_name, success, duration_ms with
  | Some tn, Some s, Some d -> Ok { tool_name = tn; success = s; duration_ms = d }
  | _ ->
    let missing =
      [ ("tool_name", Option.is_none tool_name)
      ; ("success", Option.is_none success)
      ; ("duration_ms", Option.is_none duration_ms)
      ]
      |> List.filter_map (fun (field, is_missing) ->
        if is_missing then Some field else None)
    in
    Otel_metric_store.inc_counter Otel_metric_store.metric_error_events ~labels:[("type", Error_event_type.(to_label Parsing))] ();
    Error
      (Printf.sprintf "missing required field(s): %s"
         (String.concat ", " missing))

(* ── Write queue ────────────────────────────────────── *)

let write_queue_capacity = 4096
let write_queue_mu = Mutex.create ()
let write_queue : Yojson.Safe.t Queue.t = Queue.create ()
let dropped_full_queue = Atomic.make 0

let store_ref : (string * Dated_jsonl.t) option ref = ref None

let with_write_queue_lock f = Mutex.protect write_queue_mu f

let take_queued_record () =
  with_write_queue_lock (fun () ->
    if Queue.is_empty write_queue then None else Some (Queue.take write_queue))

let drain_queue_without_store () =
  with_write_queue_lock (fun () ->
    let dropped = Queue.length write_queue in
    Queue.clear write_queue;
    dropped)

let reset_for_testing () =
  let dropped = drain_queue_without_store () in
  if dropped > 0 then
    Log.Metrics.warn "tool_metrics_persist: reset dropped %d queued records" dropped;
  Atomic.set dropped_full_queue 0;
  store_ref := None

let get_or_create_store ~base_path : Dated_jsonl.t =
  match !store_ref with
  | Some (cached_path, s) when String.equal cached_path base_path -> s
  | _ ->
    (* RFC-0121: layout SSOT via [Config_dir_resolver.data_dir]. *)
    let dir =
      Filename.concat
        (Config_dir_resolver.data_dir ~base_path)
        "tool-metrics"
    in
    Fs_compat.mkdir_p dir;
    let s = Dated_jsonl.create ~base_dir:dir () in
    store_ref := Some (base_path, s);
    s

let enqueue (result : Tool_result.result) =
  let json = record_to_json result in
  (* This hook runs inline on the tool completion path. If the persistence
     fiber is wedged behind FD/IO exhaustion, blocking here would hold the
     keeper turn open and amplify the outage. Drop best-effort metrics when
     the bounded queue is full; durable tool-call logs remain the stronger
     evidence surface. *)
  let dropped_for_full_queue =
    with_write_queue_lock (fun () ->
      if Queue.length write_queue >= write_queue_capacity
      then true
      else (
        Queue.add json write_queue;
        false))
  in
  if dropped_for_full_queue
  then begin
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_tool_metrics_persist_dropped ();
    let dropped = Atomic.fetch_and_add dropped_full_queue 1 + 1 in
    if dropped = 1 || dropped mod 1024 = 0 then
      Log.Metrics.warn
        "tool_metrics_persist: dropped %d record(s) because write queue is full"
        dropped
  end

(* ── Flush logic ────────────────────────────────────── *)

let drain_to_store (store : Dated_jsonl.t) : int =
  let count = ref 0 in
  let rec drain () =
    match take_queued_record () with
    | None -> ()
    | Some json ->
      (match Dated_jsonl.append_result store json with
       | Ok () -> Stdlib.incr count
       | Error msg ->
         Log.Metrics.error "tool_metrics_persist: append failed: %s"
           msg);
      drain ()
  in
  drain ();
  !count

let flush_now () =
  match !store_ref with
  | None ->
    (* Store not yet initialized — drain and discard to prevent unbounded growth.
       In practice, restore() initializes store_ref before any enqueue calls. *)
    let dropped = drain_queue_without_store () in
    if dropped > 0 then
      Log.Metrics.warn "tool_metrics_persist: flush_now called before init, dropped %d records"
        dropped
  | Some (_, store) ->
    let flushed = drain_to_store store in
    Log.Metrics.debug "tool_metrics_persist: flushed %d records" flushed

let start_flush_fiber ~sw ~clock ~base_path =
  let store = get_or_create_store ~base_path in
  Eio.Fiber.fork ~sw (fun () ->
    Log.Metrics.info "tool_metrics_persist: flush fiber started (interval=%.0fs)"
      flush_interval_s;
    let rec loop () =
      Eio.Time.sleep clock flush_interval_s;
      (try
         let n = drain_to_store store in
         if n > 0 then
           Log.Metrics.info "tool_metrics_persist: flushed %d records to disk" n
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Metrics.error "tool_metrics_persist: flush iteration failed: %s"
           (Stdlib.Printexc.to_string exn));
      loop ()
    in
    loop ());
  (* Register shutdown hook to drain remaining records *)
  Shutdown.register ~name:"tool_metrics_persist_flush" ~priority:25 (fun () ->
    try
      let n = drain_to_store store in
      if n > 0 then
        Log.Metrics.info "tool_metrics_persist: shutdown flush wrote %d records" n
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Metrics.error "tool_metrics_persist: shutdown flush failed: %s"
        (Stdlib.Printexc.to_string exn))

(* ── Restore on startup ─────────────────────────────── *)

let restore ~base_path : int =
  let store = get_or_create_store ~base_path in
  let count = ref 0 in
  let skipped = ref 0 in
  let first_skip_reason = ref None in
  (try
     Dated_jsonl.iter_all store (fun json ->
       match parse_record json with
       | Ok r ->
         let result : Tool_result.result =
           if r.success
           then
             Ok
               { Tool_result.tool_name = r.tool_name
               ; data = `Null
               ; duration_ms = r.duration_ms
               }
           else
             Error
               { Tool_result.class_ = Tool_result.Runtime_failure
               ; message = ""
               ; data = `Null
               ; tool_name = r.tool_name
               ; duration_ms = r.duration_ms
               }
         in
         Tool_metrics.record result;
         Stdlib.incr count
       | Error reason ->
         Stdlib.incr skipped;
         if Option.is_none !first_skip_reason then
           first_skip_reason := Some reason);
     if !skipped > 0 then
       Log.Metrics.warn
         "tool_metrics_persist: skipped %d malformed restore record(s)%s"
         !skipped
         (match !first_skip_reason with
          | Some reason -> Printf.sprintf " (first error: %s)" reason
          | None -> "")
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Metrics.error "tool_metrics_persist: restore failed: %s"
       (Stdlib.Printexc.to_string exn));
  !count
