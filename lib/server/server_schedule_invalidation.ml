let notice_count = Atomic.make 0
let notices () = Atomic.get notice_count

let publish ~base_path =
  let authority = Sse.runtime_authority_exn ~base_path in
  Sse.broadcast_to_sse_runtime_observers authority Schedule_invalidation_event.json
;;

(* A reader woken by the publication reads the fleet schedule list, which is
   cached; dropping it first makes that read see the write (RFC-0480 §3.4). *)
let invalidate ~base_path =
  Server_routes_http_runtime.invalidate_full_health_snapshot_for_workspace ~base_path;
  Server_dashboard_http_core_cache.invalidate_scheduled_automation ~base_path
;;

(* The store callback only records work and wakes a switch-owned worker.
   Fanout and disconnect hooks may yield, so they must not run on a schedule
   mutation's completion path. A change is counted when it is published,
   since a reader can read the list only after that. *)
let start_with ~sw ~mono_clock ~publish ~invalidate =
  let publish ~base_path =
    Atomic.incr notice_count;
    publish ~base_path
  in
  let enqueue = Server_workspace_invalidation.start ~sw ~mono_clock ~publish in
  let observer ~base_path =
    invalidate ~base_path;
    enqueue ~base_path
  in
  Schedule_store.install_change_observer observer;
  Eio.Switch.on_release sw (fun () ->
    ignore (Schedule_store.replace_change_observer_if_current
      ~current:observer ~replacement:invalidate))
;;

let start ~sw ~mono_clock = start_with ~sw ~mono_clock ~publish ~invalidate

(* The runner's own changes are not store writes: its status and holds live
   in memory. It runs on its own fiber, so it publishes directly. *)
let announce ~base_path =
  Server_dashboard_http_core_cache.invalidate_scheduled_automation ~base_path;
  Atomic.incr notice_count;
  try publish ~base_path with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", Schedule_invalidation_event.event_type ]
      ();
    Log.Server.warn "schedules: publishing %s for %s failed: %s"
      Schedule_invalidation_event.event_type base_path (Printexc.to_string exn)
;;

module For_testing = struct
  let start = start_with
end
