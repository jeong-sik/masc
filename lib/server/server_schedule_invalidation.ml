(* The store callback only records work and wakes a switch-owned worker.
   Fanout and disconnect hooks may yield, so they must not run on a schedule
   mutation's completion path. *)
let start_with ~sw ~mono_clock ~publish ~invalidate =
  let enqueue = Server_workspace_invalidation.start ~sw ~mono_clock ~publish in
  let observer ~base_path =
    enqueue ~base_path;
    invalidate ~base_path
  in
  Schedule_store.install_change_observer observer;
  Eio.Switch.on_release sw (fun () ->
    ignore (Schedule_store.replace_change_observer_if_current
      ~current:observer ~replacement:invalidate))
;;

let publish ~base_path =
  let authority = Sse.runtime_authority_exn ~base_path in
  Sse.broadcast_to_sse_runtime_observers authority Schedule_invalidation_event.json
;;

let start ~sw ~mono_clock =
  start_with ~sw ~mono_clock ~publish
    ~invalidate:Server_routes_http_runtime.invalidate_full_health_snapshot_for_workspace
;;

module For_testing = struct
  let start = start_with
end
