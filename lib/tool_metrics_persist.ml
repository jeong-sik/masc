(** Tool_metrics_persist — JSONL disk persistence for tool metrics.

    Uses {!Dated_jsonl} for date-split storage under
    [data/tool-metrics/YYYY-MM/DD.jsonl].

    Design:
    - Each tool call is published as an atomic pending file, then serialized as
      a single JSONL line.
    - Published records are buffered in a bounded queue and flushed on the
      configured interval (0.5 seconds by default).
    - A failed pending publication remains an observable in-memory fallback;
      a failed final append retains the durable pending record for retry.
    - A process-scoped snapshot exposes queue, drop, flush, spool, and
      append-failure state without presenting those counters as hydrated
      lifetime totals.

    @since 2.108.0 — Issue #3280 *)

let flush_interval_s = Env_config.InternalTimers.metrics_flush_sec
(** Retry failed storage at most as slowly as the normal default, while
    respecting an operator's faster configured cadence. Without this delay a
    queue already above the high watermark would wake immediately after every
    failure and spin on an unavailable filesystem. *)
let retry_backoff_s =
  Float.min
    flush_interval_s
    Env_config.InternalTimers.default_metrics_flush_sec

(* ── JSONL record format ────────────────────────────── *)

let record_to_json ~record_id (r : Tool_result.result) : Yojson.Safe.t =
  `Assoc
    [ ("record_id", `String record_id)
    ; ("tool_name", `String (Tool_result.tool_name r))
    ; ("disposition", `String (Tool_result.string_of_disposition r))
    ; ("duration_ms", `Float (Tool_result.duration_ms r))
    ; ("ts", `Float (Time_compat.now ()))
    ]

type hydrate_report = {
  loaded_records : int;
  malformed_records : int;
  invalid_records : int;
  pruned_files : int;
  recovered_pending_records : int;
  deduplicated_pending_records : int;
  invalid_pending_files : int;
}

