let changed_event = "verification_requests_changed"

let changed ~base_path =
  (* The write is already committed, often under the backlog lock. A
     cancellation raised here would skip the caller's own bookkeeping, so it
     is reported like any failure; the caller's next suspension point still
     sees it. *)
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc [ "type", `String changed_event; "ts_unix", `Float (Time_compat.now ()) ])
  with
  | () -> ()
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", changed_event ]
      ();
    Log.Keeper.warn "verification_request_broadcast: %s failed: %s" changed_event
      (Printexc.to_string exn)
;;
