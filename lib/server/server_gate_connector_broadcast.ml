let changed_event = "gate_connector_changed"

let announce ~base_path connector_id =
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        [ "type", `String changed_event
        ; "connector", `String connector_id
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", changed_event ]
      ();
    Log.Server.warn "gate connector: broadcast %s for %s failed: %s" changed_event
      connector_id (Printexc.to_string exn)
;;

let install ~sw ~base_path =
  let wake = Eio.Stream.create 1 in
  let pending_mu = Stdlib.Mutex.create () in
  let pending : (string, unit) Hashtbl.t = Hashtbl.create 4 in
  let observer ~connector_id =
    Stdlib.Mutex.protect pending_mu (fun () ->
      Hashtbl.replace pending connector_id ();
      if Eio.Stream.is_empty wake then Eio.Stream.add wake ())
  in
  let take_pending () =
    Stdlib.Mutex.protect pending_mu (fun () ->
      let connectors = Hashtbl.fold (fun connector () acc -> connector :: acc) pending [] in
      Hashtbl.reset pending;
      connectors)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      Eio.Stream.take wake;
      List.iter (announce ~base_path) (take_pending ());
      loop ()
    in
    loop ());
  Gate_connector_announce.install observer
;;