type persistence_snapshot = {
  runtime_instance_id : string;
  process_started_at : string;
  observed_at_unix : float;
  writer_active : bool;
  queue_depth : int;
  retry_queue_depth : int;
  in_flight_records : int;
  spooling_records : int;
  spool_backed_queue_depth : int;
  queue_capacity : int;
  queue_high_watermark : int;
  queue_full_dropped_records : int;
  append_failed_records : int;
  spool_write_failed_records : int;
  spool_delete_failed_records : int;
  flushed_records : int;
  flush_batches : int;
  last_flush_trigger : string option;
  last_flush_rows : int option;
  last_flush_failed_rows : int option;
  last_flush_at_unix : float option;
  last_append_error : string option;
  last_spool_error : string option;
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
(** Start the background writer at half capacity, leaving another 2,048 slots
    for producers while the Eio fiber is scheduled and begins draining. See
    issue #32011. *)
let write_queue_high_watermark = write_queue_capacity / 2
let write_queue_mu = Mutex.create ()
type queued_record = {
  record_id : string;
  json : Yojson.Safe.t;
  pending_path : string option;
}

let write_queue : queued_record Queue.t = Queue.create ()
(** Failed appends stay ahead of newer writes. [in_flight_records] reserves
    their capacity slot while the writer is outside the short queue lock, so a
    producer cannot consume that slot before a failed record is retained. *)
let retry_queue : queued_record Queue.t = Queue.create ()
let in_flight_records : (string, queued_record) Hashtbl.t = Hashtbl.create 4
let spooling_records = ref 0
let write_queue_changed = Eio.Condition.create ()
let dropped_full_queue = Atomic.make 0
let append_failed_records = Atomic.make 0
let spool_write_failed_records = Atomic.make 0
let spool_delete_failed_records = Atomic.make 0
let flushed_records = Atomic.make 0
let flush_batches = Atomic.make 0
let writer_active = Atomic.make false
let last_flush_trigger = Atomic.make None
let last_flush_rows = Atomic.make None
let last_flush_failed_rows = Atomic.make None
let last_flush_at_unix = Atomic.make None
let last_append_error = Atomic.make None
let last_spool_error = Atomic.make None

let default_pending_write path content =
  Eio_guard.run_in_systhread (fun () ->
    Fs_compat.mkdir_p (Filename.dirname path);
    Fs_compat.save_file_atomic path content)

let pending_write = Atomic.make default_pending_write

let store = Atomic.make None

let with_write_queue_lock f = Mutex.protect write_queue_mu f

let pending_record_count_locked () =
  Queue.length retry_queue
  + Queue.length write_queue
  + Hashtbl.length in_flight_records
  + !spooling_records

let spool_backed_record_count_locked () =
  let count_queue queue =
    Queue.fold
      (fun count record ->
        count + Option.fold ~none:0 ~some:(fun _ -> 1) record.pending_path)
      0
      queue
  in
  count_queue retry_queue
  + count_queue write_queue
  + Hashtbl.fold
      (fun _ record count ->
        count + Option.fold ~none:0 ~some:(fun _ -> 1) record.pending_path)
      in_flight_records
      0

let take_queued_record () =
  with_write_queue_lock (fun () ->
    let record =
      match Queue.take_opt retry_queue with
      | Some _ as record -> record
      | None -> Queue.take_opt write_queue
    in
    Option.iter
      (fun record -> Hashtbl.replace in_flight_records record.record_id record)
      record;
    record)

let complete_queued_record record =
  with_write_queue_lock (fun () -> Hashtbl.remove in_flight_records record.record_id)

let retain_failed_record record =
  with_write_queue_lock (fun () ->
    Hashtbl.remove in_flight_records record.record_id;
    Queue.add record retry_queue)

let queued_record_count () =
  with_write_queue_lock pending_record_count_locked

let queue_depths () =
  with_write_queue_lock (fun () ->
    ( pending_record_count_locked ()
    , Queue.length retry_queue
    , Hashtbl.length in_flight_records
    , !spooling_records
    , spool_backed_record_count_locked () ))

let persistence_snapshot () =
  let build = Build_identity.current () in
  let queue_depth, retry_queue_depth, in_flight_records, spooling_records,
      spool_backed_queue_depth =
    queue_depths ()
  in
  { runtime_instance_id = build.runtime_instance_id
  ; process_started_at = build.started_at
  ; observed_at_unix = Time_compat.now ()
  ; writer_active = Atomic.get writer_active
  ; queue_depth
  ; retry_queue_depth
  ; in_flight_records
  ; spooling_records
  ; spool_backed_queue_depth
  ; queue_capacity = write_queue_capacity
  ; queue_high_watermark = write_queue_high_watermark
  ; queue_full_dropped_records = Atomic.get dropped_full_queue
  ; append_failed_records = Atomic.get append_failed_records
  ; spool_write_failed_records = Atomic.get spool_write_failed_records
  ; spool_delete_failed_records = Atomic.get spool_delete_failed_records
  ; flushed_records = Atomic.get flushed_records
  ; flush_batches = Atomic.get flush_batches
  ; last_flush_trigger = Atomic.get last_flush_trigger
  ; last_flush_rows = Atomic.get last_flush_rows
  ; last_flush_failed_rows = Atomic.get last_flush_failed_rows
  ; last_flush_at_unix = Atomic.get last_flush_at_unix
  ; last_append_error = Atomic.get last_append_error
  ; last_spool_error = Atomic.get last_spool_error
  }

let option_to_json encode = function
  | Some value -> encode value
  | None -> `Null

let persistence_snapshot_to_json snapshot =
  `Assoc
    [ "schema", `String "masc.tool_metrics.persistence.v1"
    ; "scope", `String "current_process"
    ; "runtime_instance_id", `String snapshot.runtime_instance_id
    ; "process_started_at", `String snapshot.process_started_at
    ; "observed_at_unix", `Float snapshot.observed_at_unix
    ; "writer_active", `Bool snapshot.writer_active
    ; "queue_depth", `Int snapshot.queue_depth
    ; "retry_queue_depth", `Int snapshot.retry_queue_depth
    ; "in_flight_records", `Int snapshot.in_flight_records
    ; "spooling_records", `Int snapshot.spooling_records
    ; "spool_backed_queue_depth", `Int snapshot.spool_backed_queue_depth
    ; "queue_capacity", `Int snapshot.queue_capacity
    ; "queue_high_watermark", `Int snapshot.queue_high_watermark
    ; "queue_full_dropped_records", `Int snapshot.queue_full_dropped_records
    ; "append_failed_records", `Int snapshot.append_failed_records
    ; "spool_write_failed_records", `Int snapshot.spool_write_failed_records
    ; "spool_delete_failed_records", `Int snapshot.spool_delete_failed_records
    ; "flushed_records", `Int snapshot.flushed_records
    ; "flush_batches", `Int snapshot.flush_batches
    ; ( "last_flush_trigger"
      , option_to_json (fun value -> `String value) snapshot.last_flush_trigger )
    ; "last_flush_rows", option_to_json (fun value -> `Int value) snapshot.last_flush_rows
    ; ( "last_flush_failed_rows"
      , option_to_json (fun value -> `Int value) snapshot.last_flush_failed_rows )
    ; ( "last_flush_at_unix"
      , option_to_json (fun value -> `Float value) snapshot.last_flush_at_unix )
    ; ( "last_append_error"
      , option_to_json (fun value -> `String value) snapshot.last_append_error )
    ; ( "last_spool_error"
      , option_to_json (fun value -> `String value) snapshot.last_spool_error )
    ]

let await_flush_trigger ~clock ~interval_s =
  match
    Eio.Time.with_timeout clock interval_s (fun () ->
      Eio.Condition.loop_no_mutex write_queue_changed (fun () ->
        if queued_record_count () >= write_queue_high_watermark
        then Some (Ok `High_watermark)
        else None))
  with
  | Ok trigger -> trigger
  | Error `Timeout -> `Timer

