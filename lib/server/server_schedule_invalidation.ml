(* The store callback only records work and wakes this switch-owned worker.
   Fanout and disconnect hooks may yield, so they must not run on a schedule
   mutation's completion path. One pending entry per workspace is enough. *)
let start_with ~sw ~publish ~invalidate =
  let pending = ref Set_util.StringSet.empty in
  let wake = Eio.Stream.create 1 in
  let mu = Stdlib.Mutex.create () in
  let observer ~base_path =
    Stdlib.Mutex.protect mu (fun () ->
      pending := Set_util.StringSet.add base_path !pending;
      if Eio.Stream.is_empty wake then Eio.Stream.add wake ());
    invalidate ~base_path
  in
  Schedule_store.install_change_observer observer;
  Eio.Switch.on_release sw (fun () ->
    ignore (Schedule_store.replace_change_observer_if_current
      ~current:observer ~replacement:invalidate));
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      Eio.Stream.take wake;
      let paths = Stdlib.Mutex.protect mu (fun () ->
        let paths = !pending in
        pending := Set_util.StringSet.empty;
        paths) in
      Set_util.StringSet.iter (fun base_path ->
        let report exn =
          Log.Server.warn "schedule invalidation publish failed: %s" (Printexc.to_string exn) in
        try publish ~base_path with
        | Eio.Cancel.Cancelled _ as exn -> Eio.Fiber.check (); report exn
        | exn -> report exn) paths;
      loop () in
    loop ())
;;

let publish ~base_path =
  let authority = Sse.runtime_authority_exn ~base_path in
  Sse.broadcast_to_sse_runtime_observers authority Schedule_invalidation_event.json
;;

let start ~sw =
  start_with ~sw ~publish
    ~invalidate:Server_routes_http_runtime.invalidate_full_health_snapshot_for_workspace
;;

module For_testing = struct
  let start = start_with
end
