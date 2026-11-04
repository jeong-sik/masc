let announce ~base_path =
  match
    Sse.broadcast_to (Sse.Runtime_observers (Sse.runtime_authority_exn ~base_path))
      (Skill_catalog_published_event.json ~ts_unix:(Time_compat.now ()))
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", Skill_catalog_published_event.event_type ]
      ();
    Log.Server.warn "server_skill_catalog_broadcast: %s failed: %s"
      Skill_catalog_published_event.event_type (Printexc.to_string exn)
;;

let publication_observer ~base_path ~invalidate_full_health () =
  invalidate_full_health ();
  announce ~base_path
;;
