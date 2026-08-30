(** Tool_metrics_persist — JSONL disk persistence for tool metrics.

    Uses {!Dated_jsonl} for date-split storage under
    [data/tool-metrics/YYYY-MM/DD.jsonl].

    Design:
    - Each tool call is serialized as a single JSONL line.
    - Records are buffered in a bounded best-effort queue and flushed every 5 minutes.
    - All I/O failures are caught and logged (best-effort persistence).

    @since 2.108.0 — Issue #3280 *)

let flush_interval_s = Env_config.InternalTimers.metrics_flush_sec

(* ── JSONL record format ────────────────────────────── *)

let record_to_json (r : Tool_result.result) : Yojson.Safe.t =
  `Assoc
    [ ("tool_name", `String (Tool_result.tool_name r))
    ; ("disposition", `String (Tool_result.string_of_disposition r))
    ; ("duration_ms", `Float (Tool_result.duration_ms r))
    ; ("ts", `Float (Time_compat.now ()))
    ]

type hydrate_report = {
  loaded_records : int;
  malformed_records : int;
  invalid_records : int;
  pruned_files : int;
}

let exact_string_field key json =
  match Safe_ops.json_member_opt key json with
  | Some (`String value) -> Some value
  | Some _ | None -> None

let exact_finite_number_field key json =
  match Safe_ops.json_member_opt key json with
  | Some (`Float value) when Float.is_finite value -> Some value
  | Some (`Int value) -> Some (Float.of_int value)
  | Some _ | None -> None

let sample_of_json json : Tool_metrics.sample option =
  match
    ( exact_string_field "tool_name" json
    , exact_string_field "disposition" json
    , exact_finite_number_field "duration_ms" json
    , exact_finite_number_field "ts" json )
  with
  | Some tool_name, Some disposition, Some duration_ms, Some ts
    when String.trim tool_name <> "" && duration_ms >= 0.0 && ts >= 0.0 ->
    let disposition =
      match disposition with
      | "completed" -> Some Tool_metrics.Completed
      | "deferred" -> Some Tool_metrics.Deferred
      | "failed" -> Some Tool_metrics.Failed
      | _ -> None
    in
    Option.map
      (fun disposition -> { Tool_metrics.tool_name; disposition; duration_ms })
      disposition
  | _ -> None

(* ── Write queue ────────────────────────────────────── *)

let write_queue_capacity = 4096
let write_queue_mu = Mutex.create ()
let write_queue : Yojson.Safe.t Queue.t = Queue.create ()
let dropped_full_queue = Atomic.make 0

let store = Atomic.make None

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
  Atomic.set store None

let rec get_or_create_store ~base_path : Dated_jsonl.t =
  let current = Atomic.get store in
  match current with
  | Some (cached_path, s) when String.equal cached_path base_path -> s
  | _ ->
    (* RFC-0121: layout SSOT via [Config_dir_resolver.data_dir]. *)
    let dir =
      Filename.concat
        (Config_dir_resolver.data_dir ~base_path)
        "tool-metrics"
    in
    Fs_compat.mkdir_p dir;
    let candidate = Dated_jsonl.create ~base_dir:dir () in
    if Atomic.compare_and_set store current (Some (base_path, candidate))
    then candidate
    else get_or_create_store ~base_path

let hydrate ~base_path ~retention_days =
  let store = get_or_create_store ~base_path in
  let pruned_files = Dated_jsonl.prune store ~days:retention_days in
  Tool_metrics.replace_samples (fun add ->
    let loaded_records = ref 0 in
    let malformed_records = ref 0 in
    let invalid_records = ref 0 in
    let read_result =
      Dated_jsonl.iter_all_entries_result store (function
        | Dated_jsonl.Malformed_json _ -> Stdlib.incr malformed_records
        | Dated_jsonl.Parsed json ->
          (match sample_of_json json with
           | None -> Stdlib.incr invalid_records
           | Some sample ->
             add sample;
             Stdlib.incr loaded_records))
    in
    Result.map
      (fun () ->
         { loaded_records = !loaded_records
         ; malformed_records = !malformed_records
         ; invalid_records = !invalid_records
         ; pruned_files
         })
      read_result)

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
      (try
         Dated_jsonl.append store json;
         Stdlib.incr count
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Metrics.error "tool_metrics_persist: append failed: %s"
           (Stdlib.Printexc.to_string exn));
      drain ()
  in
  drain ();
  !count

let flush_now ~base_path =
  let store = get_or_create_store ~base_path in
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
