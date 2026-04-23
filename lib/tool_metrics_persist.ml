(** Tool_metrics_persist — JSONL disk persistence for tool metrics.

    Uses {!Dated_jsonl} for date-split storage under
    [data/tool-metrics/YYYY-MM/DD.jsonl].

    Design:
    - Each tool call is serialized as a single JSONL line.
    - Records are buffered in an Eio.Stream and flushed every 5 minutes.
    - On startup, existing day-files are read and replayed into Tool_metrics.
    - All I/O failures are caught and logged (best-effort persistence).

    @since 2.108.0 — Issue #3280 *)

let flush_interval_s = Env_config.InternalTimers.metrics_flush_sec

(* ── JSONL record format ────────────────────────────── *)

let record_to_json (r : Tool_result.t) : Yojson.Safe.t =
  `Assoc
    [ ("tool_name", `String r.tool_name)
    ; ("success", `Bool r.success)
    ; ("duration_ms", `Float r.duration_ms)
    ; ("ts", `Float (Time_compat.now ()))
    ]

type persisted_record = {
  tool_name : string;
  success : bool;
  duration_ms : float;
}

let parse_record (json : Yojson.Safe.t)
  : (persisted_record, string) result =
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
    Prometheus.inc_counter Prometheus.metric_error_events ~labels:[("type", "parsing")] ();
    Error
      (Printf.sprintf "missing required field(s): %s"
         (String.concat ", " missing))

(* ── Write queue ────────────────────────────────────── *)

let write_queue : Yojson.Safe.t Eio.Stream.t = Eio.Stream.create 4096

let store_ref : (string * Dated_jsonl.t) option ref = ref None

let rec drain_queue_without_store dropped =
  match Eio.Stream.take_nonblocking write_queue with
  | None -> dropped
  | Some _ -> drain_queue_without_store (dropped + 1)

let reset_for_testing () =
  ignore (drain_queue_without_store 0);
  store_ref := None

let get_or_create_store ~base_path : Dated_jsonl.t =
  match !store_ref with
  | Some (cached_path, s) when String.equal cached_path base_path -> s
  | _ ->
    let dir = Filename.concat base_path "data/tool-metrics" in
    Fs_compat.mkdir_p dir;
    let s = Dated_jsonl.create ~base_dir:dir () in
    store_ref := Some (base_path, s);
    s

let enqueue (result : Tool_result.t) =
  let json = record_to_json result in
  (* Bounded stream (4096): blocks briefly if full, providing backpressure.
     Under normal operation the flush fiber drains well before capacity. *)
  Eio.Stream.add write_queue json

(* ── Flush logic ────────────────────────────────────── *)

let drain_to_store (store : Dated_jsonl.t) : int =
  let count = ref 0 in
  let rec drain () =
    match Eio.Stream.take_nonblocking write_queue with
    | None -> ()
    | Some json ->
      (try
         Dated_jsonl.append store json;
         incr count
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Metrics.error "tool_metrics_persist: append failed: %s"
           (Printexc.to_string exn));
      drain ()
  in
  drain ();
  !count

let flush_now () =
  match !store_ref with
  | None ->
    (* Store not yet initialized — drain and discard to prevent unbounded growth.
       In practice, restore() initializes store_ref before any enqueue calls. *)
    let dropped = drain_queue_without_store 0 in
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
           (Printexc.to_string exn));
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
        (Printexc.to_string exn))

(* ── Restore on startup ─────────────────────────────── *)

let restore ~base_path : int =
  let store = get_or_create_store ~base_path in
  let count = ref 0 in
  let skipped = ref 0 in
  let first_skip_reason = ref None in
  (try
     (* Read all available records (cap at 1M to avoid OOM on huge histories) *)
     let jsons = Dated_jsonl.read_recent store 1_000_000 in
     List.iter (fun json ->
       match parse_record json with
       | Ok r ->
         let result : Tool_result.t = {
           tool_name = r.tool_name;
           success = r.success;
           duration_ms = r.duration_ms;
           data = `Null;
         } in
         Tool_metrics.record result;
         incr count
       | Error reason ->
         incr skipped;
         if Option.is_none !first_skip_reason then
           first_skip_reason := Some reason
     ) jsons;
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
       (Printexc.to_string exn));
  !count
