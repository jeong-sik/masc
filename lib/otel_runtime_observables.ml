(** Computed-at-export-tick OTel samples for runtime health surfaces that
    have no store cell: console-sink writer health (#20684), keeper
    transition-audit drain queue (#20677), fd accounting, and on-disk
    telemetry store sizes (#20682). Registered once at server bootstrap as
    an [Otel_metrics] source — the RFC-0217 observable pattern: values are
    computed when the exporter ticks, so they are always fresh and present
    from process start (no absence-vs-zero ambiguity). *)

(* Series names live in [Otel_runtime_metric_names] (via the
   [Otel_metric_store] facade): the dashboard runtime-observables endpoint
   reads the same cells this module writes, so producer and reader share
   one constant per series. *)

(* Stores implicated in the 2026-06 freeze incidents: unbounded JSONL growth
   in tool_calls / agent-core-events starved the telemetry readers (#20677), and
   trajectories reached 483MB (#20682). Sizes are per masc-root subdirectory;
   the label value is the directory name. *)
let watched_store_dirs =
  [ "tool_calls"
  ; "agent-core-events"
  ; "telemetry"
  ; "tool_usage"
  ; "trajectories"
  ; Keeper_transition_audit.store_dirname
  ; "logs"
  ]
;;

(* Directory walks are not free on a 0.5s export tick; recompute at most
   once per minute and serve the cached samples in between. The walk itself
   is one lstat per file and one readdir per directory over every watched
   store; on the live root it held the sampler's fiber, and with it the main
   domain, for about 200 ms per refresh (2026-09-05 stack sample, RFC
   main-domain-scheduler-latency §8.8). It runs as one job on the domain
   pool when one is installed and inline otherwise. *)
let store_walk_min_interval_sec = 60.0

let counter name value =
  { Otel_metrics.name; value; labels = []; kind = Otel_metrics.Counter }
;;

let counter_labeled ~labels name value =
  { Otel_metrics.name; value; labels; kind = Otel_metrics.Counter }
;;

let gauge ?(labels = []) name value =
  { Otel_metrics.name; value; labels; kind = Otel_metrics.Gauge }
;;

let walk_dir_totals root =
  (* (bytes, files) for regular files under [root], recursive. *)
  let bytes = ref 0.0 in
  let files = ref 0 in
  let rec go path =
    match (Unix.LargeFile.lstat path : Unix.LargeFile.stats) with
    | exception _ -> ()  (* cancel-guard-ok: guards Unix.stat: no Eio cancellation point *)
    | st ->
      (match st.st_kind with
       | Unix.S_REG ->
         bytes := !bytes +. Int64.to_float st.st_size;
         incr files
       | Unix.S_DIR ->
         (match Sys.readdir path with
          | exception _ -> ()  (* cancel-guard-ok: guards Sys.readdir: no Eio cancellation point *)
          | entries ->
            Array.iter (fun e -> go (Filename.concat path e)) entries)
       | _ -> ())
  in
  go root;
  (!bytes, !files)
;;

let store_cache = Atomic.make (neg_infinity, [])

let rec store_samples ~masc_root () =
  let now = Unix.gettimeofday () in
  let ((last, cached) as current) = Atomic.get store_cache in
  if now -. last < store_walk_min_interval_sec
  then cached
  else (
    let samples =
      Domain_pool_ref.submit_io_or_inline (fun () ->
        List.concat_map
          (fun store ->
            let dir = Filename.concat masc_root store in
            if Sys.file_exists dir
            then (
              let bytes, files = walk_dir_totals dir in
              [ gauge ~labels:[ "store", store ] Otel_metric_store.metric_store_bytes bytes
              ; gauge ~labels:[ "store", store ] Otel_metric_store.metric_store_files (Float.of_int files)
              ])
            else [])
          watched_store_dirs)
    in
    let next = now, samples in
    if Atomic.compare_and_set store_cache current next
    then samples
    else store_samples ~masc_root ())
;;

let fd_samples () =
  let snap = Fd_accountant.fd_snapshot () in
  let open_limit =
    List.concat
      [ (match snap.Fd_accountant.fd_open with
         | Some value -> [ gauge Otel_core_metric_names.metric_fd_open (Float.of_int value) ]
         | None -> [])
      ; (match snap.Fd_accountant.fd_limit with
         | Some value -> [ gauge Otel_core_metric_names.metric_fd_limit (Float.of_int value) ]
         | None -> [])
      ]
  in
  let per_kind =
    List.map
      (fun (kind, n) ->
        gauge
          ~labels:[ "kind", Fd_accountant.kind_to_string kind ]
          Otel_metric_store.metric_fd_active_operations
          (Float.of_int n))
      snap.Fd_accountant.per_kind
  in
  let resource_errors =
    List.map
      (fun (kind, error, count) ->
        counter_labeled
          ~labels:
            [ "kind", Fd_accountant.kind_to_string kind
            ; "error", Fd_accountant.resource_error_to_string error
            ]
          Otel_metric_store.metric_fd_resource_errors
          (Float.of_int count))
      snap.Fd_accountant.resource_errors
  in
  open_limit @ per_kind @ resource_errors
;;

(* Event-bus health: each subscriber owns a non-blocking queue contract.
   Labels identify the bus, purpose, capacity, and overflow behavior. *)
let bus_samples_of ~bus_label bus =
  let stats = Agent_core.Event_bus.stats bus in
  let by_contract =
    (* Aggregate identical contracts so label sets stay unique. *)
    List.fold_left
      (fun acc (s : Agent_core.Event_bus.subscription_stats) ->
        let purpose = Option.value s.purpose ~default:"unspecified" in
        let overflow =
          match s.overflow with
          | Agent_core.Event_bus.Drop_oldest -> "drop_oldest"
          | Agent_core.Event_bus.Drop_newest -> "drop_newest"
        in
        let key = purpose, s.capacity, overflow in
        let count, depth, dropped =
          match List.assoc_opt key acc with
          | Some (n, d, dr) -> n + 1, d + s.depth, dr + s.dropped_total
          | None -> 1, s.depth, s.dropped_total
        in
        (key, (count, depth, dropped)) :: List.remove_assoc key acc)
      []
      stats.subscriptions
  in
  let base = [ "bus", bus_label ] in
  gauge ~labels:base Otel_metric_store.metric_bus_subscribers (Float.of_int stats.subscriber_count)
  :: List.concat_map
       (fun ((purpose, capacity, overflow), (count, depth, dropped)) ->
         let labels =
           [ "bus", bus_label
           ; "purpose", purpose
           ; "capacity", string_of_int capacity
           ; "overflow", overflow
           ]
         in
         [ gauge
             ~labels
             Otel_metric_store.metric_agent_core_bus_capacity
             (Float.of_int (count * capacity))
         ; gauge ~labels Otel_metric_store.metric_bus_subscriber_depth (Float.of_int depth)
         ; counter_labeled ~labels Otel_metric_store.metric_bus_subscriber_dropped (Float.of_int dropped)
         ])
       by_contract
;;

let bus_samples () =
  List.concat
    [ (match Event_bus_slots.get_masc () with
       | Some bus -> bus_samples_of ~bus_label:"masc_domain" bus
       | None -> [])
    ; (match Event_bus_slots.get_keeper () with
       | Some bus -> bus_samples_of ~bus_label:"agent_core_runtime" bus
       | None -> [])
    ]
;;

let pool_samples () =
  match Pool_metrics.current_snapshot () with
  | None -> []
  | Some s ->
    [ gauge Otel_metric_store.metric_pool_idle (Float.of_int s.Masc_http_client.Pool.total_idle)
    ; gauge Otel_metric_store.metric_pool_inflight (Float.of_int s.Masc_http_client.Pool.total_inflight)
    ; counter Otel_metric_store.metric_pool_reuse (Float.of_int s.Masc_http_client.Pool.reuse_count_total)
    ; counter Otel_metric_store.metric_pool_evict (Float.of_int s.Masc_http_client.Pool.evict_count_total)
    ; counter
        Otel_metric_store.metric_pool_evict_failure
        (Float.of_int s.Masc_http_client.Pool.evict_failure_count_total)
    ; counter Otel_metric_store.metric_pool_create (Float.of_int s.Masc_http_client.Pool.create_count_total)
    ]
;;

let samples ~masc_root () =
  List.concat
    [ [ counter Otel_metric_store.metric_console_sink_dropped (Float.of_int (Console_sink.dropped_count ()))
      ; gauge Otel_metric_store.metric_console_sink_queue_depth (Float.of_int (Console_sink.queue_depth ()))
      ; gauge
          Otel_metric_store.metric_transition_audit_queue_depth
          (Float.of_int (Keeper_transition_audit.queue_depth ()))
      ]
    ; fd_samples ()
    ; bus_samples ()
    ; pool_samples ()
    ; store_samples ~masc_root ()
    ]
;;

(* masc#29023: these samples used to reach the world only through the
   OTLP export tick, and that tick fires only when a collector backend
   is installed — with no collector every surface above computed
   nothing. Sampling is now decoupled from export: the store writer
   lands the values in Otel_metric_store cells (read back by the
   dashboard runtime-observables endpoint), and the store's own registered
   OTLP source exports those cells when a collector exists — one
   writer, one exporter, no duplicate series. Cumulative readings land
   via [set_gauge] exactly like the GC sampler's
   monotonic-by-construction gauges. *)
let write_samples_to_store ~masc_root () =
  let samples = samples ~masc_root () in
  List.iter
    (fun { Otel_metrics.name; value; labels; kind = _ } ->
       Otel_metric_store_core.set_gauge name ~labels value)
    samples;
  (* NDT-OK: the wall-clock read is the datum itself — a freshness stamp
     cell for the read surface; no deterministic branch consumes it. *)
  let stamped_at = Unix.gettimeofday () in
  Otel_metric_store_core.set_gauge
    Otel_metric_store.metric_runtime_observables_last_write_unixtime
    stamped_at;
  List.length samples
;;

let registered = Atomic.make false
let registration_mu = Stdlib.Mutex.create ()

let register_once ~masc_root () =
  if not (Atomic.get registered)
  then
    Stdlib.Mutex.protect registration_mu (fun () ->
      if not (Atomic.get registered)
      then (
        (* One synchronous write keeps the RFC-0217 property: every
           sample is present from process start, absence never reads as
           zero. *)
        (* fire-and-forget: the count only serves callers that log it *)
        ignore (write_samples_to_store ~masc_root () : int);
        Atomic.set registered true))
;;

(* One refresh per half minute keeps queue-depth and byte-size surfaces
   near-live while the directory walks stay amortized behind their own
   60s cache. *)
let store_writer_interval_s = 30.0

let start_store_writer ~sw ~clock ~masc_root () =
  register_once ~masc_root ();
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock store_writer_interval_s;
      (* Named per iteration so a tracer attached later still sees it. *)
      Eio.Switch.run ~name:"otel-store-writer" (fun _ ->
        (* fire-and-forget: the count only serves callers that log it *)
        ignore (write_samples_to_store ~masc_root () : int));
      loop ()
    in
    loop ())
;;

module For_testing = struct
  let samples = samples
  let write_samples_to_store = write_samples_to_store
  let reset_store_cache () = Atomic.set store_cache (neg_infinity, [])
end
