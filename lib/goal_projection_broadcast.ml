let changed_event = "goal_projection_changed"

let changed ~base_path =
  (* The write is already committed, under the Goal lock or a Goal source's
     own lock. A cancellation raised here would skip the caller's bookkeeping,
     so it is reported like any failure; the caller's next suspension point
     still sees it. *)
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
    Log.Misc.warn "goal_projection_broadcast: %s failed: %s" changed_event
      (Printexc.to_string exn)
;;
