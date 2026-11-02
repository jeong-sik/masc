let changed_event = "schedules_changed"

let announcement_count = Atomic.make 0
let announcements () = Atomic.get announcement_count

let changed ~base_path =
  Atomic.incr announcement_count;
  try Sse.broadcast (`Assoc [ "type", `String changed_event ]) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Server.warn
      "schedules: broadcast %s for %s failed: %s"
      changed_event
      base_path
      (Printexc.to_string exn)
;;

(* The store calls its observer on the writer, which may hold Keeper intake
   fences, so the observer only drops caches and wakes this fiber. A burst of
   writes is announced once. *)
let install_store_announcer ~sw =
  let wake = Eio.Stream.create 1 in
  let wake_mu = Stdlib.Mutex.create () in
  let written = Atomic.make None in
  let observer ~base_path =
    Server_routes_http_runtime.invalidate_full_health_snapshot_for_workspace ~base_path;
    Server_dashboard_http_core_cache.invalidate_scheduled_automation ~base_path;
    Atomic.set written (Some base_path);
    Stdlib.Mutex.protect wake_mu (fun () ->
      if Eio.Stream.is_empty wake then Eio.Stream.add wake ())
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec announce () =
      Eio.Stream.take wake;
      Option.iter (fun base_path -> changed ~base_path) (Atomic.exchange written None);
      announce ()
    in
    announce ());
  Schedule_store.install_change_observer observer
;;

let runner_changed ~base_path =
  Server_dashboard_http_core_cache.invalidate_scheduled_automation ~base_path;
  changed ~base_path
;;
