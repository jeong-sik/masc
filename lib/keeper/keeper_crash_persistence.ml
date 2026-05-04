(** Keeper_crash_persistence -- Durable crash event store.

    Architecture:
    - [enqueue_record] pushes to an in-memory Queue (non-yielding).
    - A background drain fiber periodically flushes the queue to
      Dated_jsonl stores under [<keepers_dir>/<name>/crash-events/].
    - Each keeper gets a cached [Dated_jsonl.t] instance (same pattern
      as [keeper_types_support.ml:metrics_store_cache]).
    - [recent_crashes] reads from disk for dashboard display.

    @since 3.0.0 *)

(* ── types ───────────────────────────────────────────────────── *)

type crash_event = {
  keepers_dir : string;
  name : string;
  ts : float;
  reason : string;
  restart_count : int;
}

(* ── queue (non-yielding enqueue) ────────────────────────────── *)

let queue : crash_event Queue.t = Queue.create ()

(* ── Dated_jsonl store cache ─────────────────────────────────── *)

let store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 8
let store_mu = Eio.Mutex.create ()

let crash_store ~keepers_dir name : Dated_jsonl.t =
  let dir = Filename.concat
    (Filename.concat keepers_dir name)
    "crash-events" in
  Eio_guard.with_mutex store_mu (fun () ->
    match Hashtbl.find_opt store_cache dir with
    | Some store -> store
    | None ->
        let store = Dated_jsonl.create ~base_dir:dir () in
        Hashtbl.replace store_cache dir store;
        store)

(* ── enqueue (non-yielding) ──────────────────────────────────── *)

let enqueue_record ~keepers_dir ~name ~ts ~reason ~restart_count =
  Queue.push { keepers_dir; name; ts; reason; restart_count } queue

(* ── drain fiber ─────────────────────────────────────────────── *)

let drain_batch () =
  let batch = ref [] in
  while not (Queue.is_empty queue) do
    batch := Queue.pop queue :: !batch
  done;
  List.rev !batch

let write_event (ev : crash_event) =
  let store = crash_store ~keepers_dir:ev.keepers_dir ev.name in
  let json = `Assoc [
    ("ts", `Float ev.ts);
    ("reason", `String ev.reason);
    ("restart_count", `Int ev.restart_count);
  ] in
  Dated_jsonl.append store json

(* ── self-preservation events ──────────────────────────────── *)

type sp_event = {
  sp_keepers_dir : string;
  sp_ts : float;
  sp_suppressed_count : int;
  sp_total : int;
  sp_ratio : float;
  sp_dominant_cohort : string;
}

let sp_queue : sp_event Queue.t = Queue.create ()

let sp_store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 2
let sp_store_mu = Eio.Mutex.create ()

let sp_store ~keepers_dir : Dated_jsonl.t =
  let dir = Filename.concat keepers_dir "_self-preservation" in
  Eio_guard.with_mutex sp_store_mu (fun () ->
    match Hashtbl.find_opt sp_store_cache dir with
    | Some store -> store
    | None ->
        let store = Dated_jsonl.create ~base_dir:dir () in
        Hashtbl.replace sp_store_cache dir store;
        store)

let enqueue_sp_event ~keepers_dir ~ts ~suppressed_count ~total ~ratio
    ~dominant_cohort =
  Queue.push {
    sp_keepers_dir = keepers_dir; sp_ts = ts;
    sp_suppressed_count = suppressed_count;
    sp_total = total; sp_ratio = ratio;
    sp_dominant_cohort = dominant_cohort;
  } sp_queue

let drain_sp_batch () =
  let batch = ref [] in
  while not (Queue.is_empty sp_queue) do
    batch := Queue.pop sp_queue :: !batch
  done;
  List.rev !batch

let write_sp_event (ev : sp_event) =
  let store = sp_store ~keepers_dir:ev.sp_keepers_dir in
  let json = `Assoc [
    ("ts", `Float ev.sp_ts);
    ("suppressed_count", `Int ev.sp_suppressed_count);
    ("total", `Int ev.sp_total);
    ("ratio", `Float ev.sp_ratio);
    ("dominant_cohort", `String ev.sp_dominant_cohort);
  ] in
  Dated_jsonl.append store json

(* ── drain fiber ─────────────────────────────────────────────── *)

let start_drain_fiber ~sw ~clock =
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Time.sleep clock
        Env_config_keeper.KeeperPollIntervals.crash_persistence_drain_sec;
      let batch = drain_batch () in
      List.iter (fun ev ->
        (try write_event ev
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Prometheus.inc_counter
             Prometheus.metric_keeper_crash_persistence_failures
             ~labels:[("site", "crash_write")]
             ();
           Log.Keeper.warn "crash persistence write failed for %s: %s"
             ev.name (Printexc.to_string exn))
      ) batch;
      let sp_batch = drain_sp_batch () in
      List.iter (fun ev ->
        (try write_sp_event ev
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Prometheus.inc_counter
             Prometheus.metric_keeper_crash_persistence_failures
             ~labels:[("site", "sp_write")]
             ();
           Log.Keeper.warn "sp persistence write failed: %s"
             (Printexc.to_string exn))
      ) sp_batch
    done;
    `Stop_daemon)

(* ── read (I/O, for dashboard) ───────────────────────────────── *)

let recent_crashes ~keepers_dir ~name ~max_entries =
  let store = crash_store ~keepers_dir name in
  Dated_jsonl.read_recent store max_entries

let recent_sp_events ~keepers_dir ~max_entries =
  let store = sp_store ~keepers_dir in
  Dated_jsonl.read_recent store max_entries
