(** Durable per-Keeper crash observation store. *)

type crash_event =
  { keepers_dir : string
  ; name : string
  ; ts : float
  ; reason : string
  ; restart_count : int
  }

let queue : crash_event Queue.t = Queue.create ()
let store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 8
let store_mu = Eio.Mutex.create ()

let crash_store ~keepers_dir name =
  let dir =
    Filename.concat
      (Filename.concat keepers_dir name)
      (Common.keeper_runtime_store_dirname Common.Keeper_crash_events)
  in
  Eio_guard.with_mutex store_mu (fun () ->
    match Hashtbl.find_opt store_cache dir with
    | Some store -> store
    | None ->
      let store = Dated_jsonl.create ~base_dir:dir () in
      Hashtbl.replace store_cache dir store;
      store)
;;

let enqueue_record ~keepers_dir ~name ~ts ~reason ~restart_count =
  Queue.push { keepers_dir; name; ts; reason; restart_count } queue
;;

let write_event (event : crash_event) =
  let store = crash_store ~keepers_dir:event.keepers_dir event.name in
  Dated_jsonl.append
    store
    (`Assoc
       [ "ts", `Float event.ts
       ; "reason", `String event.reason
       ; "restart_count", `Int event.restart_count
       ])
;;

let write_event_reporting_failure event =
  try write_event event with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CrashPersistenceFailures)
      ~labels:
        [ "site", Keeper_crash_persistence_failure_site.(to_label Crash_write) ]
      ();
    Log.Keeper.warn
      "crash persistence write failed for %s: %s"
      event.name
      (Printexc.to_string exn)
;;

(* One event per protected step. Taking and writing together is what keeps a
   cancellation from leaving an event in neither the queue nor the store, and
   keeping the step to one event is what keeps the uncancellable stretch to one
   append: whatever has not been taken yet is still queued, so a cancellation
   between two events costs nothing and the release hook writes the rest. *)
let rec flush_pending () =
  match
    Eio.Cancel.protect (fun () ->
      match Queue.take_opt queue with
      | None -> `Drained
      | Some event ->
        write_event_reporting_failure event;
        `Wrote)
  with
  | `Drained -> ()
  | `Wrote -> flush_pending ()
;;

let start_drain_fiber ~sw ~clock =
  (* The switch cancels the drain fiber, and a crash record is most likely to
     be waiting in the queue exactly then: the keepers exit as the server goes
     down, enqueue, and the fiber's next wake never comes. The release hook is
     that last wake. *)
  Eio.Switch.on_release sw flush_pending;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Time.sleep
        clock
        Env_config_keeper.KeeperPollIntervals.crash_persistence_drain_sec;
      flush_pending ()
    done;
    `Stop_daemon)
;;

let recent_crashes ~keepers_dir ~name ~max_entries =
  let store = crash_store ~keepers_dir name in
  Dated_jsonl.read_recent store max_entries
;;
