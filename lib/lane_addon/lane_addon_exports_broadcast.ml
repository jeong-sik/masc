let changed_event = "lane_addon_exports_changed"

let changed ~base_path =
  (* The entry's state is already written, often under a lane add-on mutex.
     A cancellation raised here would skip the caller's bookkeeping, so it is
     reported like any failure; the caller's next suspension point still
     sees it. *)
  match
    Sse.broadcast_to_sse_runtime_observers (Sse.runtime_authority_exn ~base_path)
      (`Assoc [ "type", `String changed_event; "ts_unix", `Float (Time_compat.now ()) ])
  with
  | () -> ()
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", changed_event ]
      ();
    Log.Misc.warn "lane_addon_exports_broadcast: %s failed: %s" changed_event
      (Printexc.to_string exn)
;;