let drain_queue_without_store () =
  with_write_queue_lock (fun () ->
    let dropped = pending_record_count_locked () in
    Queue.clear write_queue;
    Queue.clear retry_queue;
    Hashtbl.clear in_flight_records;
    spooling_records := 0;
    dropped)

let reset_for_testing () =
  let dropped = drain_queue_without_store () in
  if dropped > 0 then
    Log.Metrics.warn "tool_metrics_persist: reset dropped %d queued records" dropped;
  Atomic.set dropped_full_queue 0;
  Atomic.set append_failed_records 0;
  Atomic.set spool_write_failed_records 0;
  Atomic.set spool_delete_failed_records 0;
  Atomic.set flushed_records 0;
  Atomic.set flush_batches 0;
  Atomic.set writer_active false;
  Atomic.set last_flush_trigger None;
  Atomic.set last_flush_rows None;
  Atomic.set last_flush_failed_rows None;
  Atomic.set last_flush_at_unix None;
  Atomic.set last_append_error None;
  Atomic.set last_spool_error None;
  Atomic.set pending_write default_pending_write;
  Atomic.set store None;
  Eio.Condition.broadcast write_queue_changed

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

let pending_dir ~base_path =
  Filename.concat
    (Config_dir_resolver.data_dir ~base_path)
    "tool-metrics-pending"

let pending_path ~base_path ~record_id =
  Filename.concat (pending_dir ~base_path) (record_id ^ ".json")

let remove_pending_file path =
  try
    Eio_guard.run_in_systhread (fun () ->
      try Sys.remove path with
      | Sys_error _ when not (Sys.file_exists path) -> ());
    true
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Sys_error _ | Unix.Unix_error _ | Failure _) as exn ->
    let error = Printexc.to_string exn in
    ignore (Atomic.fetch_and_add spool_delete_failed_records 1 : int);
    Atomic.set last_spool_error (Some error);
    Log.Metrics.error
      "tool_metrics_persist: pending spool delete failed for %s: %s"
      path
      error;
    false

type pending_record = {
  queued : queued_record;
  sample : Tool_metrics.sample;
}

