(** Computed-at-export-tick OTel samples for runtime health surfaces that
    have no store cell: console-sink writer health (#20684), keeper
    transition-audit drain queue (#20677), fd accounting, and on-disk
    telemetry store sizes (#20682). Registered once at server bootstrap as
    an [Otel_metrics] source — the RFC-0217 observable pattern: values are
    computed when the exporter ticks, so they are always fresh and present
    from process start (no absence-vs-zero ambiguity). *)

(* Names with exactly one producer site (this module) stay local instead of
   going through the otel_metric_store name modules: the name-module SSOT
   exists to share a name between registration and scattered call sites,
   which does not apply to computed samples. *)
let metric_console_sink_dropped = "masc_console_sink_dropped_total"
let metric_console_sink_queue_depth = "masc_console_sink_queue_depth"
let metric_transition_audit_queue_depth = "masc_keeper_transition_audit_queue_depth"
let metric_fd_active_operations = "masc_fd_active_operations"
let metric_fd_resource_errors = "masc_fd_resource_errors_total"
let metric_store_bytes = "masc_store_bytes"
let metric_store_files = "masc_store_files"

(* Event-bus health (#20676): under Drop_oldest the oas_runtime bus sheds
   events silently; under Block the masc_domain bus accumulates publish
   wait. Labels: [bus] (masc_domain | oas_runtime), [purpose] (subscriber
   purpose, "unspecified" when absent). dropped_total sums over the
   currently-live subscriptions, so it can step down when a subscriber
   leaves — long-lived keeper bridges make that rare; rate() spikes at
   churn points are acceptable against having no shed signal at all. *)
let metric_bus_subscriber_dropped = "masc_event_bus_subscriber_dropped_total"
let metric_bus_subscriber_depth = "masc_event_bus_subscriber_depth"
let metric_bus_publish_blocked = "masc_event_bus_publish_blocked_seconds_total"
let metric_bus_subscribers = "masc_event_bus_subscribers"

(* HTTP connection pool: the export hook for Pool_metrics.current_snapshot.
   The masc_pool_* names predate this module (see pool_metrics.ml); the
   *_total gauges keep their historical names. *)
let pool_gauge_idle = "masc_pool_idle_total"
let pool_gauge_inflight = "masc_pool_inflight_total"
let pool_counter_reuse = "masc_pool_reuse_total"
let pool_counter_evict = "masc_pool_evict_total"
let pool_counter_evict_failure = "masc_pool_evict_failure_total"
let pool_counter_create = "masc_pool_create_total"

(* Stores implicated in the 2026-06 freeze incidents: unbounded JSONL growth
   in tool_calls / oas-events starved the telemetry readers (#20677), and
   trajectories reached 483MB (#20682). Sizes are per masc-root subdirectory;
   the label value is the directory name. *)
let watched_store_dirs =
  [ "tool_calls"
  ; "oas-events"
  ; "telemetry"
  ; "tool_usage"
  ; "trajectories"
  ; "transition-audit"
  ; "logs"
  ]
;;

(* Directory walks are not free on a 0.5s export tick; recompute at most
   once per minute and serve the cached samples in between. *)
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
    | exception _ -> ()
    | st ->
      (match st.st_kind with
       | Unix.S_REG ->
         bytes := !bytes +. Int64.to_float st.st_size;
         incr files
       | Unix.S_DIR ->
         (match Sys.readdir path with
          | exception _ -> ()
          | entries ->
            Array.iter (fun e -> go (Filename.concat path e)) entries)
       | _ -> ())
  in
  go root;
  (!bytes, !files)
;;

let store_cache : (float * Otel_metrics.sample list) ref = ref (neg_infinity, [])

let store_samples ~masc_root () =
  let now = Unix.gettimeofday () in
  let last, cached = !store_cache in
  if now -. last < store_walk_min_interval_sec
  then cached
  else (
    let samples =
      List.concat_map
        (fun store ->
          let dir = Filename.concat masc_root store in
          if Sys.file_exists dir
          then (
            let bytes, files = walk_dir_totals dir in
            [ gauge ~labels:[ "store", store ] metric_store_bytes bytes
            ; gauge ~labels:[ "store", store ] metric_store_files (Float.of_int files)
            ])
          else [])
        watched_store_dirs
    in
    store_cache := now, samples;
    samples)
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
          metric_fd_active_operations
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
          metric_fd_resource_errors
          (Float.of_int count))
      snap.Fd_accountant.resource_errors
  in
  open_limit @ per_kind @ resource_errors
;;

let bus_samples_of ~bus_label bus =
  let stats = Agent_sdk.Event_bus.stats bus in
  let by_purpose =
    (* Aggregate per purpose: several subscriptions can share one. *)
    List.fold_left
      (fun acc (s : Agent_sdk.Event_bus.subscription_stats) ->
        let purpose = Option.value s.purpose ~default:"unspecified" in
        let depth, dropped =
          match List.assoc_opt purpose acc with
          | Some (d, dr) -> d + s.depth, dr + s.dropped_total
          | None -> s.depth, s.dropped_total
        in
        (purpose, (depth, dropped)) :: List.remove_assoc purpose acc)
      []
      stats.subscriptions
  in
  let base = [ "bus", bus_label ] in
  gauge ~labels:base metric_bus_subscribers (Float.of_int stats.subscriber_count)
  :: counter_labeled
       ~labels:base
       metric_bus_publish_blocked
       stats.total_publish_blocked_seconds
  :: List.concat_map
       (fun (purpose, (depth, dropped)) ->
         let labels = ("purpose", purpose) :: base in
         [ gauge ~labels metric_bus_subscriber_depth (Float.of_int depth)
         ; counter_labeled ~labels metric_bus_subscriber_dropped (Float.of_int dropped)
         ])
       by_purpose
;;

let bus_samples () =
  List.concat
    [ (match Masc_event_bus.get () with
       | Some bus -> bus_samples_of ~bus_label:"masc_domain" bus
       | None -> [])
    ; (match Keeper_event_bus.get () with
       | Some bus -> bus_samples_of ~bus_label:"oas_runtime" bus
       | None -> [])
    ]
;;

let pool_samples () =
  match Pool_metrics.current_snapshot () with
  | None -> []
  | Some s ->
    [ gauge pool_gauge_idle (Float.of_int s.Masc_http_client.Pool.total_idle)
    ; gauge pool_gauge_inflight (Float.of_int s.Masc_http_client.Pool.total_inflight)
    ; counter pool_counter_reuse (Float.of_int s.Masc_http_client.Pool.reuse_count_total)
    ; counter pool_counter_evict (Float.of_int s.Masc_http_client.Pool.evict_count_total)
    ; counter
        pool_counter_evict_failure
        (Float.of_int s.Masc_http_client.Pool.evict_failure_count_total)
    ; counter pool_counter_create (Float.of_int s.Masc_http_client.Pool.create_count_total)
    ]
;;

let samples ~masc_root () =
  List.concat
    [ [ counter metric_console_sink_dropped (Float.of_int (Console_sink.dropped_count ()))
      ; gauge metric_console_sink_queue_depth (Float.of_int (Console_sink.queue_depth ()))
      ; gauge
          metric_transition_audit_queue_depth
          (Float.of_int (Keeper_transition_audit.queue_depth ()))
      ]
    ; fd_samples ()
    ; bus_samples ()
    ; pool_samples ()
    ; store_samples ~masc_root ()
    ]
;;

let registered = Atomic.make false

let register_once ~masc_root () =
  if not (Atomic.exchange registered true)
  then Otel_metrics.register_source (fun () -> samples ~masc_root ())
;;

module For_testing = struct
  let samples = samples
  let reset_store_cache () = store_cache := neg_infinity, []
end
