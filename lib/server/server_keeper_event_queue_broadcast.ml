let announce (base_path, keeper_name) =
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (Keeper_event_queue_changed_event.to_json ~keeper_name)
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", Keeper_event_queue_changed_event.event_type ]
      ();
    Log.Server.warn "keeper event queue: broadcast %s for %s in %s failed: %s"
      Keeper_event_queue_changed_event.event_type keeper_name base_path
      (Printexc.to_string exn)
;;

(* Both stores call the observer on the writer -- the event queue under the
   Keeper's queue owner lock -- so the observer only drops caches, records
   which Keeper changed and wakes this fiber. A burst of writes for one Keeper
   is announced once. *)
let install ~sw =
  let wake = Eio.Stream.create 1 in
  let pending_mu = Stdlib.Mutex.create () in
  let pending : (string * string, unit) Hashtbl.t = Hashtbl.create 16 in
  let observer ~base_path ~keeper_name =
    Server_routes_http_runtime.invalidate_full_health_snapshot ();
    (* Each schedule row carries its target Keeper's queue and reaction
       evidence; a reader woken by the announcement must not get the list
       cached before this write (RFC-0480 §3.4). *)
    Server_dashboard_http_core_cache.invalidate_scheduled_automation ~base_path;
    Stdlib.Mutex.protect pending_mu (fun () ->
      Hashtbl.replace pending (base_path, keeper_name) ();
      if Eio.Stream.is_empty wake then Eio.Stream.add wake ())
  in
  let take_pending () =
    Stdlib.Mutex.protect pending_mu (fun () ->
      let keys = Hashtbl.fold (fun key () keys -> key :: keys) pending [] in
      Hashtbl.reset pending;
      keys)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      Eio.Stream.take wake;
      List.iter announce (take_pending ());
      loop ()
    in
    loop ());
  Keeper_event_queue_persistence.install_state_change_observer observer;
  Keeper_reaction_ledger.install_state_change_observer observer
;;