let load_pending_records ~base_path =
  let dir = pending_dir ~base_path in
  if not (Sys.file_exists dir)
  then [], 0
  else
    Fs_compat.read_dir dir
    |> List.fold_left
         (fun (records, invalid) name ->
           let path = Filename.concat dir name in
           let parse () =
             if not (String.ends_with ~suffix:".json" name)
             then None
             else
               let record_id =
                 String.sub name 0 (String.length name - String.length ".json")
               in
               match Random_id.parse_uuid_v7 record_id with
               | Error _ -> None
               | Ok record_id ->
                 let json = Yojson.Safe.from_string (Fs_compat.load_file path) in
                 (match exact_string_field "record_id" json, sample_of_json json with
                  | Some embedded_id, Some sample
                    when String.equal embedded_id record_id ->
                    Some
                      { queued = { record_id; json; pending_path = Some path }
                      ; sample
                      }
                  | _ -> None)
           in
           if Fs_compat.is_atomic_orphan_name name
           then records, invalid
           else
             let parsed =
               try Ok (parse ()) with
               | Eio.Cancel.Cancelled _ as exn -> raise exn
               | Yojson.Json_error _ | Sys_error _ | Unix.Unix_error _ -> Error ()
             in
             match parsed with
             | Ok (Some record) -> record :: records, invalid
             | Ok None | Error () -> records, invalid + 1)
         ([], 0)

let enqueue_recovered_record record =
  with_write_queue_lock (fun () -> Queue.add record retry_queue)

let hydrate ~base_path ~retention_days =
  let store = get_or_create_store ~base_path in
  let pruned_files = Dated_jsonl.prune store ~days:retention_days in
  let pending_records, invalid_pending_files = load_pending_records ~base_path in
  let pending_ids = Hashtbl.create (List.length pending_records) in
  List.iter
    (fun pending -> Hashtbl.replace pending_ids pending.queued.record_id ())
    pending_records;
  let persisted_pending_ids = Hashtbl.create (List.length pending_records) in
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
             Option.iter
               (fun record_id ->
                 if Hashtbl.mem pending_ids record_id
                 then Hashtbl.replace persisted_pending_ids record_id ())
               (exact_string_field "record_id" json);
             add sample;
             Stdlib.incr loaded_records))
    in
    Result.map
      (fun () ->
         let recovered_pending_records = ref 0 in
         let deduplicated_pending_records = ref 0 in
         List.iter
           (fun pending ->
             if Hashtbl.mem persisted_pending_ids pending.queued.record_id
             then begin
               ignore (remove_pending_file (Option.get pending.queued.pending_path));
               Stdlib.incr deduplicated_pending_records
             end
             else begin
               add pending.sample;
               enqueue_recovered_record pending.queued;
               Stdlib.incr recovered_pending_records
             end)
           (List.rev pending_records);
         { loaded_records = !loaded_records
         ; malformed_records = !malformed_records
         ; invalid_records = !invalid_records
         ; pruned_files
         ; recovered_pending_records = !recovered_pending_records
         ; deduplicated_pending_records = !deduplicated_pending_records
         ; invalid_pending_files
         })
      read_result)

