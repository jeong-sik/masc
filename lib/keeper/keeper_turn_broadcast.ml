let changed_event = "keeper_turn_changed"

let changed ~base_path ~keeper_name =
  (* The write is already committed, often under the caller's lock or in its
     finally block. A cancellation raised here would skip the caller's own
     bookkeeping, so it is reported like any failure; the caller's next
     suspension point still sees it. *)
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        [ "type", `String changed_event
        ; "name", `String keeper_name
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | () -> ()
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", keeper_name; "site", changed_event ]
      ();
    Log.Keeper.warn
      "keeper_turn_broadcast: %s name=%s failed: %s"
      changed_event
      keeper_name
      (Printexc.to_string exn)
;;
