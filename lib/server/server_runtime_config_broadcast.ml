let announce ~base_path =
  match
    Sse.broadcast_to (Sse.Runtime_observers (Sse.runtime_authority_exn ~base_path))
      (Runtime_config_changed_event.json ~ts_unix:(Time_compat.now ()))
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", Runtime_config_changed_event.event_type ]
      ();
    Log.Server.warn "server_runtime_config_broadcast: %s failed: %s"
      Runtime_config_changed_event.event_type (Printexc.to_string exn)
;;

let install ~sw ~base_path =
  let revision = Runtime.config_text_revision () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec watch ~after =
      let revision = Runtime.await_config_text_change ~after in
      announce ~base_path;
      watch ~after:revision
    in
    watch ~after:revision)
;;