let enqueue ~base_path (result : Tool_result.result) =
  (* This hook runs inline on the tool completion path. If the persistence
     fiber is wedged behind FD/IO exhaustion, blocking here would hold the
     keeper turn open and amplify the outage. Drop best-effort metrics when
     the bounded queue is full; durable tool-call logs remain the stronger
     evidence surface. *)
  let dropped_for_full_queue =
    with_write_queue_lock (fun () ->
      if pending_record_count_locked () >= write_queue_capacity
      then true
      else (
        Stdlib.incr spooling_records;
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
  else begin
    let record_id = Random_id.uuid_v7 () in
    let json = record_to_json ~record_id result in
    let path = pending_path ~base_path ~record_id in
    let write_result =
      try Atomic.get pending_write path (Yojson.Safe.to_string json ^ "\n") with
      | Eio.Cancel.Cancelled _ as exn ->
        with_write_queue_lock (fun () -> Stdlib.decr spooling_records);
        raise exn
      | (Sys_error _ | Unix.Unix_error _ | Failure _) as exn ->
        Error (Printexc.to_string exn)
    in
    let pending_path =
      match write_result with
      | Ok () -> Some path
      | Error error ->
        ignore (Atomic.fetch_and_add spool_write_failed_records 1 : int);
        Atomic.set last_spool_error (Some error);
        Log.Metrics.error
          "tool_metrics_persist: pending spool write failed; retaining in memory: %s"
          error;
        None
    in
    let wake_flush_fiber =
      with_write_queue_lock (fun () ->
        Stdlib.decr spooling_records;
        Queue.add { record_id; json; pending_path } write_queue;
        pending_record_count_locked () = write_queue_high_watermark)
    in
    if wake_flush_fiber then Eio.Condition.broadcast write_queue_changed
  end

(* ── Flush logic ────────────────────────────────────── *)

type drain_report = {
  written : int;
  failed : int;
  last_error : string option;
}

let trigger_to_string = function
  | `High_watermark -> "high_watermark"
  | `Manual -> "manual"
  | `Shutdown -> "shutdown"
  | `Timer -> "timer"

let record_drain_report ~trigger report =
  let attempted = report.written + report.failed in
  if attempted > 0
  then begin
    Atomic.incr flush_batches;
    ignore (Atomic.fetch_and_add flushed_records report.written : int);
    ignore (Atomic.fetch_and_add append_failed_records report.failed : int);
    Atomic.set last_flush_trigger (Some (trigger_to_string trigger));
    Atomic.set last_flush_rows (Some report.written);
    Atomic.set last_flush_failed_rows (Some report.failed);
    Atomic.set last_flush_at_unix (Some (Time_compat.now ()));
    Atomic.set last_append_error report.last_error
  end

let drain_to_store ~trigger (store : Dated_jsonl.t) : drain_report =
  let written = ref 0 in
  let failed = ref 0 in
  let last_error = ref None in
  let rec drain () =
    match take_queued_record () with
    | None -> ()
    | Some record ->
      (match
         try
           Dated_jsonl.append store record.json;
           Ok ()
         with
         | Eio.Cancel.Cancelled _ as exn -> Error (`Cancelled exn)
         | exn -> Error (`Failed exn)
       with
       | Error (`Cancelled exn) ->
         retain_failed_record record;
         raise exn
       | Error (`Failed exn) ->
         let error = Stdlib.Printexc.to_string exn in
         retain_failed_record record;
         Stdlib.incr failed;
         last_error := Some error;
         Log.Metrics.error
           "tool_metrics_persist: append failed; retained for retry: %s"
           error
       | Ok () ->
         complete_queued_record record;
         Stdlib.incr written;
         Option.iter
           (fun path -> ignore (remove_pending_file path))
           record.pending_path;
         drain ())
  in
  drain ();
  let report = { written = !written; failed = !failed; last_error = !last_error } in
  record_drain_report ~trigger report;
  report

let flush_now ~base_path =
  let store = get_or_create_store ~base_path in
  let report = drain_to_store ~trigger:`Manual store in
  Log.Metrics.debug
    "tool_metrics_persist: flushed %d records (append_failed=%d)"
    report.written
    report.failed

let start_flush_fiber ~sw ~clock ~base_path =
  let store = get_or_create_store ~base_path in
  Atomic.set writer_active true;
  Eio.Switch.on_release sw (fun () -> Atomic.set writer_active false);
  Eio.Fiber.fork ~sw (fun () ->
    Log.Metrics.info "tool_metrics_persist: flush fiber started (interval=%.3gs)"
      flush_interval_s;
    let rec loop () =
      let trigger = await_flush_trigger ~clock ~interval_s:flush_interval_s in
      (try
         let report = drain_to_store ~trigger store in
         if report.written > 0 || report.failed > 0 then
           Log.Metrics.info
             "tool_metrics_persist: flushed %d records to disk (trigger=%s, append_failed=%d)"
             report.written
             (trigger_to_string trigger)
             report.failed;
         if report.failed > 0 then Eio.Time.sleep clock retry_backoff_s
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
      let report = drain_to_store ~trigger:`Shutdown store in
      if report.written > 0 || report.failed > 0 then
        Log.Metrics.info
          "tool_metrics_persist: shutdown flush wrote %d records (append_failed=%d)"
          report.written
          report.failed
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Metrics.error "tool_metrics_persist: shutdown flush failed: %s"
        (Stdlib.Printexc.to_string exn))

module For_testing = struct
  let high_watermark = write_queue_high_watermark
  let queued_record_count = queued_record_count
  let await_flush_trigger = await_flush_trigger
  let set_pending_write_guard guard = Atomic.set pending_write guard
end
