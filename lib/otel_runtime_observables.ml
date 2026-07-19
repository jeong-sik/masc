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
let metric_store_scan_errors = "masc_store_scan_errors"
let metric_store_scan_partial = "masc_store_scan_partial"

(* Event-bus health: each subscriber owns a non-blocking queue contract.
   Labels identify the bus, purpose, capacity, and overflow behavior. *)
let metric_bus_subscriber_dropped = "masc_event_bus_subscriber_dropped_total"
let metric_bus_subscriber_depth = "masc_event_bus_subscriber_depth"
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
   trajectories reached 483MB (#20682). Flat stores are direct masc-root
   children. Canonical trajectories are the aggregate of every keeper's
   [Trajectory.trajectories_dir]; the retired top-level archive is not a
   telemetry source. *)
type watched_store_location =
  | Masc_root_child of string
  | Keeper_trajectory_directories

type watched_store =
  { label : string
  ; location : watched_store_location
  }

let flat_store label = { label; location = Masc_root_child label }

let watched_stores =
  [ flat_store "tool_calls"
  ; flat_store "oas-events"
  ; flat_store "telemetry"
  ; flat_store "tool_usage"
  ; { label =
        Common.keeper_runtime_store_dirname Common.Keeper_trajectories
    ; location = Keeper_trajectory_directories
    }
  ; flat_store "transition-audit"
  ; flat_store "logs"
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

type store_scan_operation =
  | Inspect_path
  | Read_directory

type store_scan_cause =
  | Io_failure of exn
  | Expected_directory of Unix.file_kind
  | Unknown_path_kind

type store_scan_error =
  { operation : store_scan_operation
  ; path : string
  ; cause : store_scan_cause
  }

type directory_presence =
  | Directory_missing
  | Directory_present

type store_paths =
  { paths : string list
  ; errors : store_scan_error list
  }

let store_scan_operation_to_string = function
  | Inspect_path -> "inspect_path"
  | Read_directory -> "read_directory"
;;

let file_kind_to_string = function
  | Unix.S_REG -> "regular_file"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character_device"
  | Unix.S_BLK -> "block_device"
  | Unix.S_LNK -> "symbolic_link"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let store_scan_cause_to_string = function
  | Io_failure exn -> Printexc.to_string exn
  | Expected_directory kind ->
    Printf.sprintf "expected directory, observed %s" (file_kind_to_string kind)
  | Unknown_path_kind -> "path kind could not be determined"
;;

let log_store_scan_error ~store error =
  Log.Telemetry.warn
    "runtime observable store scan failed store=%s operation=%s path=%s reason=%s"
    store
    (store_scan_operation_to_string error.operation)
    error.path
    (store_scan_cause_to_string error.cause)
;;

let inspect_directory path =
  match Fs_compat.exact_path_kind ~follow:false path with
  | Fs_compat.Exact_missing -> Ok Directory_missing
  | Fs_compat.Exact_kind Unix.S_DIR -> Ok Directory_present
  | Fs_compat.Exact_kind kind ->
    Error { operation = Inspect_path; path; cause = Expected_directory kind }
  | Fs_compat.Exact_unknown ->
    Error { operation = Inspect_path; path; cause = Unknown_path_kind }
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error { operation = Inspect_path; path; cause = Io_failure exn }
;;

let read_directory path =
  match Sys.readdir path with
  | entries -> Ok (Array.to_list entries)
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error { operation = Read_directory; path; cause = Io_failure exn }
;;

let keeper_root_entry_is_directory path =
  match Fs_compat.exact_path_kind ~follow:false path with
  | Fs_compat.Exact_missing -> Ok false
  | Fs_compat.Exact_kind Unix.S_DIR -> Ok true
  | Fs_compat.Exact_kind _ -> Ok false
  | Fs_compat.Exact_unknown ->
    Error { operation = Inspect_path; path; cause = Unknown_path_kind }
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error { operation = Inspect_path; path; cause = Io_failure exn }
;;

let walk_dir_totals root =
  (* (bytes, files) for regular files under [root], recursive. *)
  let bytes = ref 0.0 in
  let files = ref 0 in
  let errors = ref [] in
  let record_error operation path exn =
    errors := { operation; path; cause = Io_failure exn } :: !errors
  in
  let rec go path =
    match (Unix.LargeFile.lstat path : Unix.LargeFile.stats) with
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> record_error Inspect_path path exn
    | st ->
      (match st.st_kind with
       | Unix.S_REG ->
         bytes := !bytes +. Int64.to_float st.st_size;
         incr files
       | Unix.S_DIR ->
         (match Sys.readdir path with
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception exn -> record_error Read_directory path exn
          | entries ->
            Array.iter (fun e -> go (Filename.concat path e)) entries)
       | _ -> ())
  in
  go root;
  !bytes, !files, List.rev !errors
;;

let direct_store_paths ~masc_root store =
  let path = Filename.concat masc_root store in
  match inspect_directory path with
  | Ok Directory_missing -> { paths = []; errors = [] }
  | Ok Directory_present -> { paths = [ path ]; errors = [] }
  | Error error -> { paths = []; errors = [ error ] }
;;

let keeper_trajectory_paths ~masc_root =
  let keepers_root = Filename.concat masc_root Common.keepers_runtime_dirname in
  match inspect_directory keepers_root with
  | Ok Directory_missing -> { paths = []; errors = [] }
  | Error error -> { paths = []; errors = [ error ] }
  | Ok Directory_present ->
    (match read_directory keepers_root with
     | Error error -> { paths = []; errors = [ error ] }
     | Ok keeper_entries ->
       List.fold_left
         (fun discovered keeper_name ->
           let keeper_path = Filename.concat keepers_root keeper_name in
           match keeper_root_entry_is_directory keeper_path with
           | Ok false -> discovered
           | Error error ->
             { discovered with errors = error :: discovered.errors }
           | Ok true ->
             let path = Trajectory.trajectories_dir masc_root keeper_name in
             (match inspect_directory path with
              | Ok Directory_missing -> discovered
              | Ok Directory_present ->
                { discovered with paths = path :: discovered.paths }
              | Error error ->
                { discovered with errors = error :: discovered.errors }))
         { paths = []; errors = [] }
         keeper_entries)
;;

let watched_store_paths ~masc_root = function
  | Masc_root_child store -> direct_store_paths ~masc_root store
  | Keeper_trajectory_directories -> keeper_trajectory_paths ~masc_root
;;

let samples_for_watched_store ~masc_root store =
  let discovered = watched_store_paths ~masc_root store.location in
  let bytes, files, walk_errors =
    List.fold_left
      (fun (bytes, files, errors) path ->
        let path_bytes, path_files, path_errors = walk_dir_totals path in
        bytes +. path_bytes, files + path_files, List.rev_append path_errors errors)
      (0.0, 0, [])
      discovered.paths
  in
  let errors = List.rev_append discovered.errors walk_errors in
  List.iter (log_store_scan_error ~store:store.label) errors;
  let labels = [ "store", store.label ] in
  let scan_observations =
    [ gauge ~labels metric_store_scan_errors (Float.of_int (List.length errors))
    ; gauge ~labels metric_store_scan_partial
        (if discovered.paths <> [] && errors <> [] then 1.0 else 0.0)
    ]
  in
  match discovered.paths with
  | [] -> scan_observations
  | _ :: _ ->
    gauge ~labels metric_store_bytes bytes
    :: gauge ~labels metric_store_files (Float.of_int files)
    :: scan_observations
;;

type store_cache_entry =
  { sampled_at : float
  ; samples : Otel_metrics.sample list
  }

(* The observable source can be polled from exporter and test domains. A
   Stdlib mutex protects only the in-memory table; directory I/O always runs
   outside the critical section. Entries are keyed by the runtime root so a
   second workspace can never receive the first workspace's samples. *)
let store_cache : (string, store_cache_entry) Hashtbl.t = Hashtbl.create 4
let store_cache_mutex = Stdlib.Mutex.create ()

let fresh_cache_entry ~now entry =
  now -. entry.sampled_at < store_walk_min_interval_sec

let cached_store_samples ~masc_root ~now =
  Stdlib.Mutex.protect store_cache_mutex (fun () ->
    match Hashtbl.find_opt store_cache masc_root with
    | Some entry when fresh_cache_entry ~now entry -> Some entry.samples
    | Some _ | None -> None)
;;

let publish_store_samples ~masc_root ~sampled_at samples =
  Stdlib.Mutex.protect store_cache_mutex (fun () ->
    match Hashtbl.find_opt store_cache masc_root with
    | Some entry when fresh_cache_entry ~now:sampled_at entry -> entry.samples
    | Some _ | None ->
      Hashtbl.replace store_cache masc_root { sampled_at; samples };
      samples)
;;

let store_samples ~masc_root () =
  let now = Unix.gettimeofday () in
  match cached_store_samples ~masc_root ~now with
  | Some cached -> cached
  | None ->
    let samples =
      List.concat_map
        (samples_for_watched_store ~masc_root)
        watched_stores
    in
    publish_store_samples ~masc_root ~sampled_at:now samples
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
  let by_contract =
    (* Aggregate identical contracts so label sets stay unique. *)
    List.fold_left
      (fun acc (s : Agent_sdk.Event_bus.subscription_stats) ->
        let purpose = Option.value s.purpose ~default:"unspecified" in
        let overflow =
          match s.overflow with
          | Agent_sdk.Event_bus.Drop_oldest -> "drop_oldest"
          | Agent_sdk.Event_bus.Drop_newest -> "drop_newest"
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
  gauge ~labels:base metric_bus_subscribers (Float.of_int stats.subscriber_count)
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
             Otel_metric_store.metric_oas_bus_capacity
             (Float.of_int (count * capacity))
         ; gauge ~labels metric_bus_subscriber_depth (Float.of_int depth)
         ; counter_labeled ~labels metric_bus_subscriber_dropped (Float.of_int dropped)
         ])
       by_contract
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

  let reset_store_cache () =
    Stdlib.Mutex.protect store_cache_mutex (fun () -> Hashtbl.reset store_cache)
end
