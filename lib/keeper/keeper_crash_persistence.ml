(** Keeper_crash_persistence -- Durable crash event store.

    Architecture:
    - [enqueue_record] pushes to an in-memory Queue (non-yielding).
    - A background drain fiber periodically flushes the queue to
      Dated_jsonl stores under [masc_root/keepers/<name>/crash-events/].
    - Each keeper gets a cached [Dated_jsonl.t] instance (same pattern
      as [keeper_types_support.ml:metrics_store_cache]).
    - [recent_crashes] reads from disk for dashboard display.

    Callers must pass [Room.masc_root_dir config] as [~masc_root]
    to ensure cluster-scoped paths.

    @since 3.0.0 *)

(* ── types ───────────────────────────────────────────────────── *)

type crash_event = {
  masc_root : string;
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

let crash_store ~masc_root name : Dated_jsonl.t =
  let dir = Filename.concat
    (Filename.concat (Filename.concat masc_root "keepers") name)
    "crash-events" in
  Eio_guard.with_mutex store_mu (fun () ->
    match Hashtbl.find_opt store_cache dir with
    | Some store -> store
    | None ->
        let store = Dated_jsonl.create ~base_dir:dir () in
        Hashtbl.replace store_cache dir store;
        store)

(* ── enqueue (non-yielding) ──────────────────────────────────── *)

let enqueue_record ~masc_root ~name ~ts ~reason ~restart_count =
  Queue.push { masc_root; name; ts; reason; restart_count } queue

(* ── drain fiber ─────────────────────────────────────────────── *)

let drain_batch () =
  let batch = ref [] in
  while not (Queue.is_empty queue) do
    batch := Queue.pop queue :: !batch
  done;
  List.rev !batch

let write_event (ev : crash_event) =
  let store = crash_store ~masc_root:ev.masc_root ev.name in
  let json = `Assoc [
    ("ts", `Float ev.ts);
    ("reason", `String ev.reason);
    ("restart_count", `Int ev.restart_count);
  ] in
  Dated_jsonl.append store json

let start_drain_fiber ~sw ~clock =
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Time.sleep clock 2.0;
      let batch = drain_batch () in
      List.iter (fun ev ->
        (try write_event ev
         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
           Log.Keeper.warn "crash persistence write failed for %s: %s"
             ev.name (Printexc.to_string exn))
      ) batch
    done;
    `Stop_daemon)

(* ── read (I/O, for dashboard) ───────────────────────────────── *)

let recent_crashes ~masc_root ~name ~max_entries =
  let store = crash_store ~masc_root name in
  Dated_jsonl.read_recent store max_entries
