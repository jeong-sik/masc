let changed_event = "gate_connector_changed"

let observer ~base_path ~connector_id =
  (* The write is already committed under the writer's lock. A cancellation
     raised here would skip the caller's bookkeeping, so it is reported like
     any failure; the caller's next suspension point still sees it. *)
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to_sse_runtime_observers authority
      (`Assoc
        [ "type", `String changed_event
        ; "connector", `String connector_id
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | () -> ()
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", changed_event ]
      ();
    Log.Misc.warn "gate_connector_broadcast: %s for %s failed: %s" changed_event
      connector_id (Printexc.to_string exn)
;;
